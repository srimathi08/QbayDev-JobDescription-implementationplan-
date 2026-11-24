/**
 * Creates Skill__c (master) and Employee_Skill__c (candidate <-> skill) records.
 * Only the skills named in the resumes are queried; new skills carry a unique Skill_Key__c,
 * so two uploads running at the same time cannot create the same skill twice.
 */
public class CandidateSkillQueueable implements Queueable {

    private static final Set<String> PROFICIENCIES = new Set<String>{ 'Beginner', 'Intermediate', 'Advanced', 'Expert' };

    private List<Account> accounts;
    private List<List<Map<String, Object>>> skillsByResume;

    public CandidateSkillQueueable(List<Account> accounts, List<List<Map<String, Object>>> skillsByResume) {
        this.accounts = accounts;
        this.skillsByResume = skillsByResume;
    }

    public void execute(QueueableContext qc) {
        try {
            run();
        } catch (Exception e) {
            UtilityClass.createElog(e, 'CandidateSkillQueueable', 'execute');
        }
    }

    @TestVisible
    private void run() {
        if (accounts == null || accounts.isEmpty() || skillsByResume == null) return;

        // ---------- names and keys used in these resumes ----------
        Map<String, Map<String, Object>> firstByKey = new Map<String, Map<String, Object>>();
        Set<String> rawNames = new Set<String>();
        for (Integer i = 0; i < accounts.size() && i < skillsByResume.size(); i++) {
            if (skillsByResume[i] == null) continue;
            for (Map<String, Object> s : skillsByResume[i]) {
                String raw = AiJson.str(s, 'name');
                String key = clean(raw);
                if (key == '') continue;
                rawNames.add(raw.left(255));
                if (!firstByKey.containsKey(key)) firstByKey.put(key, s);
            }
        }
        if (firstByKey.isEmpty()) return;

        Map<String, Skill__c> skillMaster = loadSkills(firstByKey.keySet(), rawNames);

        // ---------- new master skills ----------
        List<Skill__c> newSkills = new List<Skill__c>();
        for (String key : firstByKey.keySet()) {
            if (skillMaster.containsKey(key)) continue;
            Map<String, Object> s = firstByKey.get(key);
            newSkills.add(new Skill__c(
                Skill_Name__c = AiJson.str(s, 'name').left(255),
                Skill_Key__c = key.left(255),
                Active__c = true,
                Category__c = AiJson.str(s, 'Category')
            ));
        }
        if (!newSkills.isEmpty()) {
            // allOrNone = false: a parallel run may have just inserted the same key
            Database.insert(newSkills, false);
            skillMaster = loadSkills(firstByKey.keySet(), rawNames);
        }

        // ---------- employee skills ----------
        Map<String, Employee_Skill__c> existingMap = new Map<String, Employee_Skill__c>();
        for (Employee_Skill__c es : [
            SELECT Id, Employee_Name__c, Skill__c, Full_Skill_Name__c, Proficiency__c
            FROM Employee_Skill__c WHERE Employee_Name__c IN :accounts
        ]) {
            existingMap.put(es.Employee_Name__c + '::' + clean(es.Full_Skill_Name__c), es);
        }

        List<Employee_Skill__c> toInsert = new List<Employee_Skill__c>();
        Map<Id, Employee_Skill__c> toUpdate = new Map<Id, Employee_Skill__c>();
        Set<String> seen = new Set<String>();

        for (Integer i = 0; i < accounts.size() && i < skillsByResume.size(); i++) {
            Account acc = accounts[i];
            if (skillsByResume[i] == null) continue;
            for (Map<String, Object> s : skillsByResume[i]) {
                String raw = AiJson.str(s, 'name');
                String norm = clean(raw);
                if (norm == '') continue;
                String key = acc.Id + '::' + norm;
                if (seen.contains(key)) continue;
                seen.add(key);

                Skill__c skillRef = skillMaster.get(norm);
                if (skillRef == null) continue;
                String proficiency = normalizeProficiency(AiJson.str(s, 'proficiency'));

                if (existingMap.containsKey(key)) {
                    Employee_Skill__c ex = existingMap.get(key);
                    if (proficiency != null && ex.Proficiency__c != proficiency) {
                        ex.Proficiency__c = proficiency;
                        toUpdate.put(ex.Id, ex);
                    }
                } else {
                    toInsert.add(new Employee_Skill__c(
                        Name = raw.left(80),
                        Full_Skill_Name__c = raw,
                        Skill__c = skillRef.Id,
                        Employee_Name__c = acc.Id,
                        Proficiency__c = proficiency
                    ));
                }
            }
        }
        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate.values();
    }

    private static Map<String, Skill__c> loadSkills(Set<String> keys, Set<String> rawNames) {
        Map<String, Skill__c> m = new Map<String, Skill__c>();
        for (Skill__c sk : [
            SELECT Id, Skill_Name__c, Skill_Key__c FROM Skill__c
            WHERE Skill_Key__c IN :keys OR Skill_Name__c IN :rawNames
            ORDER BY CreatedDate ASC
        ]) {
            String k = String.isNotBlank(sk.Skill_Key__c) ? sk.Skill_Key__c : clean(sk.Skill_Name__c);
            if (!m.containsKey(k)) m.put(k, sk);
        }
        return m;
    }

    private static String normalizeProficiency(String p) {
        if (p == null) return 'Intermediate';
        for (String v : PROFICIENCIES) {
            if (v.equalsIgnoreCase(p.trim())) return v;
        }
        return 'Intermediate';
    }

    private static String clean(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('[^a-z0-9]', '');
    }
}
