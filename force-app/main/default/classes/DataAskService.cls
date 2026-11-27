/**
 * Magic Search v3 (27-11-2026): answer plain-English questions about any standard or custom object,
 * e.g. "how many opportunities were created last week?" -> the list of those Opportunities and the count.
 *
 * 1. Object finder: matches the question's words to object names (all custom objects + common standard ones),
 *    plus recruiter words (clients, jobs, JDs, candidates, interviews, leaves ...).
 * 2. Schema hints: the fields the user can read on the top 3 objects (with picklist values, record types).
 * 3. Einstein (Qbay_Ask_Data prompt) writes one SOQL query from those hints only.
 * 4. Safety: SELECT only, one main object the user can read, no semicolons, LIMIT 200 enforced,
 *    run in USER MODE (the user's own sharing and field access), so nobody sees more than they already could.
 * 5. The count is computed with a COUNT() query of the same filter.
 */
public with sharing class DataAskService {

    public static final String TEMPLATE = 'Qbay_Ask_Data';
    public static final Integer MAX_ROWS = 200;
    @TestVisible private static String mockResponse;

    private static final List<String> STANDARD_OBJECTS = new List<String>{
        'Account', 'Contact', 'Opportunity', 'Lead', 'Case', 'Task', 'Event', 'User', 'Campaign', 'Contract', 'Product2', 'ContentDocument'
    };
    /** Recruiter words -> object. */
    private static final Map<String, String> SYNONYMS = new Map<String, String>{
        'client' => 'Account', 'customer' => 'Account', 'company' => 'Account', 'candidate' => 'Account',
        'employee' => 'Account', 'contractor' => 'Account', 'account' => 'Account',
        'deal' => 'Opportunity', 'requirement' => 'Opportunity', 'opening' => 'Opportunity', 'position' => 'Opportunity',
        'vacancy' => 'Opportunity', 'job' => 'Opportunity', 'opportunity' => 'Opportunity', 'oppty' => 'Opportunity',
        'jd' => 'Job_Description__c', 'description' => 'Job_Description__c',
        'interview' => 'Interview__c', 'match' => 'Job_Match__c', 'shortlist' => 'Presented_Candidate__c',
        'presented' => 'Presented_Candidate__c', 'submission' => 'Presented_Candidate__c',
        'skill' => 'Employee_Skill__c', 'certification' => 'Certification__c', 'certificate' => 'Certification__c',
        'project' => 'Project_Experience__c', 'intake' => 'Service__c', 'upload' => 'Service__c',
        'leave' => 'Leave_Request__c', 'holiday' => 'Holiday__c', 'attendance' => 'Employee_Attendance__c',
        'offer' => 'Candidate__c', 'onboarding' => 'Candidate__c', 'user' => 'User', 'task' => 'Task', 'meeting' => 'Event',
        'lead' => 'Lead', 'case' => 'Case', 'file' => 'ContentDocument', 'document' => 'ContentDocument'
    };
    private static final Set<String> IGNORE_WORDS = new Set<String>{
        'how', 'many', 'much', 'what', 'which', 'who', 'show', 'list', 'give', 'get', 'me', 'all', 'the', 'a', 'an', 'of', 'in',
        'on', 'for', 'with', 'and', 'or', 'were', 'was', 'is', 'are', 'by', 'created', 'last', 'this', 'week', 'month', 'year',
        'today', 'yesterday', 'my', 'our', 'record', 'records', 'count', 'number', 'from', 'to', 'at', 'did', 'do', 'have', 'has'
    };

    public class Column {
        @AuraEnabled public String fieldName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
    }

    public class Answer {
        @AuraEnabled public String title;
        @AuraEnabled public String note;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public List<Column> columns = new List<Column>();
        @AuraEnabled public List<Map<String, Object>> rows = new List<Map<String, Object>>();
        @AuraEnabled public String soql;
    }

    // =====================================================================
    // Entry point
    // =====================================================================

    @AuraEnabled
    public static Answer ask(String question) {
        if (String.isBlank(question)) throw error('Please type a question.');
        if (question.length() > 500) throw error('Please keep the question under 500 characters.');
        List<String> objects = pickObjects(question);
        if (objects.isEmpty()) {
            throw error('I could not tell which records you mean. Try naming them, for example "opportunities", "clients", "interviews" or "job descriptions".');
        }
        String schemaText = describeForPrompt(objects);
        String raw;
        try {
            raw = callPrompt(question, schemaText);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'DataAskService', 'callPrompt');
            throw error('The AI service is not available right now. Please try again in a minute.');
        }
        Map<String, Object> parsed = AiJson.parse(raw);
        String soql = parsed == null ? null : AiJson.str(parsed, 'soql');
        if (soql == null) throw error('The AI could not turn this question into a search. Try rephrasing it with the record name and a date or status.');

        Answer a = new Answer();
        a.title = AiJson.str(parsed, 'title');
        a.note = AiJson.str(parsed, 'note');
        String safe = makeSafe(soql);
        a.soql = safe;
        a.objectApiName = mainObject(safe);
        Schema.DescribeSObjectResult d = Schema.getGlobalDescribe().get(a.objectApiName).getDescribe(SObjectDescribeOptions.DEFERRED);
        a.objectLabel = d.getLabelPlural();
        if (String.isBlank(a.title)) a.title = a.objectLabel;

        List<SObject> records;
        try {
            records = Database.query(safe, AccessLevel.USER_MODE);
            a.totalCount = Database.countQuery(countQueryOf(safe), AccessLevel.USER_MODE);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'DataAskService', 'run: ' + safe.left(200));
            throw error('The search could not run: ' + e.getMessage().left(200) + ' Try rephrasing the question.');
        }
        fillTable(a, records, d);
        return a;
    }

    private static final Pattern DATA_INTENT = Pattern.compile(
        '(?i)\\b(how many|count|number of|created|modified|closed|last|this|today|yesterday|since|between|week|month|year|status|stage|owner|list of|all)\\b');
    private static final Set<String> PEOPLE_OBJECTS = new Set<String>{ 'Account', 'Candidate__c', 'Employee_Skill__c', 'Certification__c', 'Project_Experience__c' };

    /**
     * "people" = find candidates by skills / experience (ranked people search);
     * "data"   = a question about records ("how many opportunities were created last week?").
     */
    @AuraEnabled
    public static String route(String question) {
        if (String.isBlank(question)) return 'people';
        List<String> objects = pickObjects(question);
        if (objects.isEmpty()) return 'people';
        // the best-matching object decides: people objects without a date / count / status word = people search
        if (!PEOPLE_OBJECTS.contains(objects[0])) return 'data';
        return DATA_INTENT.matcher(question).find() ? 'data' : 'people';
    }

    // =====================================================================
    // 1. Object finder
    // =====================================================================

    @TestVisible
    private static List<String> pickObjects(String question) {
        Set<String> words = new Set<String>();
        for (String w : question.toLowerCase().split('[^a-z0-9]+')) {
            if (w.length() < 2 || IGNORE_WORDS.contains(w)) continue;
            words.add(singular(w));
        }
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Map<String, Integer> score = new Map<String, Integer>();
        for (String w : words) {
            if (SYNONYMS.containsKey(w) && gd.containsKey(SYNONYMS.get(w).toLowerCase())) add(score, SYNONYMS.get(w), 3);
        }
        List<String> names = new List<String>(STANDARD_OBJECTS);
        for (String key : gd.keySet()) {
            if (key.endsWith('__c')) names.add(key);
        }
        for (String n : names) {
            List<String> tokens = nameTokens(n);
            if (tokens.isEmpty()) continue;
            Integer hits = 0;
            for (String t : tokens) if (words.contains(t)) hits++;
            if (hits == 0) continue;
            // all words of the object name present = strong match
            add(score, n, hits == tokens.size() ? 2 + hits : hits);
        }
        List<ScoredName> ranked = new List<ScoredName>();
        for (String n : score.keySet()) {
            Schema.SObjectType t = gd.get(n.toLowerCase());
            if (t == null) continue;
            Schema.DescribeSObjectResult d = t.getDescribe(SObjectDescribeOptions.DEFERRED);
            if (!d.isAccessible() || !d.isQueryable()) continue;
            ranked.add(new ScoredName(d.getName(), score.get(n)));
        }
        ranked.sort();
        List<String> out = new List<String>();
        for (Integer i = 0; i < ranked.size() && i < 3; i++) out.add(ranked[i].name);
        return out;
    }

    private class ScoredName implements Comparable {
        String name;
        Integer score;
        ScoredName(String name, Integer score) { this.name = name; this.score = score; }
        public Integer compareTo(Object o) {
            ScoredName b = (ScoredName) o;
            if (score != b.score) return score > b.score ? -1 : 1;
            return name.length() - b.name.length();
        }
    }

    private static void add(Map<String, Integer> m, String k, Integer v) {
        m.put(k, (m.containsKey(k) ? m.get(k) : 0) + v);
    }

    @TestVisible
    private static String singular(String w) {
        if (w.endsWith('ies') && w.length() > 4) return w.left(w.length() - 3) + 'y';
        if (w.endsWith('sses')) return w.left(w.length() - 2);
        if (w.endsWith('es') && (w.endsWith('ches') || w.endsWith('shes') || w.endsWith('xes'))) return w.left(w.length() - 2);
        if (w.endsWith('s') && !w.endsWith('ss') && w.length() > 2) return w.left(w.length() - 1);
        return w;
    }

    /** "Job_Description__c" -> [job, description]; "Product2" -> [product]. */
    private static List<String> nameTokens(String apiName) {
        String s = apiName.removeEnd('__c').replaceAll('([a-z])([A-Z])', '$1_$2').toLowerCase().replaceAll('[0-9]', '');
        List<String> out = new List<String>();
        for (String t : s.split('_+')) if (t.length() >= 2) out.add(t);
        return out;
    }

    // =====================================================================
    // 2. Schema hints for the prompt
    // =====================================================================

    @TestVisible
    private static String describeForPrompt(List<String> objects) {
        List<String> lines = new List<String>{
            'Today: ' + Date.today().format() + ' (' + String.valueOf(Date.today()) + '). User: ' + UserInfo.getName() + '.'
        };
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        for (String o : objects) {
            Schema.DescribeSObjectResult d = gd.get(o.toLowerCase()).getDescribe();
            lines.add('');
            lines.add('Object ' + d.getName() + ' (' + d.getLabel() + ' / ' + d.getLabelPlural() + ')');
            List<String> rts = new List<String>();
            for (Schema.RecordTypeInfo rt : d.getRecordTypeInfos()) {
                if (rt.isActive() && !rt.isMaster()) rts.add(rt.getDeveloperName());
            }
            if (!rts.isEmpty()) lines.add('  Record types (RecordType.DeveloperName): ' + String.join(rts, ', '));
            Integer n = 0;
            for (Schema.SObjectField f : d.fields.getMap().values()) {
                Schema.DescribeFieldResult fd = f.getDescribe();
                if (!fd.isAccessible() || n >= 70) continue;
                String t = String.valueOf(fd.getType()).toLowerCase();
                if (t == 'address' || t == 'location' || t == 'base64' || t == 'encryptedstring') continue;
                String line = '  ' + fd.getName() + ' (' + fd.getLabel() + ', ' + t;
                if (t == 'reference' && fd.getRelationshipName() != null && !fd.getReferenceTo().isEmpty()) {
                    line += ' -> ' + fd.getReferenceTo()[0] + ', use ' + fd.getRelationshipName() + '.Name';
                }
                if (t == 'picklist' || t == 'multipicklist') {
                    List<String> vals = new List<String>();
                    for (Schema.PicklistEntry pe : fd.getPicklistValues()) {
                        if (pe.isActive() && vals.size() < 15) vals.add(pe.getValue());
                    }
                    if (!vals.isEmpty()) line += ': ' + String.join(vals, ' | ');
                }
                lines.add(line + ')');
                n++;
            }
        }
        return String.join(lines, '\n').left(30000);
    }

    // =====================================================================
    // 3. Prompt call
    // =====================================================================

    private static String callPrompt(String question, String schemaText) {
        ConnectApi.WrappedValue q = new ConnectApi.WrappedValue();
        q.value = question;
        ConnectApi.WrappedValue s = new ConnectApi.WrappedValue();
        s.value = schemaText;
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:question' => q, 'Input:schema' => s };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.isPreview = false;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation out = Test.isRunningTest()
            ? CandidateCreationPrompt.fakeOutput(mockResponse)
            : ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, input);
        return CandidateCreationPrompt.textOf(out, 'The AI returned an empty answer.');
    }

    // =====================================================================
    // 4. Safety
    // =====================================================================

    @TestVisible
    private static String makeSafe(String soql) {
        String s = soql.replaceAll('(?i)```(sql)?|`', '').replaceAll('\\s+', ' ').trim().removeEnd(';').trim();
        String u = s.toUpperCase();
        if (!u.startsWith('SELECT ')) throw error('The AI answer was not a search. Try rephrasing the question.');
        if (s.contains(';')) throw error('The AI answer was not a single search. Try rephrasing the question.');
        if (u.countMatches(' FROM ') != 1 || u.contains('(SELECT')) throw error('That question needs a combined search across objects. Ask about one kind of record at a time.');
        if (Pattern.compile('(?i)\\b(FOR UPDATE|FOR VIEW|FOR REFERENCE|UPDATE TRACKING|UPDATE VIEWSTAT|ALL ROWS|TYPEOF)\\b').matcher(s).find()) {
            throw error('That kind of search is not allowed here.');
        }
        String obj = mainObject(s);
        Schema.SObjectType t = Schema.getGlobalDescribe().get(obj.toLowerCase());
        if (t == null || !t.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) throw error('You do not have access to ' + obj + '.');
        // one cap for every answer
        s = s.replaceAll('(?i)\\s+OFFSET\\s+\\d+', '').replaceAll('(?i)\\s+LIMIT\\s+\\d+', '');
        return s + ' LIMIT ' + MAX_ROWS;
    }

    @TestVisible
    private static String mainObject(String soql) {
        Matcher m = Pattern.compile('(?i)\\sFROM\\s+([A-Za-z0-9_]+)').matcher(soql);
        if (!m.find()) throw error('The AI answer did not name an object.');
        return m.group(1);
    }

    @TestVisible
    private static String countQueryOf(String safe) {
        Integer fromPos = safe.toUpperCase().indexOf(' FROM ');
        String rest = safe.substring(fromPos);
        rest = rest.replaceAll('(?i)\\s+ORDER BY\\s.*$', '').replaceAll('(?i)\\s+LIMIT\\s+\\d+.*$', '');
        return 'SELECT COUNT()' + rest;
    }

    // =====================================================================
    // 5. Result table
    // =====================================================================

    private static void fillTable(Answer a, List<SObject> records, Schema.DescribeSObjectResult d) {
        List<String> fieldOrder = selectedFields(a.soql);
        Map<String, Schema.SObjectField> fmap = d.fields.getMap();
        String nameField = null;
        for (Schema.SObjectField f : fmap.values()) {
            if (f.getDescribe().isNameField()) { nameField = f.getDescribe().getName(); break; }
        }
        for (String path : fieldOrder) {
            if (path.equalsIgnoreCase('Id')) continue;
            Column c = new Column();
            c.fieldName = path.replace('.', '_');
            c.label = labelOf(path, fmap);
            c.type = path.contains('.') ? 'text' : typeOf(fmap.get(path.toLowerCase()));
            if (nameField != null && path.equalsIgnoreCase(nameField)) c.type = 'name';
            a.columns.add(c);
        }
        for (SObject r : records) {
            Map<String, Object> row = new Map<String, Object>{ 'Id' => r.Id, 'recordUrl' => '/' + r.Id };
            for (String path : fieldOrder) {
                if (path.equalsIgnoreCase('Id')) continue;
                row.put(path.replace('.', '_'), valueOf(r, path));
            }
            a.rows.add(row);
        }
    }

    private static List<String> selectedFields(String soql) {
        Integer fromPos = soql.toUpperCase().indexOf(' FROM ');
        List<String> out = new List<String>();
        for (String p : soql.substring(7, fromPos).split(',')) {
            String f = p.trim();
            if (f != '' && !out.contains(f)) out.add(f);
        }
        return out;
    }

    private static Object valueOf(SObject r, String path) {
        try {
            SObject cur = r;
            List<String> parts = path.split('\\.');
            for (Integer i = 0; i < parts.size() - 1; i++) {
                cur = cur.getSObject(parts[i]);
                if (cur == null) return null;
            }
            return cur.get(parts[parts.size() - 1]);
        } catch (Exception e) {
            return null;
        }
    }

    private static String labelOf(String path, Map<String, Schema.SObjectField> fmap) {
        if (path.contains('.')) {
            List<String> parts = path.split('\\.');
            return parts[0].replace('__r', '').replace('_', ' ') + ' ' + parts[parts.size() - 1].replace('__c', '').replace('_', ' ');
        }
        Schema.SObjectField f = fmap.get(path.toLowerCase());
        return f == null ? path : f.getDescribe().getLabel();
    }

    private static String typeOf(Schema.SObjectField f) {
        if (f == null) return 'text';
        Schema.DisplayType t = f.getDescribe().getType();
        if (t == Schema.DisplayType.DATE) return 'date';
        if (t == Schema.DisplayType.DATETIME) return 'datetime';
        if (t == Schema.DisplayType.CURRENCY) return 'currency';
        if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.PERCENT) return 'number';
        if (t == Schema.DisplayType.BOOLEAN) return 'boolean';
        return 'text';
    }

    private static AuraHandledException error(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}
