/**
 * Turns the JD_Prompt AI JSON into demand records: client Account, Opportunity and Job_Description__c.
 *
 * Rules
 *  - Client Account: matched on a normalized company name ("Infosys Ltd." = "infosys"),
 *    never on Candidate / Employee / Contractor Accounts. New clients get the Direct_Customers
 *    record type and Account_Type__c = Customer.
 *  - Opportunity (T-071, 26-11-2026): only OPEN Opportunities of that client created in the last 90 days are compared.
 *      Same requirement  = same role (normalized: "Sr. SFDC Dev" = "Senior Salesforce Developer") and the JD is
 *                          similar (50% of the words of role + responsibilities + skills + qualifications, or 60% of
 *                          the skills), or, when a role is missing on either side, 80% of those words.
 *                          -> the Opportunity is reused.
 *      Possible duplicate = same role but the text differs (the AI writes the text differently each time).
 *                          -> Qbay Home upload: the intake waits in Needs Review and the recruiter chooses
 *                             "Use existing" or "Create new" (jdDecision).
 *                          -> email / WhatsApp: a new Opportunity is created and the summary names the possible duplicate.
 *      Otherwise a new Resourcing Opportunity is created. Closed deals are never changed.
 *  - Re-using an Opportunity only fills empty fields; nothing is blanked.
 *  - Every number/date is parsed safely: a bad value leaves that field empty.
 */
public without sharing class JobDescriptionCreationController {

    public class Result {
        public Id accountId;
        public Id opportunityId;
        public Id jobDescriptionId;
        public List<String> legacy = new List<String>();
        public String summary;
    }

    private static final Set<String> PERSON_RTS = new Set<String>{ 'Candidates', 'Employee', 'Contractor' };
    private static final String TEMP_ACCOUNT = 'Temp Holding Account';
    private static final Set<String> COMPANY_SUFFIXES = new Set<String>{
        'pvt', 'private', 'ltd', 'limited', 'inc', 'incorporated', 'llc', 'llp', 'plc', 'corp', 'corporation', 'co', 'company', 'gmbh'
    };

    // =====================================================================
    // Legacy entry point (email / WhatsApp): returns [accountName, opportunityId, ...]
    // =====================================================================
    public static List<String> createJobDescriptions(String jsonText, Id jdSampleId) {
        Result r = process(jsonText, jdSampleId, false);
        return r.legacy.isEmpty() ? null : r.legacy;
    }

    // =====================================================================
    // Main entry point. strict = true for the UI upload.
    // =====================================================================
    public static Result process(String rawJson, Id serviceId, Boolean strict) {
        return process(rawJson, serviceId, strict, null);
    }

    /** Recruiter's answer to a possible duplicate JD (Qbay Home upload, Needs Review). */
    public static final String DECISION_EXISTING = 'existing';
    public static final String DECISION_NEW = 'new';
    public static final String POSSIBLE_DUPLICATE_PREFIX = 'Possible duplicate: ';
    public static final String NOT_A_JD_MESSAGE = 'This file does not look like a resume or a job description: '
        + 'no company, skills, experience, qualifications or location were found. Nothing was created.';

    /**
     * @param jdDecision null = normal run; DECISION_EXISTING / DECISION_NEW = the recruiter's choice for a possible duplicate
     */
    public static Result process(String rawJson, Id serviceId, Boolean strict, String jdDecision) {
        Result res = new Result();
        Map<String, Object> parsed = AiJson.parse(rawJson);
        if (parsed == null) {
            if (strict) throw new IntakeProcessor.RejectException('The AI response could not be read for this file. Please check the file is a readable PDF or DOCX job description.');
            return res;
        }
        String docType = AiJson.documentType(rawJson);
        if (strict && docType == 'Resume') {
            throw new IntakeProcessor.RejectException('This file looks like a resume, not a Job Description. Please upload it as a Resume, or choose Auto-detect. Nothing was created.');
        }
        if (strict && docType == 'Other') {
            throw new IntakeProcessor.RejectException('This file does not look like a Job Description. Nothing was created. Please upload it as a Resume, or choose Auto-detect.');
        }

        List<Map<String, Object>> jdList = new List<Map<String, Object>>();
        for (Map<String, Object> w : AiJson.objList(parsed, 'jobs')) {
            Map<String, Object> jd = AiJson.obj(w, 'jobDescription');
            if (jd != null) jdList.add(jd);
        }
        if (jdList.isEmpty()) {
            if (strict) throw new IntakeProcessor.RejectException('No job description could be read from this file. Nothing was created.');
            return res;
        }

        // ---------- shared lookups (once) ----------
        Service__c svc = null;
        List<ContentDocumentLink> serviceFiles = new List<ContentDocumentLink>();
        String fileTitle = null;
        if (serviceId != null) {
            List<Service__c> svcs = [
                SELECT Id, Name, EmailFrom__c, WhatsappFrom__c, Email_Body__c, Source_Channel__c
                FROM Service__c WHERE Id = :serviceId LIMIT 1
            ];
            if (!svcs.isEmpty()) svc = svcs[0];
            serviceFiles = [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
                FROM ContentDocumentLink WHERE LinkedEntityId = :serviceId
            ];
            if (!serviceFiles.isEmpty()) {
                fileTitle = serviceFiles[0].ContentDocument.Title;
                String ext = serviceFiles[0].ContentDocument.FileExtension;
                if (ext != null && !fileTitle.toLowerCase().endsWith('.' + ext.toLowerCase())) fileTitle += '.' + ext;
            }
        }
        Map<String, Decimal> rates = loadRates();
        Id ownerId = resolveOwner(svc);
        String source = sourceOf(svc);
        // Only Qbay Home uploads have a screen where the recruiter can answer a possible duplicate
        Boolean askOnPossible = strict && jdDecision == null && svc != null && svc.Source_Channel__c == IntakeProcessor.CHANNEL_UI;

        Id resourcingRt = rtId(Opportunity.SObjectType, 'Resourcing');
        Id clientRt = rtId(Account.SObjectType, 'Direct_Customers');

        Set<String> jobTypes = picklistValues(Opportunity.Job_type__c);
        Set<String> seniorities = picklistValues(Job_Description__c.Seniority__c);

        Integer queueableRoom = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
        if (Test.isRunningTest() && System.isQueueable()) queueableRoom = 0; // tests cannot chain queueables
        List<Opportunity> needMatch = new List<Opportunity>();
        List<ContentDocumentLink> newLinks = new List<ContentDocumentLink>();
        List<String> summaries = new List<String>();

        for (Map<String, Object> jd : jdList) {
            // ---------- company ----------
            String companyName = AiJson.str(jd, 'companyName');
            if (companyName != null && companyName.equalsIgnoreCase(TEMP_ACCOUNT)) companyName = null;
            if (companyName == null && strict && !hasJobSignals(jd)) {
                // e.g. a report or meeting notes that the AI called a JD: say so, not "no company name"
                throw new IntakeProcessor.RejectException(NOT_A_JD_MESSAGE);
            }
            if (companyName == null) {
                if (strict) throw new IntakeProcessor.RejectException('No company name was found in the Job Description. Please add the client name to the JD and upload again. Nothing was created.');
                companyName = TEMP_ACCOUNT; // legacy behaviour for email / WhatsApp
            }
            Account client = findOrCreateClient(companyName, clientRt);

            // ---------- JD values ----------
            String role = AiJson.str(jd, 'opportunityName');
            if (role == null) role = AiJson.str(jd, 'title');
            String title = AiJson.str(jd, 'title');
            if (title == null) title = role;
            String responsibilities = AiJson.str(jd, 'responsibilities');
            String skills = AiJson.str(jd, 'skillsRequired');
            String prefLocation = AiJson.str(jd, 'preferredLocation');
            String otherLocation = AiJson.str(jd, 'otherLocation');
            String qualifications = AiJson.str(jd, 'qualifications');
            String duration = AiJson.str(jd, 'duration');
            Decimal experience = AiJson.toNumber(jd.get('experience'));
            Decimal resources = AiJson.toNumber(jd.get('ar'));
            Date startDate = AiJson.toDate(jd.get('opportunityStartDate'));
            Date closeDate = AiJson.toDate(jd.get('opportunityCloseDate'));
            String jobType = matchPicklist(AiJson.str(jd, 'jobType'), jobTypes);
            String seniority = matchPicklist(AiJson.str(jd, 'seniority'), seniorities);

            // ---------- opportunity ----------
            OppMatch match = findSameOpenOpportunity(client.Id, role, responsibilities, skills, qualifications);
            Opportunity opp = null;
            String possibleNote = null;
            if (match != null && match.same) {
                opp = match.opp;
            } else if (match != null) {
                if (jdDecision == DECISION_EXISTING) {
                    opp = match.opp;
                } else if (jdDecision != DECISION_NEW) {
                    String createdOn = match.opp.CreatedDate == null ? '' : ' on ' + match.opp.CreatedDate.format('dd MMM yyyy');
                    if (askOnPossible) {
                        IntakeProcessor.PossibleDuplicateJdException pd = new IntakeProcessor.PossibleDuplicateJdException(
                            POSSIBLE_DUPLICATE_PREFIX + 'the open Opportunity "' + match.opp.Name + '" for ' + client.Name
                            + ' has the same role and was created' + createdOn + '. The job text differs, so it may be the same '
                            + 'requirement or a new one. Choose "Use existing Opportunity" or "Create new Opportunity".');
                        pd.opportunityId = match.opp.Id;
                        pd.accountId = client.Id;
                        throw pd;
                    }
                    possibleNote = ' Possible duplicate of the open Opportunity "' + match.opp.Name + '" created' + createdOn
                        + ' (same role); please check and merge if it is the same requirement.';
                }
            }
            Boolean isNewOpp = opp == null;
            if (isNewOpp) {
                opp = new Opportunity(
                    AccountId = client.Id,
                    Name = (role != null ? role : companyName + ' - ' + Date.today().format()).left(120),
                    StageName = 'Discovery',
                    CloseDate = closeDate != null && closeDate >= Date.today() ? closeDate : Date.today().addMonths(1),
                    OwnerId = ownerId,
                    Date_Received__c = Date.today()
                );
                if (resourcingRt != null) opp.RecordTypeId = resourcingRt;
            }

            setIfBlank(opp, 'Role_Required__c', role);
            setIfBlank(opp, 'Skills_Required__c', skills);
            setIfBlank(opp, 'Job_Location__c', joinNonBlank(prefLocation, otherLocation));
            setIfBlank(opp, 'Job_Duration__c', duration == null ? null : duration.left(255));
            setIfBlank(opp, 'Experience_Required__c', experience == null ? null : String.valueOf(experience));
            setIfBlank(opp, 'Resource_Needed__c', resources);
            setIfBlank(opp, 'Start_Date__c', startDate);
            setIfBlank(opp, 'Job_type__c', jobType);
            setIfBlank(opp, 'Required_Qualifications__c', qualifications);
            setIfBlank(opp, 'Source_Of_Requirement__c', source);
            setIfBlank(opp, 'Job_Description__c', responsibilities);
            if (svc != null) setIfBlank(opp, 'Source_Content__c', svc.Email_Body__c);
            applyBudget(opp, jd, responsibilities, qualifications, rates);
            applyReferral(opp, AiJson.str(jd, 'referralContact'));

            if (isNewOpp) insert opp; else update opp;

            // ---------- job description record ----------
            Job_Description__c jdRec = null;
            if (opp.JD_Lookup__c != null) {
                List<Job_Description__c> l = [
                    SELECT Id, Name, Company_Name__c, Key_Responsibilities__c, Preferred_Location__c, Other_Location__c,
                           Experience__c, Skills__c, AR__c, Job_Tagline__c, Seniority__c, Required_Qualifications__c,
                           FileName__c, Source_Service__c
                    FROM Job_Description__c WHERE Id = :opp.JD_Lookup__c LIMIT 1
                ];
                if (!l.isEmpty()) jdRec = l[0];
            }
            Boolean isNewJd = jdRec == null;
            if (isNewJd) {
                jdRec = new Job_Description__c(
                    Opportunity__c = opp.Id,
                    Name = (title != null ? title : opp.Name).left(80),
                    Status__c = 'Draft'
                );
            }
            setIfBlank(jdRec, 'Company_Name__c', companyName);
            setIfBlank(jdRec, 'Key_Responsibilities__c', responsibilities);
            setIfBlank(jdRec, 'Preferred_Location__c', prefLocation == null ? null : prefLocation.left(250));
            setIfBlank(jdRec, 'Other_Location__c', otherLocation == null ? null : otherLocation.left(250));
            setIfBlank(jdRec, 'Experience__c', experience);
            setIfBlank(jdRec, 'Skills__c', skills);
            setIfBlank(jdRec, 'AR__c', resources);
            setIfBlank(jdRec, 'Job_Tagline__c', left(AiJson.str(jd, 'tagline'), 255));
            setIfBlank(jdRec, 'Seniority__c', seniority);
            setIfBlank(jdRec, 'Required_Qualifications__c', qualifications);
            setIfBlank(jdRec, 'FileName__c', left(fileTitle, 255));
            if (serviceId != null) setIfBlank(jdRec, 'Source_Service__c', serviceId);
            if (isNewJd) insert jdRec; else update jdRec;

            // ---------- link JD to opportunity, request matching once ----------
            Boolean oppChanged = false;
            if (opp.JD_Lookup__c != jdRec.Id) { opp.JD_Lookup__c = jdRec.Id; oppChanged = true; }
            if (opp.Generate_Match__c == null && String.isNotBlank(opp.Job_Description__c) && queueableRoom > 0) {
                // OpportunityTrigger enqueues one OpportunityMatchJob per opportunity
                opp.Generate_Match__c = 'Generate Match';
                queueableRoom--;
                oppChanged = true;
            }
            if (oppChanged) needMatch.add(opp);

            // ---------- files: link the uploaded JD to the Opportunity and the JD record ----------
            newLinks.addAll(linksFor(serviceFiles, new List<Id>{ opp.Id, jdRec.Id }));

            if (res.opportunityId == null) {
                res.accountId = client.Id;
                res.opportunityId = opp.Id;
                res.jobDescriptionId = jdRec.Id;
            }
            res.legacy.add(client.Name);
            res.legacy.add(String.valueOf(opp.Id));
            summaries.add((isNewOpp ? 'Created Opportunity ' : 'Updated open Opportunity ') + opp.Name + ' for ' + client.Name
                + (possibleNote == null ? '' : '.' + possibleNote.removeEnd('.')));
        }

        if (!needMatch.isEmpty()) update needMatch;
        if (!newLinks.isEmpty()) insert newLinks;

        res.summary = String.join(summaries, '. ') + '.';
        return res;
    }

    // =====================================================================
    // Matching
    // =====================================================================

    @TestVisible
    private static String normalizeCompany(String name) {
        if (name == null) return '';
        List<String> kept = new List<String>();
        for (String w : name.toLowerCase().replaceAll('[^a-z0-9 ]', ' ').split('\\s+')) {
            if (w != '' && !COMPANY_SUFFIXES.contains(w)) kept.add(w);
        }
        return String.join(kept, ' ');
    }

    private static Account findOrCreateClient(String companyName, Id clientRt) {
        String norm = normalizeCompany(companyName);
        String firstWord = norm.contains(' ') ? norm.substringBefore(' ') : norm;
        if (String.isBlank(firstWord)) firstWord = companyName;
        String likeKey = firstWord + '%';
        for (Account a : [
            SELECT Id, Name, RecordType.DeveloperName FROM Account
            WHERE Name LIKE :likeKey
            ORDER BY CreatedDate ASC LIMIT 200
        ]) {
            if (a.RecordType != null && PERSON_RTS.contains(a.RecordType.DeveloperName)) continue;
            if (normalizeCompany(a.Name) == norm) return a;
        }
        Account acc = new Account(Name = companyName.left(255), Account_Type__c = 'Customer');
        if (clientRt != null) acc.RecordTypeId = clientRt;
        Database.DMLOptions opts = new Database.DMLOptions();
        opts.DuplicateRuleHeader.allowSave = true;
        Database.insert(acc, opts);
        return acc;
    }

    /** An open Opportunity of the same client: same = reuse it; not same = possible duplicate (same role, other text). */
    public class OppMatch {
        public Opportunity opp;
        public Boolean same = false;
        OppMatch(Opportunity opp, Boolean same) {
            this.opp = opp;
            this.same = same;
        }
    }

    @TestVisible private static final Decimal SAME_ROLE_TEXT_MIN = 0.5;
    @TestVisible private static final Decimal SAME_ROLE_SKILLS_MIN = 0.6;
    @TestVisible private static final Decimal NO_ROLE_TEXT_MIN = 0.8;

    /**
     * T-071. The AI writes the responsibilities in different words on every run, so text alone
     * cannot decide. The role (normalized) is the main key; the text and skills confirm it.
     */
    @TestVisible
    private static OppMatch findSameOpenOpportunity(Id accountId, String role, String jdText, String skills, String quals) {
        String newRole = roleKey(role);
        String newText = joinNonBlankAll(new List<String>{ role, jdText, skills, quals });
        if (newRole == '' && String.isBlank(newText)) return null;
        Datetime since = Datetime.now().addDays(-90);
        OppMatch possible = null;
        for (Opportunity o : [
            SELECT Id, Name, CreatedDate, AccountId, JD_Lookup__c, Job_Description__c, Role_Required__c, Skills_Required__c,
                   Experience_Required__c, Job_Location__c, Source_Content__c, Source_Of_Requirement__c,
                   StageName, Start_Date__c, Amount, Budget_In_JD__c, Currency_Mentioned_In_JD__c,
                   Original_Budget_Amount__c, Original_Currency__c, Job_Duration__c, Resource_Needed__c,
                   Job_type__c, Required_Qualifications__c, Generate_Match__c, Identified_Budget__c,
                   Referral_Contact__c, CloseDate
            FROM Opportunity
            WHERE AccountId = :accountId AND IsClosed = false AND CreatedDate >= :since
            ORDER BY CreatedDate DESC LIMIT 50
        ]) {
            String oldRole = roleKey(o.Role_Required__c);
            Boolean bothHaveRole = newRole != '' && oldRole != '';
            // Different roles are never the same requirement
            if (bothHaveRole && newRole != oldRole) continue;
            String oldText = joinNonBlankAll(new List<String>{
                o.Role_Required__c, o.Job_Description__c, o.Skills_Required__c, o.Required_Qualifications__c
            });
            Decimal textSim = similarity(newText, oldText);
            Boolean same = bothHaveRole
                ? (textSim >= SAME_ROLE_TEXT_MIN || skillSimilarity(skills, o.Skills_Required__c) >= SAME_ROLE_SKILLS_MIN)
                : textSim >= NO_ROLE_TEXT_MIN;
            if (same) return new OppMatch(o, true);
            if (bothHaveRole && possible == null) possible = new OppMatch(o, false); // newest first
        }
        return possible;
    }

    private static final Map<String, String> ROLE_WORDS = new Map<String, String>{
        'sr' => 'senior', 'snr' => 'senior', 'jr' => 'junior', 'jnr' => 'junior',
        'dev' => 'developer', 'developers' => 'developer', 'engg' => 'engineer', 'engr' => 'engineer', 'engineers' => 'engineer',
        'mgr' => 'manager', 'admin' => 'administrator', 'sfdc' => 'salesforce', 'sf' => 'salesforce',
        'consultants' => 'consultant', 'analysts' => 'analyst', 'architects' => 'architect', 'qa' => 'quality'
    };
    private static final Set<String> ROLE_FILLER = new Set<String>{
        'role', 'position', 'opening', 'openings', 'vacancy', 'requirement', 'hiring', 'urgent', 'job',
        'for', 'the', 'a', 'an', 'of', 'and', 'with', 'in', 'at', 'needed', 'required'
    };

    /** Role compared word by word, any order, common short forms expanded: "Sr. SFDC Dev" = "Senior Salesforce Developer". */
    @TestVisible
    private static String roleKey(String role) {
        if (String.isBlank(role)) return '';
        List<String> out = new List<String>();
        for (String w : normalizeText(role).split(' ')) {
            if (w == '') continue;
            String v = ROLE_WORDS.containsKey(w) ? ROLE_WORDS.get(w) : w;
            if (!ROLE_FILLER.contains(v) && !out.contains(v)) out.add(v);
        }
        out.sort();
        return String.join(out, ' ');
    }

    /** Overlap of the listed skills ("Apex, LWC, REST API"), 0..1. */
    @TestVisible
    private static Decimal skillSimilarity(String a, String b) {
        Set<String> s1 = skillSet(a), s2 = skillSet(b);
        if (s1.isEmpty() || s2.isEmpty()) return 0;
        Set<String> inter = new Set<String>(s1);
        inter.retainAll(s2);
        Set<String> uni = new Set<String>(s1);
        uni.addAll(s2);
        return Decimal.valueOf(inter.size()) / uni.size();
    }

    private static Set<String> skillSet(String s) {
        Set<String> out = new Set<String>();
        if (String.isBlank(s)) return out;
        for (String p : s.toLowerCase().split('[,;/|\\n]+|\\band\\b')) {
            String v = p.replaceAll('[^a-z0-9+#.]+', ' ').normalizeSpace();
            if (v != '') out.add(v);
        }
        return out;
    }

    /** A JD without a company still counts as a JD when it has at least one of these. */
    private static Boolean hasJobSignals(Map<String, Object> jd) {
        for (String k : new List<String>{ 'skillsRequired', 'experience', 'qualifications', 'seniority',
                'preferredLocation', 'otherLocation', 'jobType', 'duration' }) {
            if (AiJson.str(jd, k) != null) return true;
        }
        return false;
    }

    private static String joinNonBlankAll(List<String> parts) {
        List<String> kept = new List<String>();
        for (String p : parts) {
            if (String.isNotBlank(p)) kept.add(p);
        }
        return String.join(kept, ' ');
    }

    private static String normalizeText(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('[^a-z0-9]+', ' ').trim();
    }

    /** Jaccard similarity of the words longer than 3 letters (0..1). */
    @TestVisible
    private static Decimal similarity(String a, String b) {
        Set<String> s1 = words(a), s2 = words(b);
        if (s1.isEmpty() || s2.isEmpty()) return 0;
        Set<String> inter = new Set<String>(s1);
        inter.retainAll(s2);
        Set<String> uni = new Set<String>(s1);
        uni.addAll(s2);
        return Decimal.valueOf(inter.size()) / uni.size();
    }

    private static Set<String> words(String s) {
        Set<String> out = new Set<String>();
        for (String w : normalizeText(s).split(' ')) {
            if (w.length() > 3) out.add(w);
        }
        return out;
    }

    // =====================================================================
    // Budget, referral, owner, source
    // =====================================================================

    private static void applyBudget(Opportunity opp, Map<String, Object> jd, String resp, String quals, Map<String, Decimal> rates) {
        if (opp.Original_Budget_Amount__c != null) return; // already set earlier: keep it

        Decimal amount = null;
        String currencyCode = null;
        String budgetText = null;

        String budgetMentioned = AiJson.str(jd, 'budgetMentioned');
        String currencyMentioned = AiJson.str(jd, 'currencyMentioned');
        if (budgetMentioned != null) {
            amount = AiJson.toNumber(budgetMentioned);
            currencyCode = currencyMentioned != null ? currencyMentioned.split('[,\\s]')[0].toUpperCase() : null;
            budgetText = budgetMentioned + (currencyMentioned != null && !budgetMentioned.containsIgnoreCase(currencyMentioned) ? ' ' + currencyMentioned : '');
        } else {
            String text = (resp == null ? '' : resp) + ' ' + (quals == null ? '' : quals);
            Matcher m = Pattern.compile('(?i)([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(USD|OMR|EUR|GBP|INR|AED|SAR)').matcher(text);
            if (m.find()) {
                amount = Decimal.valueOf(m.group(1).replace(',', ''));
                currencyCode = m.group(2).toUpperCase();
                budgetText = m.group(0);
            }
        }
        if (amount != null) {
            opp.Original_Budget_Amount__c = amount;
            opp.Original_Currency__c = currencyCode;
            opp.Currency_Mentioned_In_JD__c = currencyCode;
            opp.Budget_In_JD__c = left(budgetText, 255);
            Decimal rate = currencyCode != null && rates.containsKey(currencyCode) ? rates.get(currencyCode) : null;
            if (rate != null) {
                opp.Amount = (amount * rate).setScale(2);
                if (Schema.SObjectType.Opportunity.fields.getMap().containsKey('CurrencyIsoCode')) opp.put('CurrencyIsoCode', 'INR');
            }
        }
        // opportunityAmount is given in Lakhs (INR)
        Decimal lakhs = AiJson.toNumber(jd.get('opportunityAmount'));
        if (lakhs != null && opp.Identified_Budget__c == null) opp.Identified_Budget__c = lakhs * 100000;
        opp.Budget_Confirmed__c = opp.Amount != null && opp.Amount > 0;
    }

    private static void applyReferral(Opportunity opp, String name) {
        if (name == null || opp.Referral_Contact__c != null) return;
        List<Contact> cs = [SELECT Id FROM Contact WHERE Name = :name LIMIT 2];
        if (cs.size() == 1) opp.Referral_Contact__c = cs[0].Id; // only when unambiguous
    }

    private static Id resolveOwner(Service__c svc) {
        if (svc != null && String.isNotBlank(svc.EmailFrom__c)) {
            List<User> us = [SELECT Id FROM User WHERE Email = :svc.EmailFrom__c AND IsActive = true LIMIT 1];
            if (!us.isEmpty()) return us[0].Id;
        }
        if (svc != null && String.isNotBlank(svc.WhatsappFrom__c)) {
            String p = AiJson.digitsOnly(svc.WhatsappFrom__c);
            for (User u : [SELECT Id, Phone, MobilePhone FROM User WHERE IsActive = true AND (Phone != null OR MobilePhone != null) LIMIT 2000]) {
                if (p != null && (AiJson.digitsOnly(u.Phone) == p || AiJson.digitsOnly(u.MobilePhone) == p)) return u.Id;
            }
        }
        return UserInfo.getUserId();
    }

    private static String sourceOf(Service__c svc) {
        if (svc == null) return null;
        if (String.isNotBlank(svc.EmailFrom__c)) return 'Email';
        if (String.isNotBlank(svc.WhatsappFrom__c)) return 'Whatsapp';
        if (svc.Source_Channel__c == 'UI Upload') return 'Qbay Home Upload';
        return null;
    }

    private static Map<String, Decimal> loadRates() {
        Map<String, Decimal> rates = new Map<String, Decimal>();
        for (Currency_Rates__mdt c : [SELECT Currency_Code__c, INR_Conversion_Rate__c FROM Currency_Rates__mdt]) {
            if (c.Currency_Code__c != null && c.INR_Conversion_Rate__c != null) {
                rates.put(c.Currency_Code__c.trim().toUpperCase(), c.INR_Conversion_Rate__c);
            }
        }
        if (rates.isEmpty()) {
            rates.put('INR', 1);
            rates.put('USD', 88.33);
            rates.put('OMR', 229.78);
            rates.put('EUR', 102.76);
            rates.put('GBP', 117.95);
        }
        return rates;
    }

    // =====================================================================
    // Small helpers
    // =====================================================================

    private static List<ContentDocumentLink> linksFor(List<ContentDocumentLink> files, List<Id> targets) {
        List<ContentDocumentLink> out = new List<ContentDocumentLink>();
        if (files.isEmpty()) return out;
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink f : files) docIds.add(f.ContentDocumentId);
        Set<String> existing = new Set<String>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId, LinkedEntityId FROM ContentDocumentLink
            WHERE ContentDocumentId IN :docIds AND LinkedEntityId IN :targets
        ]) {
            existing.add(l.ContentDocumentId + '|' + l.LinkedEntityId);
        }
        for (Id t : targets) {
            for (Id d : docIds) {
                if (existing.contains(d + '|' + t)) continue;
                out.add(new ContentDocumentLink(ContentDocumentId = d, LinkedEntityId = t, ShareType = 'I', Visibility = 'AllUsers'));
            }
        }
        return out;
    }

    private static void setIfBlank(SObject rec, String field, Object value) {
        if (value == null) return;
        if (value instanceof String && String.isBlank((String) value)) return;
        Object cur = rec.get(field);
        if (cur == null || (cur instanceof String && String.isBlank((String) cur))) rec.put(field, value);
    }

    private static String joinNonBlank(String a, String b) {
        if (String.isBlank(a)) return b;
        if (String.isBlank(b) || a.equalsIgnoreCase(b)) return a;
        return a + '; ' + b;
    }

    private static String left(String s, Integer n) {
        return s == null ? null : s.left(n);
    }

    private static Id rtId(Schema.SObjectType t, String devName) {
        Schema.RecordTypeInfo i = t.getDescribe().getRecordTypeInfosByDeveloperName().get(devName);
        return i == null ? null : i.getRecordTypeId();
    }

    private static Set<String> picklistValues(Schema.SObjectField f) {
        Set<String> out = new Set<String>();
        for (Schema.PicklistEntry e : f.getDescribe().getPicklistValues()) {
            if (e.isActive()) out.add(e.getValue());
        }
        return out;
    }

    private static String matchPicklist(String v, Set<String> allowed) {
        if (v == null) return null;
        for (String a : allowed) {
            if (a.equalsIgnoreCase(v.trim())) return a;
        }
        return null;
    }
}