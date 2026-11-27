/**
 * Magic Search v2 (26-11-2026): plain-English candidate search on Qbay Home.
 *
 * Why it replaced the old path: QbayPromptSearch asked Einstein to write a SOQL query and ran it as-is,
 * without sharing, on any object and with no row limit. Its prompt also points to a schema file
 * (069H1000001P8klIAC) that does not exist in this org, so the AI guessed field names.
 *
 * How it works now:
 *  1. The search text is read with simple rules: "5+ years" / "at least 5 years" -> minimum experience,
 *     the remaining words -> keywords (stop words removed, at most 6).
 *  2. Each keyword is looked up with SOSL in candidate Accounts and in their skills, certifications and projects.
 *  3. Accounts are filtered by record type and experience, ranked by how many keywords they match.
 *  4. Runs with sharing and in user mode, at most 100 results; nothing the user cannot see is returned.
 *  5. Optional AI summary of the top results (existing GeneratedSearch prompt), only when the user asks for it.
 */
public with sharing class CandidateSearchController {

    public static final Integer MAX_RESULTS = 100;
    public static final Integer MAX_KEYWORDS = 6;
    private static final Set<String> ALLOWED_TYPES = new Set<String>{ 'Candidates', 'Employee', 'Contractor' };
    private static final Set<String> STOP_WORDS = new Set<String>{
        'a', 'an', 'the', 'and', 'or', 'of', 'for', 'to', 'in', 'on', 'at', 'with', 'who', 'has', 'have', 'having', 'is', 'are',
        'show', 'find', 'get', 'list', 'me', 'all', 'any', 'some', 'candidate', 'candidates', 'people', 'person', 'profiles',
        'profile', 'resume', 'resumes', 'cv', 'experience', 'experienced', 'exp', 'year', 'years', 'yrs', 'yr', 'plus',
        'least', 'more', 'than', 'above', 'over', 'minimum', 'min', 'good', 'strong', 'knowledge', 'skill', 'skills',
        'skilled', 'working', 'worked', 'want', 'need', 'looking', 'available', 'based', 'from', 'like', 'please'
    };

    public class Result {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String recordType;
        @AuraEnabled public String designation;
        @AuraEnabled public Decimal experience;
        @AuraEnabled public String location;
        @AuraEnabled public String organization;
        @AuraEnabled public List<String> skills = new List<String>();
        @AuraEnabled public List<String> certifications = new List<String>();
        @AuraEnabled public List<String> matched = new List<String>();
        @AuraEnabled public Integer score = 0;
        @AuraEnabled public Id resumeId;
        @AuraEnabled public String resumeTitle;
    }

    public class SearchResponse {
        @AuraEnabled public List<Result> results = new List<Result>();
        @AuraEnabled public List<String> keywords = new List<String>();
        @AuraEnabled public Decimal minYears;
        @AuraEnabled public Integer keywordCount = 0;
    }

    /** Parsed search text. */
    public class Parsed {
        public List<String> keywords = new List<String>();
        public Decimal minYears;
    }

    // =====================================================================
    // Search
    // =====================================================================

    @AuraEnabled
    public static SearchResponse search(String query, List<String> recordTypes) {
        if (String.isBlank(query)) throw error('Please type what you are looking for, for example "Salesforce developer Chennai 5+ years".');
        if (query.length() > 255) throw error('Please use a shorter search (255 characters at most).');
        Set<String> types = new Set<String>();
        if (recordTypes != null) {
            for (String t : recordTypes) if (ALLOWED_TYPES.contains(t)) types.add(t);
        }
        if (types.isEmpty()) types.add('Candidates');

        Parsed p = parse(query);
        SearchResponse resp = new SearchResponse();
        resp.keywords = p.keywords;
        resp.minYears = p.minYears;
        resp.keywordCount = p.keywords.size();

        // 1. Keyword -> accounts that match it (account fields, skills, certifications, projects)
        Map<Id, Set<String>> matchedBy = new Map<Id, Set<String>>();
        for (String kw : p.keywords) {
            for (Id accId : accountsMatching(kw, types)) {
                if (!matchedBy.containsKey(accId)) matchedBy.put(accId, new Set<String>());
                matchedBy.get(accId).add(kw);
            }
        }
        if (!p.keywords.isEmpty() && matchedBy.isEmpty()) return resp;

        // 2. Load the accounts the user may see, with the record type and experience filters
        Set<Id> ids = matchedBy.keySet();
        Decimal minYears = p.minYears;
        String soql = 'SELECT Id, Name, RecordType.DeveloperName, Designation__c, Experience_Years__c, Current_Location__c, '
            + 'Current_Organization__c FROM Account WHERE RecordType.DeveloperName IN :types'
            + (p.keywords.isEmpty() ? '' : ' AND Id IN :ids')
            + (minYears == null ? '' : ' AND Experience_Years__c >= :minYears')
            + ' ORDER BY Experience_Years__c DESC NULLS LAST, LastModifiedDate DESC LIMIT 1000';
        List<Account> accounts = Database.queryWithBinds(soql,
            new Map<String, Object>{ 'types' => types, 'ids' => ids, 'minYears' => minYears }, AccessLevel.USER_MODE);

        // 3. Rank: most keywords matched first, then experience
        List<Result> all = new List<Result>();
        for (Account a : accounts) {
            Result r = new Result();
            r.id = a.Id;
            r.name = a.Name;
            r.recordType = a.RecordType?.DeveloperName == 'Candidates' ? 'Candidate' : a.RecordType?.DeveloperName;
            r.designation = a.Designation__c;
            r.experience = a.Experience_Years__c;
            r.location = a.Current_Location__c;
            r.organization = a.Current_Organization__c;
            if (matchedBy.containsKey(a.Id)) {
                for (String kw : p.keywords) if (matchedBy.get(a.Id).contains(kw)) r.matched.add(kw);
            }
            r.score = r.matched.size();
            all.add(r);
        }
        all.sort(new ByScore());
        for (Integer i = 0; i < all.size() && i < MAX_RESULTS; i++) resp.results.add(all[i]);
        enrich(resp.results);
        return resp;
    }

    /**
     * Ask AI (optional): answers the user's question about the search results, e.g. "Who fits a senior LWC role best?",
     * "How many have Platform Developer I?", or a summary when the question is the search itself.
     * Uses the existing GeneratedSearch prompt with the top 20 results only, so the answer is grounded in real records.
     */
    @AuraEnabled
    public static String summarize(String query, List<Id> accountIds) {
        if (String.isBlank(query) || accountIds == null || accountIds.isEmpty()) throw error('Run a search first.');
        List<Id> top = new List<Id>();
        for (Integer i = 0; i < accountIds.size() && i < 20; i++) top.add(accountIds[i]);
        SearchResponse fake = new SearchResponse();
        for (Account a : [
            SELECT Id, Name, Designation__c, Experience_Years__c, Current_Location__c, Current_Organization__c
            FROM Account WHERE Id IN :top WITH USER_MODE
        ]) {
            Result r = new Result();
            r.id = a.Id;
            r.name = a.Name;
            r.designation = a.Designation__c;
            r.experience = a.Experience_Years__c;
            r.location = a.Current_Location__c;
            r.organization = a.Current_Organization__c;
            fake.results.add(r);
        }
        enrich(fake.results);
        List<Map<String, Object>> compact = new List<Map<String, Object>>();
        for (Result r : fake.results) {
            compact.add(new Map<String, Object>{
                'recordId' => r.id, 'name' => r.name, 'designation' => r.designation, 'experienceYears' => r.experience,
                'location' => r.location, 'currentCompany' => r.organization,
                'skills' => r.skills, 'certifications' => r.certifications
            });
        }
        try {
            String text = Test.isRunningTest() ? mockSummary : QbayPromptSearch.refinePrompt(query, JSON.serialize(compact));
            if (String.isBlank(text)) throw new CalloutException('empty');
            return text;
        } catch (Exception e) {
            UtilityClass.createElog(e, 'CandidateSearchController', 'summarize');
            throw error('The AI summary is not available right now. The search results above are complete without it.');
        }
    }

    @TestVisible private static String mockSummary = '<p>Summary</p>';

    // =====================================================================
    // Helpers
    // =====================================================================

    /** Simple rules: experience phrase -> minimum years; the remaining meaningful words -> keywords. */
    @TestVisible
    private static Parsed parse(String query) {
        Parsed p = new Parsed();
        String q = query.toLowerCase().normalizeSpace();
        Matcher m = Pattern.compile('(?:(?:at least|more than|above|over|min(?:imum)?)\\s*)?(\\d{1,2}(?:\\.\\d)?)\\s*\\+?\\s*(?:years?|yrs?)').matcher(q);
        if (m.find()) {
            p.minYears = Decimal.valueOf(m.group(1));
            q = q.replace(m.group(0), ' ');
        }
        for (String raw : q.split('[^a-z0-9+#.]+')) {
            String w = raw.removeEnd('.').removeStart('.');
            if (w.length() < 2 && w != 'c' && w != 'r') continue;
            if (STOP_WORDS.contains(w) || w.isNumeric()) continue;
            if (!p.keywords.contains(w)) p.keywords.add(w);
            if (p.keywords.size() >= MAX_KEYWORDS) break;
        }
        return p;
    }

    /** Accounts of the given types that match one keyword in their own fields, skills, certifications or projects. */
    private static Set<Id> accountsMatching(String keyword, Set<String> types) {
        String term = escapeSosl(keyword) + (keyword.length() >= 3 && keyword.isAlphanumeric() ? '*' : '');
        // types come from ALLOWED_TYPES only, so they are safe to write into the query
        String typeList = '\'' + String.join(new List<String>(types), '\',\'') + '\'';
        String sosl = 'FIND \'' + term + '\' IN ALL FIELDS RETURNING '
            + 'Account(Id WHERE RecordType.DeveloperName IN (' + typeList + ')), '
            + 'Employee_Skill__c(Employee_Name__c), Certification__c(Candidate_Name__c), Project_Experience__c(Employee_Name__c) '
            + 'LIMIT 500';
        List<List<SObject>> found = Search.query(sosl, AccessLevel.USER_MODE);
        Set<Id> out = new Set<Id>();
        for (SObject a : found[0]) out.add(a.Id);
        for (SObject s : found[1]) if (s.get('Employee_Name__c') != null) out.add((Id) s.get('Employee_Name__c'));
        for (SObject c : found[2]) if (c.get('Candidate_Name__c') != null) out.add((Id) c.get('Candidate_Name__c'));
        for (SObject pe : found[3]) if (pe.get('Employee_Name__c') != null) out.add((Id) pe.get('Employee_Name__c'));
        return out;
    }

    @TestVisible
    private static String escapeSosl(String s) {
        return s.replaceAll('([\\\\?&|!{}\\[\\]()^~*:"\'+\\-])', '\\\\$1');
    }

    /** Top skills, certifications and the latest resume file for each result. */
    private static void enrich(List<Result> results) {
        if (results.isEmpty()) return;
        Map<Id, Result> byId = new Map<Id, Result>();
        for (Result r : results) byId.put(r.id, r);
        Set<Id> ids = byId.keySet();
        for (Employee_Skill__c s : [
            SELECT Employee_Name__c, Name FROM Employee_Skill__c WHERE Employee_Name__c IN :ids WITH USER_MODE ORDER BY CreatedDate ASC LIMIT 2000
        ]) {
            Result r = byId.get(s.Employee_Name__c);
            if (r != null && r.skills.size() < 8 && String.isNotBlank(s.Name)) r.skills.add(s.Name.left(60));
        }
        for (Certification__c c : [
            SELECT Candidate_Name__c, Name FROM Certification__c WHERE Candidate_Name__c IN :ids WITH USER_MODE LIMIT 2000
        ]) {
            Result r = byId.get(c.Candidate_Name__c);
            if (r != null && r.certifications.size() < 5 && String.isNotBlank(c.Name)) r.certifications.add(c.Name.left(80));
        }
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title FROM ContentDocumentLink
            WHERE LinkedEntityId IN :ids ORDER BY ContentDocument.CreatedDate DESC
        ]) {
            Result r = byId.get(l.LinkedEntityId);
            if (r != null && r.resumeId == null) {
                r.resumeId = l.ContentDocumentId;
                r.resumeTitle = l.ContentDocument.Title;
            }
        }
    }

    private class ByScore implements Comparator<Result> {
        public Integer compare(Result a, Result b) {
            if (a.score != b.score) return a.score > b.score ? -1 : 1;
            Decimal ea = a.experience == null ? -1 : a.experience;
            Decimal eb = b.experience == null ? -1 : b.experience;
            if (ea != eb) return ea > eb ? -1 : 1;
            return 0;
        }
    }

    private static AuraHandledException error(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}
