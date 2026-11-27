/**
 * Matching screen on the Opportunity (opportunityMatches LWC), 27-11-2026.
 * Not cacheable, so Refresh always shows the latest scores.
 */
public with sharing class JobMatchController {

    public class MatchRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String designation;
        @AuraEnabled public String experience;
        @AuraEnabled public String location;
        @AuraEnabled public String recordType;
        @AuraEnabled public Decimal score;
        @AuraEnabled public Decimal quickFit;
        @AuraEnabled public Decimal aiFit;
        @AuraEnabled public String status;
        @AuraEnabled public String explanation;
        @AuraEnabled public String matched;
        @AuraEnabled public String missing;
        @AuraEnabled public String error;
        @AuraEnabled public Datetime scoredOn;
    }

    public class MatchList {
        @AuraEnabled public List<MatchRow> rows = new List<MatchRow>();
        @AuraEnabled public String jobDescription;
        @AuraEnabled public Integer waiting = 0;
        @AuraEnabled public Datetime lastScored;
        @AuraEnabled public Boolean running = false;
    }

    @AuraEnabled
    public static MatchList getMatches(Id opportunityId) {
        MatchList out = new MatchList();
        List<Opportunity> opps = [SELECT Job_Description__c FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1];
        if (opps.isEmpty() || !Schema.sObjectType.Job_Match__c.isAccessible()) return out;
        out.jobDescription = opps[0].Job_Description__c;
        // the user must be able to open the job; the match rows are then read in system mode so new fields work without per-profile access
        String q = 'SELECT Id, Match_Score__c, Quick_Fit_Score__c, AI_Fit_Score__c, Match_Status__c, Explanation__c, '
            + 'Skills_Matched__c, Skills_Missing__c, Error_Message__c, Scored_On__c, '
            + 'Candidate_Name__c, Candidate_Name__r.Name, Candidate_Name__r.Designation__c, '
            + 'Candidate_Name__r.Years_of_Experience__c, Candidate_Name__r.Current_Location__c, Candidate_Name__r.RecordType.Name '
            + 'FROM Job_Match__c WHERE Opportunity_Name__c = :oppId AND Match_Key__c != null '
            + 'ORDER BY Match_Score__c DESC NULLS LAST, Quick_Fit_Score__c DESC NULLS LAST LIMIT 500';
        List<Job_Match__c> matches = Database.queryWithBinds(q, new Map<String, Object>{ 'oppId' => opportunityId }, AccessLevel.SYSTEM_MODE);
        for (Job_Match__c m : matches) {
            MatchRow r = new MatchRow();
            r.id = m.Id;
            r.candidateId = m.Candidate_Name__c;
            r.candidateName = m.Candidate_Name__r.Name;
            r.designation = m.Candidate_Name__r.Designation__c;
            r.experience = m.Candidate_Name__r.Years_of_Experience__c;
            r.location = m.Candidate_Name__r.Current_Location__c;
            r.recordType = m.Candidate_Name__r.RecordType == null ? null : m.Candidate_Name__r.RecordType.Name;
            r.score = m.Match_Score__c;
            r.quickFit = m.Quick_Fit_Score__c;
            r.aiFit = m.AI_Fit_Score__c;
            r.status = m.Match_Status__c;
            r.explanation = m.Explanation__c;
            r.matched = m.Skills_Matched__c;
            r.missing = m.Skills_Missing__c;
            r.error = m.Error_Message__c;
            r.scoredOn = m.Scored_On__c;
            if (m.Match_Status__c == 'Waiting for AI') out.waiting++;
            if (m.Scored_On__c != null && (out.lastScored == null || m.Scored_On__c > out.lastScored)) out.lastScored = m.Scored_On__c;
            out.rows.add(r);
        }
        out.running = ![
            SELECT Id FROM AsyncApexJob
            WHERE ApexClass.Name = 'JobMatchJob' AND Status IN ('Queued', 'Preparing', 'Processing') LIMIT 1
        ].isEmpty();
        return out;
    }

    /** Re-score button: quick fit for everyone again; AI only where the job or the candidate changed. */
    @AuraEnabled
    public static Boolean rescore(Id opportunityId) {
        if (opportunityId == null) throw new AuraHandledException('Open a job first.');
        if (!Schema.sObjectType.Job_Match__c.isUpdateable() || !Schema.sObjectType.Job_Match__c.isCreateable()) {
            throw new AuraHandledException('You do not have access to update job matches.');
        }
        Id jobId = JobMatchJob.enqueueJobs(new List<Id>{ opportunityId });
        if (jobId == null) throw new AuraHandledException('Matching is busy right now. Please try again in a minute.');
        return true;
    }
}