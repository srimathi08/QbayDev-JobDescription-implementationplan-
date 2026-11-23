@isTest
public class ProjectBillableHoursRollupHandlerTest {
    
    @testSetup
    static void setupData() {
        // Create standard account and contact
        Account acc = new Account(Name = 'Test Account', Industry = 'IT Services');
        insert acc;
        
        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'Employee',
            AccountId = acc.Id,
            Email = 'test.employee@example.com'
        );
        insert con;
        
        // Create project with estimated hours
        Project__c proj = new Project__c(
            Name = 'Rollup Test Project',
            Status__c = 'Active',
            Estimated_Hours__c = 10.0,
            Total_Logged_Billable_Hours__c = 0.0,
            Alert_75_Percent_Sent__c = false
        );
        insert proj;

        // Assign Employee to Project
        Project_Assignment__c pa = new Project_Assignment__c(
            Employee__c = UserInfo.getUserId(),
            Project__c = proj.Id,
            Employment_Status__c = 'Billable',
            Role__c = 'Developer'
        );
        insert pa;
    }
    
    @isTest
    static void testBillableHoursRollupAndAlert() {
        Project__c proj = [SELECT Id, Estimated_Hours__c, Total_Logged_Billable_Hours__c, Alert_75_Percent_Sent__c FROM Project__c LIMIT 1];
        
        // Create mock Timesheet
        Timesheet__c ts = new Timesheet__c(
            Employee__c = UserInfo.getUserId(),
            Week_Number__c = 34,
            Week_Year__c = 2026,
            Approval_Status__c = 'Draft'
        );
        insert ts;
        
        Test.startTest();
        // Insert Billable Entry under 75% limit (e.g. 5 hours on 10 estimated)
        TimesheetEntry__c te1 = new TimesheetEntry__c(
            Timesheet__c = ts.Id,
            Project__c = proj.Id,
            Date__c = Date.today(),
            Total_Hours__c = 5.0,
            Billing_Status__c = 'Billable',
            Approval_Status__c = 'Approved'
        );
        insert te1;
        
        Project__c checkProj1 = [SELECT Total_Logged_Billable_Hours__c, Alert_75_Percent_Sent__c FROM Project__c WHERE Id = :proj.Id];
        System.assertEquals(5.0, checkProj1.Total_Logged_Billable_Hours__c, 'Billable hours should rollup correctly.');
        System.assertEquals(false, checkProj1.Alert_75_Percent_Sent__c, 'No alert should be fired below 75% limit.');
        
        // Insert Billable Entry reaching 75% limit (e.g. 3 additional hours total 8 hours -> 80%)
        TriggerExecutionGuard.reset();
        TimesheetEntry__c te2 = new TimesheetEntry__c(
            Timesheet__c = ts.Id,
            Project__c = proj.Id,
            Date__c = Date.today(),
            Total_Hours__c = 3.0,
            Billing_Status__c = 'Billable',
            Approval_Status__c = 'Approved'
        );
        insert te2;
        
        Project__c checkProj2 = [SELECT Total_Logged_Billable_Hours__c, Alert_75_Percent_Sent__c FROM Project__c WHERE Id = :proj.Id];
        System.assertEquals(8.0, checkProj2.Total_Logged_Billable_Hours__c, 'Rollup should add up.');
        System.assertEquals(true, checkProj2.Alert_75_Percent_Sent__c, '75% threshold crossed, Alert flag should be set.');
        
        // Verify 100% logging block validation
        TriggerExecutionGuard.reset();
        TimesheetEntry__c te3 = new TimesheetEntry__c(
            Timesheet__c = ts.Id,
            Project__c = proj.Id,
            Date__c = Date.today(),
            Total_Hours__c = 3.0,
            Billing_Status__c = 'Billable',
            Approval_Status__c = 'Approved'
        );
        
        Boolean exceptionThrown1 = false;
        try {
            insert te3; // Reaches 11.0 (>10.0 Estimated)
        } catch (DmlException e) {
            exceptionThrown1 = true;
            System.assert(e.getMessage().contains('Timesheet logging is blocked'), 'Should block insert due to 100% capacity restriction.');
        }
        System.assert(exceptionThrown1, 'Should throw validation exception on logging beyond 100% on te3.');

        // Test project estimated hours extension logic
        proj.Estimated_Hours__c = 15.0; // Increase estimated hours (currently 8.0 logged -> 8/15 = 53% < 75%)
        update proj;

        Project__c checkProj3 = [SELECT Alert_75_Percent_Sent__c FROM Project__c WHERE Id = :proj.Id];
        System.assertEquals(false, checkProj3.Alert_75_Percent_Sent__c, 'Alert flag should reset to false since estimated hours were increased.');
        
        Test.stopTest();
    }
}