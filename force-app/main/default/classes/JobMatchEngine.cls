/**
 * Candidate matching, stage 1: Quick fit (27-11-2026). No AI, no tokens.
 *
 * Every candidate gets a 0-100 score for every open job:
 *   skills 50 (with synonyms, e.g. LWC = Lightning Web Components), experience range 20,
 *   role 15, certifications 10, location 5.
 * Matched and missing skills are saved on the match, so recruiters see why.
 *
 * Stage 2 (JobMatchJob) asks Einstein only about the top AI_TOP_N candidates per job whose quick fit
 * is at least AI_MIN_QUICK, and only when the job or the candidate changed since the last AI answer.
 *
 * One Job_Match__c per job and candidate (Match_Key__c = Opportunity Id + Account Id).
 * Match_Score__c = average of quick fit and AI fit when there is an AI fit, else quick fit, always 0-100.
 */
public without sharing class JobMatchEngine {

    public static final Integer AI_TOP_N = 10;
    public static final Integer AI_MIN_QUICK = 30;
    public static final Integer OPEN_JOB_DAYS = 90;
    static final Integer MAX_JOB_SKILLS = 25;

    public static final List<String> POOL_TYPES = new List<String>{ 'Candidates', 'Employee', 'Contractor' };
    static final List<String> AVAILABLE = new List<String>{ 'Immediately Available', 'Available in 1 Week', 'Available in 2 Weeks' };

    // canonical forms (left -> right); multi-word phrases before single words
    static final List<String[]> SYNONYMS = new List<String[]>{
        new String[]{ 'lightning web components', 'lwc' }, new String[]{ 'lightning web component', 'lwc' },
        new String[]{ 'lightning component', 'aura' }, new String[]{ 'aura components', 'aura' },
        new String[]{ 'amazon web services', 'aws' }, new String[]{ 'google cloud platform', 'gcp' },
        new String[]{ 'google cloud', 'gcp' }, new String[]{ 'microsoft azure', 'azure' },
        new String[]{ 'restful apis', 'rest api' }, new String[]{ 'restful api', 'rest api' },
        new String[]{ 'rest apis', 'rest api' }, new String[]{ 'restful', 'rest' },
        new String[]{ 'cicd pipelines', 'cicd' }, new String[]{ 'cicd pipeline', 'cicd' },
        new String[]{ 'continuous integration', 'cicd' },
        new String[]{ 'machine learning', 'ml' }, new String[]{ 'artificial intelligence', 'ai' },
        new String[]{ 'microsoft excel', 'excel' }, new String[]{ 'ms excel', 'excel' },
        new String[]{ 'node.js', 'node' }, new String[]{ 'nodejs', 'node' },
        new String[]{ 'react.js', 'react' }, new String[]{ 'reactjs', 'react' },
        new String[]{ 'vue.js', 'vue' }, new String[]{ 'vuejs', 'vue' },
        new String[]{ 'angularjs', 'angular' }, new String[]{ 'dot net', '.net' }, new String[]{ 'dotnet', '.net' },
        new String[]{ 'sfdc', 'salesforce' }, new String[]{ 'k8s', 'kubernetes' }, new String[]{ 'postgres', 'postgresql' },
        new String[]{ 'js', 'javascript' }, new String[]{ 'ts', 'typescript' }, new String[]{ 'golang', 'go' },
        new String[]{ 'apis', 'api' }, new String[]{ 'bangalore', 'bengaluru' }, new String[]{ 'gurgaon', 'gurugram' },
        new String[]{ 'bombay', 'mumbai' }, new String[]{ 'madras', 'chennai' }, new String[]{ 'trivandrum', 'thiruvananthapuram' },
        new String[]{ 'cochin', 'kochi' }
    };
    static final Set<String> FILLER = new Set<String>{
        'and', 'or', 'of', 'the', 'with', 'in', 'for', 'to', 'a', 'an', 'on', 'at', 'as', 'is', 'experience', 'knowledge',
        'skills', 'skill', 'strong', 'good', 'understanding', 'working', 'hands', 'basic', 'advanced', 'proficiency',
        'familiarity', 'tools', 'tool', 'practices', 'concepts', 'principles', 'using', 'etc', 'including', 'ability',
        'excellent', 'solid', 'years', 'year', 'plus', 'preferred', 'required', 'must', 'have', 'nice'
    };
    static final Set<String> SENIORITY = new Set<String>{
        'senior', 'sr', 'junior', 'jr', 'lead', 'associate', 'principal', 'trainee', 'intern', 'i', 'ii', 'iii', 'staff', 'chief', 'head'
    };
    static final Set<String> CERT_WORDS = new Set<String>{ 'certified', 'certification', 'certificate', 'professional', 'exam' };

    // =====================================================================
    // Profiles
    // =====================================================================

    public class JobProfile {
        public Id id;
        public String name;
        public List<String> skillLabels = new List<String>();
        public List<String> skillKeys = new List<String>();
        public String expText;
        public Decimal expMin;
        public Decimal expMax;
        public String roleText;
        public List<String> roleWords = new List<String>();
        public String location;
        public String qualifications;
        public String jdText;     // padded normalised JD text (fallback when no skills are listed)
        public String allText;    // padded normalised skills + qualifications + role
        public Boolean asksForCerts = false;
    }

    public class PersonProfile {
        public Id id;
        public String designation;
        public String yearsText;
        public Decimal years;
        public String location;
        public List<String> skillLabels = new List<String>();
        public List<String> skillKeys = new List<String>();
        public List<String> certs = new List<String>();
        public String projectSkills = '';
        public String summary;
        public String corpus;     // padded normalised text of everything the candidate has
    }

    public class QuickFit {
        public Integer total = 0;
        public Integer skills = 0;
        public Integer experience = 0;
        public Integer role = 0;
        public Integer certifications = 0;
        public Integer location = 0;
        public List<String> matched = new List<String>();
        public List<String> missing = new List<String>();
        public String explanation;
    }

    public static List<Opportunity> queryJobs(Set<Id> ids, Boolean openRecentOnly) {
        String q = 'SELECT Id, Name, Skills_Required__c, Experience_Required__c, Job_Location__c, Role_Required__c, '
            + 'Required_Qualifications__c, Job_Description__c FROM Opportunity WHERE RecordType.DeveloperName = \'Resourcing\'';
        if (ids != null) q += ' AND Id IN :ids';
        if (openRecentOnly) q += ' AND IsClosed = false AND CreatedDate = LAST_N_DAYS:' + OPEN_JOB_DAYS;
        return Database.query(q + ' ORDER BY CreatedDate DESC LIMIT 2000');
    }

    /** The matching pool: candidates, employees and contractors who are not blacklisted and are available. */
    public static List<Account> queryPeople(Set<Id> ids) {
        List<String> poolTypes = POOL_TYPES;
        List<String> available = AVAILABLE;
        String q = 'SELECT Id, Name, Years_of_Experience__c, Designation__c, Description, Current_Location__c, Preferred_location__c, '
            + '(SELECT Skill_Name__c FROM Employee_Skills__r LIMIT 60), (SELECT Name FROM Certifications__r LIMIT 20), '
            + '(SELECT Skills_Applied__c, Tools_Used__c FROM Project_Experiences__r LIMIT 15) '
            + 'FROM Account WHERE RecordType.DeveloperName IN :poolTypes AND Status__c != \'Blacklist\' '
            + 'AND (Availability_for_New_Project__c IN :available OR Availability_for_New_Project__c = null)';
        if (ids != null) q += ' AND Id IN :ids';
        return Database.query(q + ' LIMIT 5000');
    }

    public static JobProfile jobProfile(Opportunity o) {
        JobProfile j = new JobProfile();
        j.id = o.Id;
        j.name = o.Name;
        for (String label : splitList(o.Skills_Required__c)) {
            String key = norm(label);
            if (String.isBlank(key) || j.skillKeys.contains(key) || FILLER.contains(key)) continue;
            j.skillLabels.add(label);
            j.skillKeys.add(key);
            if (j.skillKeys.size() >= MAX_JOB_SKILLS) break;
        }
        j.expText = o.Experience_Required__c;
        Decimal[] range = parseRange(o.Experience_Required__c);
        j.expMin = range[0];
        j.expMax = range[1];
        j.roleText = String.isNotBlank(o.Role_Required__c) ? o.Role_Required__c.left(150) : o.Name;
        for (String w : norm(j.roleText).split(' ')) {
            if (w.length() > 1 && !FILLER.contains(w) && !SENIORITY.contains(w) && !j.roleWords.contains(w)) j.roleWords.add(w);
        }
        j.location = o.Job_Location__c;
        j.qualifications = o.Required_Qualifications__c;
        j.jdText = pad(norm(left(o.Job_Description__c, 20000)));
        j.allText = pad(norm(left(o.Skills_Required__c, 8000) + ' ' + left(o.Required_Qualifications__c, 4000) + ' ' + j.roleText));
        j.asksForCerts = (left(o.Required_Qualifications__c, 4000) + ' ' + left(o.Skills_Required__c, 4000)).toLowerCase().contains('certif');
        return j;
    }

    public static PersonProfile personProfile(Account a) {
        PersonProfile p = new PersonProfile();
        p.id = a.Id;
        p.designation = a.Designation__c;
        p.yearsText = a.Years_of_Experience__c;
        p.years = parseYears(a.Years_of_Experience__c);
        p.location = join(new List<String>{ a.Current_Location__c, a.Preferred_location__c }, ' / ');
        for (Employee_Skill__c s : a.Employee_Skills__r) {
            String key = norm(s.Skill_Name__c);
            if (String.isBlank(key) || p.skillKeys.contains(key)) continue;
            p.skillKeys.add(key);
            p.skillLabels.add(s.Skill_Name__c.trim());
        }
        for (Certification__c c : a.Certifications__r) {
            if (String.isNotBlank(c.Name)) p.certs.add(c.Name.trim());
        }
        List<String> proj = new List<String>();
        for (Project_Experience__c pe : a.Project_Experiences__r) {
            proj.add(left(pe.Skills_Applied__c, 500));
            proj.add(left(pe.Tools_Used__c, 500));
        }
        p.projectSkills = join(proj, ', ');
        p.summary = left(a.Description, 3000);
        p.corpus = pad(norm(String.join(p.skillLabels, ' , ') + ' , ' + String.join(p.certs, ' , ') + ' , '
            + p.projectSkills + ' , ' + left(a.Designation__c, 200) + ' , ' + p.summary));
        return p;
    }

    // =====================================================================
    // Quick fit
    // =====================================================================

    public static QuickFit quickFit(JobProfile j, PersonProfile p) {
        QuickFit f = new QuickFit();

        // ---- skills (50) ----
        if (!j.skillKeys.isEmpty()) {
            Decimal credit = 0;
            for (Integer i = 0; i < j.skillKeys.size(); i++) {
                Decimal c = skillCredit(j.skillKeys[i], p);
                credit += c;
                if (c >= 1) f.matched.add(j.skillLabels[i]); else f.missing.add(j.skillLabels[i]);
            }
            f.skills = Math.round(50 * credit / j.skillKeys.size());
        } else {
            // no skills listed on the job: count the candidate's skills the job description mentions (5 = full)
            Integer found = 0;
            for (Integer i = 0; i < p.skillKeys.size(); i++) {
                if (p.skillKeys[i].length() > 1 && j.jdText.contains(pad(p.skillKeys[i]))) {
                    found++;
                    f.matched.add(p.skillLabels[i]);
                }
            }
            f.skills = Math.round(50 * Math.min(found, 5) / 5.0);
        }

        // ---- experience (20) ----
        if (j.expMin == null || j.expMin == 0) {
            f.experience = 20;
        } else if (p.years == null) {
            f.experience = 8;
        } else if (p.years >= j.expMin) {
            f.experience = (j.expMax != null && p.years > j.expMax + 3) ? 14 : 20;
        } else {
            Decimal gap = j.expMin - p.years;
            f.experience = gap <= 1 ? 14 : (gap <= 2 ? 8 : 0);
        }

        // ---- role (15) ----
        if (j.roleWords.isEmpty()) {
            f.role = 15;
        } else if (String.isBlank(p.designation)) {
            f.role = 5;
        } else {
            String d = pad(norm(p.designation));
            Integer hit = 0;
            for (String w : j.roleWords) if (d.contains(pad(w))) hit++;
            f.role = Math.round(15.0 * hit / j.roleWords.size());
        }

        // ---- certifications (10) ----
        Boolean relevant = false;
        for (String c : p.certs) {
            for (String w : norm(c).split(' ')) {
                if (w.length() > 2 && !FILLER.contains(w) && !CERT_WORDS.contains(w) && j.allText.contains(pad(w))) {
                    relevant = true;
                    break;
                }
            }
            if (relevant) break;
        }
        f.certifications = relevant ? 10 : (j.asksForCerts ? 0 : 5);

        // ---- location (5) ----
        f.location = locationScore(j.location, p.location);

        f.total = Math.min(100, f.skills + f.experience + f.role + f.certifications + f.location);
        f.explanation = explain(j, p, f);
        return f;
    }

    /** 1 = has the skill, 0.5 = most of a multi-word skill, 0 = missing. */
    static Decimal skillCredit(String key, PersonProfile p) {
        if (p.corpus.contains(pad(key))) return 1;
        List<String> words = new List<String>();
        for (String w : key.split(' ')) if (w.length() > 1 && !FILLER.contains(w)) words.add(w);
        if (words.isEmpty()) return 0;
        Integer hit = 0;
        for (String w : words) if (p.corpus.contains(pad(w))) hit++;
        if (hit == words.size()) return 1;
        if (words.size() >= 2 && hit * 3 >= words.size() * 2) return 0.5;
        // a candidate skill that is a clear part of the job skill (e.g. "Service Cloud" for "Salesforce Service Cloud")
        for (String ck : p.skillKeys) {
            if (ck.contains(' ') && pad(key).contains(pad(ck))) return 0.5;
        }
        return 0;
    }

    static Integer locationScore(String jobLoc, String personLoc) {
        String jl = norm(jobLoc);
        if (String.isBlank(jl) || jl.contains('remote') || jl.contains('anywhere')) return 5;
        String pl = pad(norm(personLoc));
        if (String.isBlank(personLoc)) return 2;
        if (pl.contains(' anywhere ') || pl.contains(' remote ') || pl.contains(' any ')) return 4;
        List<String> parts = jobLoc.split('[,/|]');
        String city = norm(parts[0]);
        if (String.isNotBlank(city) && pl.contains(pad(city))) return 5;
        for (Integer i = 1; i < parts.size(); i++) {
            String part = norm(parts[i]);
            if (String.isNotBlank(part) && part != 'india' && pl.contains(pad(part))) return 2;
        }
        return 0;
    }

    static String explain(JobProfile j, PersonProfile p, QuickFit f) {
        List<String> out = new List<String>();
        if (!j.skillKeys.isEmpty()) {
            out.add('Skills ' + f.matched.size() + ' of ' + j.skillKeys.size()
                + (f.matched.isEmpty() ? '' : ': ' + String.join(cap(f.matched, 6), ', ')) + '.');
        } else if (!f.matched.isEmpty()) {
            out.add('JD mentions ' + String.join(cap(f.matched, 6), ', ') + '.');
        }
        if (j.expMin != null && j.expMin > 0) {
            out.add('Experience ' + (p.years == null ? 'not given' : p.years.stripTrailingZeros().toPlainString() + ' yrs')
                + ' vs ' + j.expText + ' required.');
        }
        if (String.isNotBlank(p.designation)) out.add('Role: ' + p.designation.left(60) + '.');
        if (!f.missing.isEmpty()) out.add('Missing: ' + String.join(cap(f.missing, 5), ', ') + '.');
        return String.join(out, ' ');
    }

    // =====================================================================
    // Scoring runs
    // =====================================================================

    public class RunResult {
        public Integer saved = 0;
        public Integer failed = 0;
        public List<Id> aiQueue = new List<Id>();
    }

    /** Scores the given jobs against everyone in the pool. */
    public static RunResult scoreJobs(Set<Id> jobIds) {
        return run(queryJobs(jobIds, false), queryPeople(null), false);
    }

    /** Reverse matching: scores new or updated candidates against the open jobs of the last 90 days. */
    public static RunResult scoreCandidates(Set<Id> accountIds) {
        return run(queryJobs(null, true), queryPeople(accountIds), true);
    }

    static RunResult run(List<Opportunity> jobs, List<Account> people, Boolean onlyTheseInAiQueue) {
        RunResult res = new RunResult();
        if (jobs.isEmpty() || people.isEmpty()) return res;

        Set<Id> jobIds = new Map<Id, Opportunity>(jobs).keySet();
        Set<Id> personIds = new Map<Id, Account>(people).keySet();

        // existing rows: keyed rows first, then the newest legacy row (old rows without a key are adopted, never duplicated)
        Map<String, Job_Match__c> existing = new Map<String, Job_Match__c>();
        for (Job_Match__c m : [
            SELECT Id, Opportunity_Name__c, Candidate_Name__c, Match_Key__c, AI_Fit_Score__c, Match_Status__c, Explanation__c
            FROM Job_Match__c
            WHERE Opportunity_Name__c IN :jobIds AND Candidate_Name__c IN :personIds
            ORDER BY Match_Key__c NULLS LAST, CreatedDate DESC
        ]) {
            String k = key(m.Opportunity_Name__c, m.Candidate_Name__c);
            if (!existing.containsKey(k)) existing.put(k, m);
        }

        List<PersonProfile> profiles = new List<PersonProfile>();
        for (Account a : people) profiles.add(personProfile(a));

        List<Job_Match__c> toInsert = new List<Job_Match__c>();
        List<Job_Match__c> toUpdate = new List<Job_Match__c>();
        Datetime now = Datetime.now();
        for (Opportunity o : jobs) {
            JobProfile j = jobProfile(o);
            for (PersonProfile p : profiles) {
                QuickFit f = quickFit(j, p);
                String k = key(o.Id, p.id);
                Job_Match__c old = existing.get(k);
                Boolean hasAi = old != null && old.AI_Fit_Score__c != null && old.Match_Key__c != null;
                Job_Match__c m = new Job_Match__c(
                    Match_Key__c = k,
                    Quick_Fit_Score__c = f.total,
                    Match_Score__c = hasAi ? blend(f.total, old.AI_Fit_Score__c) : f.total,
                    Skills_Matched__c = left(String.join(f.matched, ', '), 4000),
                    Skills_Missing__c = left(String.join(f.missing, ', '), 4000),
                    Scored_On__c = now
                );
                if (!hasAi) {
                    m.Explanation__c = 'Quick fit ' + f.total + '/100. ' + f.explanation;
                    m.Match_Status__c = 'Scored';
                    m.AI_Fit_Score__c = null;
                    m.AI_Input_Hash__c = null;
                    m.Error_Message__c = null;
                }
                if (old == null) {
                    m.Opportunity_Name__c = o.Id;
                    m.Candidate_Name__c = p.id;
                    toInsert.add(m);
                } else {
                    m.Id = old.Id;
                    toUpdate.add(m);
                }
            }
        }
        countResults(Database.insert(toInsert, false), res, 'insert');
        countResults(Database.update(toUpdate, false), res, 'update');

        // Stage 2 queue: top N per job with quick fit >= AI_MIN_QUICK
        Map<Id, Integer> perJob = new Map<Id, Integer>();
        List<Job_Match__c> waiting = new List<Job_Match__c>();
        for (Job_Match__c m : [
            SELECT Id, Opportunity_Name__c, Candidate_Name__c, Match_Status__c
            FROM Job_Match__c
            WHERE Opportunity_Name__c IN :jobIds AND Match_Key__c != null AND Quick_Fit_Score__c >= :AI_MIN_QUICK
            ORDER BY Opportunity_Name__c, Quick_Fit_Score__c DESC, Scored_On__c DESC
            LIMIT 20000
        ]) {
            Integer n = perJob.containsKey(m.Opportunity_Name__c) ? perJob.get(m.Opportunity_Name__c) : 0;
            if (n >= AI_TOP_N) continue;
            perJob.put(m.Opportunity_Name__c, n + 1);
            if (!onlyTheseInAiQueue || personIds.contains(m.Candidate_Name__c)) {
                res.aiQueue.add(m.Id);
                if (m.Match_Status__c == 'Scored' || m.Match_Status__c == null) waiting.add(new Job_Match__c(Id = m.Id, Match_Status__c = 'Waiting for AI'));
            }
        }
        if (!waiting.isEmpty()) Database.update(waiting, false);
        return res;
    }

    static void countResults(List<Database.SaveResult> results, RunResult res, String what) {
        List<String> errors = new List<String>();
        for (Database.SaveResult sr : results) {
            if (sr.isSuccess()) {
                res.saved++;
            } else {
                res.failed++;
                if (errors.size() < 5) errors.add(sr.getErrors()[0].getMessage());
            }
        }
        if (!errors.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'JobMatchEngine ' + what + ' failed: ' + String.join(errors, ' | '));
        }
    }

    // =====================================================================
    // Compact AI input (few tokens) and its fingerprint
    // =====================================================================

    public static String jobText(JobProfile j) {
        List<String> out = new List<String>();
        out.add('Role: ' + left(j.roleText, 120));
        if (String.isNotBlank(j.expText)) out.add('Experience required: ' + j.expText.left(60));
        if (String.isNotBlank(j.location)) out.add('Location: ' + j.location.left(80));
        if (!j.skillLabels.isEmpty()) out.add('Skills: ' + String.join(j.skillLabels, ', '));
        if (String.isNotBlank(j.qualifications)) out.add('Qualifications: ' + oneLine(j.qualifications, 300));
        if (j.skillLabels.isEmpty() && String.isNotBlank(j.jdText)) out.add('Description: ' + j.jdText.trim().left(600));
        return String.join(out, '\n');
    }

    public static String personText(PersonProfile p) {
        List<String> out = new List<String>();
        if (String.isNotBlank(p.designation)) out.add('Role: ' + p.designation.left(100));
        if (String.isNotBlank(p.yearsText)) out.add('Experience: ' + p.yearsText.left(40));
        if (String.isNotBlank(p.location)) out.add('Location: ' + p.location.left(100));
        if (!p.skillLabels.isEmpty()) out.add('Skills: ' + String.join(cap(p.skillLabels, 30), ', '));
        if (!p.certs.isEmpty()) out.add('Certifications: ' + String.join(cap(p.certs, 8), ', '));
        if (String.isNotBlank(p.projectSkills)) out.add('Project skills: ' + oneLine(p.projectSkills, 400));
        if (String.isNotBlank(p.summary)) out.add('Summary: ' + oneLine(p.summary, 300));
        return String.join(out, '\n');
    }

    /** Change PROMPT_VERSION when the AI rules change, so the top matches are checked once more with the new rules. */
    public static final String PROMPT_VERSION = 'v2';

    public static String fingerprint(String job, String person) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(PROMPT_VERSION + '\n' + job + '\n#\n' + person)));
    }

    /** Final score: average of the rule score and the AI score, so one odd AI answer moves a score only a little. */
    public static Integer blend(Decimal quick, Decimal ai) {
        if (ai == null) return quick == null ? 0 : quick.intValue();
        if (quick == null) return ai.intValue();
        return Math.round((quick + ai) / 2);
    }

    // =====================================================================
    // Text helpers
    // =====================================================================

    public static String key(Id jobId, Id personId) {
        return String.valueOf(jobId).left(15) + String.valueOf(personId).left(15);
    }

    /** lower case, punctuation to spaces (keeps + # and inner dots), canonical synonyms. */
    public static String norm(String s) {
        if (String.isBlank(s)) return '';
        String t = s.toLowerCase().replace('ci/cd', 'cicd').replace('ci / cd', 'cicd');
        t = t.replaceAll('[^a-z0-9+#.]+', ' ').replaceAll('\\.(?=\\s|$)', ' ').replaceAll('\\s+', ' ');
        t = ' ' + t.trim() + ' ';
        for (String[] pair : SYNONYMS) {
            String from1 = ' ' + pair[0] + ' ';
            if (t.contains(from1)) t = t.replace(from1, ' ' + pair[1] + ' ');
        }
        return t.trim();
    }

    static String pad(String s) {
        return ' ' + (s == null ? '' : s) + ' ';
    }

    /** Splits a skills list on commas, semicolons, new lines, bullets, brackets and " and ". */
    public static List<String> splitList(String text) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) return out;
        for (String part : text.split('[,;\\n\\r\\u2022|()\\[\\]]+|\\s+and\\s+|\\s+or\\s+')) {
            String label = part.replaceAll('^[\\s\\-\\*\\.:]+|[\\s\\.:]+$', '').trim();
            if (label.length() >= 1 && label.length() <= 60) out.add(label);
        }
        return out;
    }

    /** "3-5 years" -> [3,5], "5+" -> [5,null], "2 to 4" -> [2,4], blank -> [null,null]. Months are turned into years. */
    public static Decimal[] parseRange(String s) {
        Decimal[] out = new Decimal[]{ null, null };
        if (String.isBlank(s)) return out;
        Matcher m = Pattern.compile('(\\d+(?:\\.\\d+)?)').matcher(s);
        List<Decimal> nums = new List<Decimal>();
        while (m.find() && nums.size() < 2) nums.add(Decimal.valueOf(m.group(1)));
        if (nums.isEmpty()) return out;
        Boolean months = s.toLowerCase().contains('month') && !s.toLowerCase().contains('year');
        Decimal div = months ? 12 : 1;
        out[0] = (nums[0] / div).setScale(1);
        if (nums.size() == 2 && nums[1] > nums[0]) out[1] = (nums[1] / div).setScale(1);
        return out;
    }

    public static Decimal parseYears(String s) {
        return parseRange(s)[0];
    }

    static String left(String s, Integer n) {
        return s == null ? '' : s.left(n);
    }

    static String oneLine(String s, Integer n) {
        return s == null ? '' : s.replaceAll('\\s+', ' ').trim().left(n);
    }

    static String join(List<String> parts, String sep) {
        List<String> out = new List<String>();
        for (String p : parts) if (String.isNotBlank(p)) out.add(p.trim());
        return String.join(out, sep);
    }

    static List<String> cap(List<String> items, Integer n) {
        List<String> out = new List<String>();
        for (Integer i = 0; i < items.size() && i < n; i++) out.add(items[i]);
        if (items.size() > n) out.add('+' + (items.size() - n) + ' more');
        return out;
    }
}