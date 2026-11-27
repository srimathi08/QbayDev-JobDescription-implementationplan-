@isTest
public class OpportunityMatchJobTest {
    // Since 27-11-2026 matching no longer launches a batch: OpportunityMatchJob runs JobMatchJob (quick fit + AI for the top 10).
    @isTest
    static void testOpportunityMatchJobExecution() {
        Opportunity opp = new Opportunity(Name = 'Test Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(10));
        insert opp;

        Test.startTest();
        Id jobId = System.enqueueJob(new OpportunityMatchJob(opp.Id));
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status);
        System.assertEquals(0, job.NumberOfErrors);
    }
}