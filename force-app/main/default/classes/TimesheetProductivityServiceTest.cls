@isTest
private class TimesheetProductivityServiceTest {
    
    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        
        User testUser1 = new User(
            Alias = 'standt1', Email='standarduser1@testorg.com', 
            EmailEncodingKey='UTF-8', LastName='Testing1', LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', UserName='tsadminuser1@testorg.com',
            IsActive=true
        );
        insert testUser1;

        Project__c proj = new Project__c(Name='Test Project', Status__c='Active');
        insert proj;
        
        Timesheet__c ts1 = new Timesheet__c(
            Employee__c = testUser1.Id,
            Approval_Status__c = 'Approved'
        );
        insert ts1;
        
        // Target weekday date (let's assume a static Monday)
        Date targetDate = Date.newInstance(2025, 1, 6); // Jan 6 2025 is a Monday
        
        TimesheetEntry__c te1 = new TimesheetEntry__c(
            Timesheet__c = ts1.Id,
            Project__c = proj.Id,
            Total_Hours__c = 4,
            Approval_Status__c = 'Approved',
            Billing_Status__c = 'Billable',
            Date__c = targetDate
        );
        TimesheetEntry__c te2 = new TimesheetEntry__c(
            Timesheet__c = ts1.Id,
            Project__c = proj.Id,
            Total_Hours__c = 4,
            Approval_Status__c = 'Submitted',
            Billing_Status__c = 'Non-Billable',
            Date__c = targetDate
        );
        insert new List<TimesheetEntry__c>{te1, te2};

        // Create a Holiday
        Holiday__c hol = new Holiday__c(
            Name = 'Test Holiday',
            Holiday_Date__c = Date.newInstance(2025, 1, 10), // Jan 10 is Friday
            Holiday_Type__c = 'Public Holiday'
        );
        insert hol;
        
        // Create a Leave
        Leave_Request__c leave = new Leave_Request__c(
            Employee__c = testUser1.Id,
            Start_Date__c = Date.newInstance(2025, 1, 9), // Thursday
            End_Date__c = Date.newInstance(2025, 1, 9),
            Status__c = 'Approved',
            Is_Half_Day__c = false,
            Total_Days__c = 1
        );
        insert leave;
    }
    
    @isTest
    static void testCalculateBulkProductivity() {
        User testUser = [SELECT Id FROM User WHERE UserName='tsadminuser1@testorg.com' LIMIT 1];
        Set<Id> userIds = new Set<Id>{testUser.Id};
        
        // From Jan 6 (Mon) to Jan 12 (Sun) -> 5 weekdays
        // minus 1 holiday (Friday) -> 4 working days
        // minus 1 leave (Thursday) -> 3 target working days
        // Target hours = 3 * 8 = 24.
        
        Date startDate = Date.newInstance(2025, 1, 6);
        Date endDate = Date.newInstance(2025, 1, 12);
        
        Test.startTest();
        Map<Id, TimesheetProductivityService.ProductivityMetrics> results = TimesheetProductivityService.calculateBulkProductivity(userIds, startDate, endDate);
        Test.stopTest();
        
        System.assertEquals(1, results.size(), 'Should return metrics for 1 user');
        TimesheetProductivityService.ProductivityMetrics metrics = results.get(testUser.Id);
        
        System.assertNotEquals(null, metrics, 'Metrics should not be null');
        System.assertEquals(8, metrics.totalHours, 'Total hours should be 8');
        System.assertEquals(4, metrics.approvedHours, 'Approved hours should be 4');
        System.assertEquals(24, metrics.targetHours, 'Target hours should be 24 (3 days * 8 hours)');
        
        Decimal expectedPct = (4.0 / 24.0 * 100).setScale(1);
        System.assertEquals(expectedPct, metrics.productivityPct, 'Productivity % should calculate correctly');
    }
}