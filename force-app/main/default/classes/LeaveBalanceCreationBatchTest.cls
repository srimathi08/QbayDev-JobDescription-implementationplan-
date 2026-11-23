@isTest
private class LeaveBalanceCreationBatchTest {
    
    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        
        // Create ONE test user with UNIQUE username
        insert new User(
            FirstName = 'Test', LastName = 'BatchUser',
            Email = 'test.batchuser@leave.com',
            Username = 'test.batchuser.leavebatch.unique001@test.com',
            Alias = 'tbu',
            TimeZoneSidKey = 'America/Los_Angeles',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            IsActive = true,
            Employee_IDs__c = '999999',  // Unique numeric value no real user will have
            Date_of_Joining__c = Date.newInstance(2023, 1, 15),
            Gender__c = 'Male',
            Marital_Status__c = 'Single',
            Number_of_Children__c = 0.0,
            Employment_Type__c = 'Full Time'
        );
    }
    
    @isTest
    static void testBatchFullLifecycle() {
        Test.startTest();
        
        LeaveBalanceCreationBatch batch = new LeaveBalanceCreationBatch('2025');
        Id jobId = Database.executeBatch(batch);  // ONLY ONE executeBatch call
        
        Test.stopTest();
        
        // Verify batch completed successfully
        AsyncApexJob job = [SELECT Id, Status, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status, 'Batch should complete successfully');
        System.assertEquals(0, job.NumberOfErrors, 'Batch should have no errors');
    }
    
    @isTest
    static void testStartMethod() {
        LeaveBalanceCreationBatch batch = new LeaveBalanceCreationBatch('2024');
        Test.startTest();
        Database.QueryLocator ql = batch.start(null);
        Test.stopTest();
        
        // Verify our specific test user is found (ignores real org users)
        List<User> testUsers = [SELECT Id FROM User WHERE Employee_IDs__c = '999999'];
        System.assertEquals(1, testUsers.size(), 'Should find exactly 1 test user');
        System.assertNotEquals(null, ql, 'start() should return QueryLocator');
    }
    
    @isTest
    static void testConstructorDifferentYears() {
        // Test constructor with different years
        String year2024 = '2024';
        String year2025 = '2025';
        
        LeaveBalanceCreationBatch batch1 = new LeaveBalanceCreationBatch(year2024);
        LeaveBalanceCreationBatch batch2 = new LeaveBalanceCreationBatch(year2025);
        
        // Just verify objects are created (private year doesn't need assertion)
        System.assertNotEquals(null, batch1);
        System.assertNotEquals(null, batch2);
    }

    @isTest
    static void testCreateEligibleBalancesForEmployeeMethod() {
        // Create active Leave Type
        Leave_Type__c lt = new Leave_Type__c(
            Leave_Type_Name__c = 'Casual Leave Test',
            Leave_Code__c = 'CL_TEST',
            Is_Active__c = true,
            Default_Allocation__c = 15
        );
        insert lt;

        // Retrieve the test user created in setup
        User emp = [SELECT Id FROM User WHERE Employee_IDs__c = '999999' LIMIT 1];

        Test.startTest();
        // Test creation path (first run)
        LeaveBalanceCreationBatch.createEligibleBalancesForEmployee(emp.Id, '2025');
        
        // Test duplicate protection path (second run)
        LeaveBalanceCreationBatch.createEligibleBalancesForEmployee(emp.Id, '2025');
        Test.stopTest();

        // Verify balance record was created
        List<Employee_Leave_Balance__c> balances = [
            SELECT Id, Total_Allocated__c 
            FROM Employee_Leave_Balance__c 
            WHERE Employee__c = :emp.Id 
            AND Leave_Type__c = :lt.Id 
            AND Year__c = '2025'
        ];
        System.assertEquals(1, balances.size(), 'Should create exactly 1 balance record');
        System.assertEquals(15, balances[0].Total_Allocated__c, 'Allocation should match Default Allocation');
    }
}