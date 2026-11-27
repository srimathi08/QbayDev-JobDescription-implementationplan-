@isTest
public class OpportunityMatchJob_Test {
    // Since 27-11-2026 OpportunityMatchJob runs the two-stage matching (JobMatchJob). Detailed tests: JobMatchEngine_Test.
    @isTest
    static void runsMatchingForTheJob() {
        Account client = new Account(Name = 'Client Co',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Direct_Customers').getRecordTypeId());
        insert client;
        Account cand = new Account(Name = 'Candidate One', Designation__c = 'Developer',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId());
        insert cand;
        Opportunity opp = new Opportunity(Name = 'Developer', AccountId = client.Id, StageName = 'Discovery',
            CloseDate = Date.today().addDays(10), Skills_Required__c = 'Apex',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Resourcing').getRecordTypeId());
        insert opp;

        Test.startTest();
        System.enqueueJob(new OpportunityMatchJob(opp.Id));
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Job_Match__c WHERE Opportunity_Name__c = :opp.Id AND Candidate_Name__c = :cand.Id]);
    }

    @isTest
    static void noCandidatesIsFine() {
        Test.startTest();
        System.enqueueJob(new OpportunityMatchJob(new List<Id>()));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Job_Match__c]);
    }
}