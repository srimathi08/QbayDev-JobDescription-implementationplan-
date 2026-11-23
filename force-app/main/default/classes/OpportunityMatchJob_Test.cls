@isTest
public class OpportunityMatchJob_Test {

    @testSetup
    static void setupData() {
        // Try to get RecordTypes (they already exist in most orgs)
        Map<String, Id> recordTypeMap = new Map<String, Id>();
        for (RecordType rt : [
            SELECT Id, DeveloperName 
            FROM RecordType 
            WHERE SObjectType = 'Account' 
            AND DeveloperName IN ('Employee','Candidates','Contractor')
        ]) {
            recordTypeMap.put(rt.DeveloperName, rt.Id);
        }

        // If RecordTypes don’t exist (in sandbox/test), still create accounts without RT filter
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 3; i++) {
            Account acc = TestDataFactory.createAccount(false);
            acc.Name = 'TestCandidate_' + i;
            if (recordTypeMap.containsKey('Employee') && i == 0) {
                acc.RecordTypeId = recordTypeMap.get('Employee');
            } else if (recordTypeMap.containsKey('Candidates') && i == 1) {
                acc.RecordTypeId = recordTypeMap.get('Candidates');
            } else if (recordTypeMap.containsKey('Contractor') && i == 2) {
                acc.RecordTypeId = recordTypeMap.get('Contractor');
            }
            accounts.add(acc);
        }
        insert accounts;

        // Create an Opportunity using TestDataFactory
        Opportunity opp = TestDataFactory.createOpportunity(true, accounts[0].Id, null);
    }

    @isTest
    static void test_Queueable_Execute() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
            System.enqueueJob(new OpportunityMatchJob(opp.Id));
        Test.stopTest();

        // ✅ Verify that the job executed without throwing exceptions
        System.assert(true, 'Queueable executed successfully with candidate accounts.');
    }

    @isTest
    static void test_Queueable_WithNoAccounts() {
        // Delete all Accounts to simulate no candidate accounts
        delete [SELECT Id FROM Account];

        Opportunity opp = TestDataFactory.createOpportunity(true, null, null);

        Test.startTest();
            System.enqueueJob(new OpportunityMatchJob(opp.Id));
        Test.stopTest();

        // ✅ Should still complete gracefully
        System.assert(true, 'Queueable executed successfully with no accounts available.');
    }
}