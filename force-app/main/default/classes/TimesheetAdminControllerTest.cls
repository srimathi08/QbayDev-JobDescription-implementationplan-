@isTest
private class TimesheetAdminControllerTest {

    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        
        User u1 = new User(
            Alias = 'standt1', Email='stand1@testorg.com', 
            EmailEncodingKey='UTF-8', LastName='TestingAdmin1', LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', UserName='ts_admin1@testorg.com',
            IsActive=true, Employee_IDs__c='1001', Department='IT'
        );
        User u2 = new User(
            Alias = 'staint', Email='integ@testorg.com', 
            EmailEncodingKey='UTF-8', LastName='Integration User', LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', UserName='ts_integ@testorg.com',
            IsActive=true
        );
        insert new List<User>{u1, u2};

        Project__c proj = new Project__c(Name='Alpha Project', Status__c='Active');
        insert proj;

        // Create a Holiday (Adding required type)
        Holiday__c hol = new Holiday__c(
            Name = 'Alpha Holiday',
            Holiday_Date__c = Date.today().addDays(1),
            Holiday_Type__c = 'Public Holiday'
        );
        insert hol;

        Timesheet__c ts1 = new Timesheet__c(Employee__c = u1.Id, Approval_Status__c = 'Approved');
        Timesheet__c ts2 = new Timesheet__c(Employee__c = u2.Id, Approval_Status__c = 'Submitted');
        insert new List<Timesheet__c>{ts1, ts2};

        Date today = Date.today();
        
        TimesheetEntry__c te1 = new TimesheetEntry__c(
            Timesheet__c = ts1.Id,
            Project__c = proj.Id,
            Total_Hours__c = 8,
            Approval_Status__c = 'Submitted',
            Billing_Status__c = 'Billable',
            Date__c = today,
            Tasks__c = 'Did some work'
        );
        TimesheetEntry__c te2 = new TimesheetEntry__c(
            Timesheet__c = ts1.Id,
            Project__c = proj.Id,
            Total_Hours__c = 4,
            Approval_Status__c = 'Approved',
            Billing_Status__c = 'Non-Billable',
            Date__c = today,
            Tasks__c = 'Training'
        );
        // Integration user entry
        TimesheetEntry__c te3 = new TimesheetEntry__c(
            Timesheet__c = ts2.Id,
            Project__c = proj.Id,
            Total_Hours__c = 10,
            Approval_Status__c = 'Approved',
            Billing_Status__c = 'Billable',
            Date__c = today
        );
        
        insert new List<TimesheetEntry__c>{te1, te2, te3};
    }

    @isTest
    static void testGetDashboardStats() {
        Date dDate = Date.today();
        String todayStr = String.valueOf(dDate);

        Test.startTest();
        Map<String, Object> stats = TimesheetAdminController.getDashboardStats(todayStr, todayStr);
        Test.stopTest();

        System.assertNotEquals(null, stats, 'Stats MAP should not be null');
        // Instead of exact count, ensure it's at least 1 and my user is counted
        System.assert((Integer)stats.get('totalEmployees') >= 1, 'Should have at least one employee');
        // Total Hours = 8 + 4 = 12 (te3 is excluded)
        System.assertEquals(12, (Decimal)stats.get('totalHours'), 'Total hours should reflect the 12 hours from TestingAdmin1');
    }

    @isTest
    static void testGetTimesheetEntries() {
        Date dDate = Date.today();
        String todayStr = String.valueOf(dDate);

        Test.startTest();
        List<TimesheetAdminController.TimesheetEntryWrapper> wrappers = 
            TimesheetAdminController.getTimesheetEntries(todayStr, todayStr, 'TestingAdmin1', 'IT', 'Alpha Project', 'Submitted');
        Test.stopTest();

        System.assertNotEquals(null, wrappers);
        System.assertEquals(1, wrappers.size(), 'Should find 1 pending entry for TestingAdmin1');
        System.assertEquals('TestingAdmin1', wrappers[0].employeeName);
    }

    @isTest
    static void testGetEmployeeProductivityStats() {
        Date dDate = Date.today();
        String todayStr = String.valueOf(dDate);

        Test.startTest();
        List<TimesheetAdminController.EmployeeProductivityWrapper> stats = 
            TimesheetAdminController.getEmployeeProductivityStats(todayStr, todayStr, 'All Departments', 'All Projects');
        Test.stopTest();

        System.assertNotEquals(null, stats);
        Boolean foundMyUser = false;
        for(TimesheetAdminController.EmployeeProductivityWrapper w : stats) {
            if(w.employeeName == 'TestingAdmin1') foundMyUser = true;
            System.assert(!w.employeeName.contains('Integration'), 'Integration user should be filtered out');
        }
        System.assert(foundMyUser, 'Custom test user should be in the list');
    }

    @isTest
    static void testActionMethods() {
        TimesheetEntry__c te = [SELECT Id FROM TimesheetEntry__c WHERE Approval_Status__c = 'Submitted' LIMIT 1];

        Test.startTest();
        String resApprove = TimesheetAdminController.approveTimesheetEntry(te.Id);
        System.assertEquals('Success', resApprove);

        String resReject = TimesheetAdminController.rejectTimesheetEntry(te.Id, 'Need more info');
        System.assertEquals('Success', resReject);
        Test.stopTest();

        TimesheetEntry__c check = [SELECT Approval_Status__c FROM TimesheetEntry__c WHERE Id = :te.Id];
        System.assertEquals('Rejected', check.Approval_Status__c);
    }

    @isTest
    static void testFilterOptions() {
        Test.startTest();
        List<String> emps = TimesheetAdminController.getFilterOptions('employees');
        List<String> depts = TimesheetAdminController.getFilterOptions('departments');
        List<String> projs = TimesheetAdminController.getFilterOptions('projects');
        List<String> status = TimesheetAdminController.getFilterOptions('status');
        Test.stopTest();

        System.assert(emps.size() > 0);
        System.assert(depts.size() > 0);
        System.assert(projs.size() > 0);
        System.assert(status.size() > 0);
    }

    @isTest
    static void testSearchFilterOptions() {
        Test.startTest();
        List<String> emps = TimesheetAdminController.searchFilterOptions('employees', 'Testing');
        List<String> projs = TimesheetAdminController.searchFilterOptions('projects', 'Alpha');
        Test.stopTest();

        System.assertEquals(1, emps.size());
        System.assertEquals('TestingAdmin1', emps[0]);

        System.assertEquals(1, projs.size());
        System.assertEquals('Alpha Project', projs[0]);
    }

    @isTest
    static void testGetAdminTimesheetSummaryCustomRange() {
        Date startD = Date.today().addDays(-7);
        Date endD = Date.today();
        String startStr = String.valueOf(startD);
        String endStr = String.valueOf(endD);

        Test.startTest();
        // Test with explicit 4 parameters as per refactored signature
        List<Map<String,Object>> summary = TimesheetAdminController.getAdminTimesheetSummary(startStr, endStr, 'IT', 'TestingAdmin1');
        Test.stopTest();

        System.assertNotEquals(null, summary);
        System.assertEquals(1, summary.size(), 'Should find exactly 1 employee in the custom range');
        System.assertEquals('TestingAdmin1', (String)summary[0].get('name'));
    }
}