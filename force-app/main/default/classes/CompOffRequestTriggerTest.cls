@IsTest
public class CompOffRequestTriggerTest {

    @TestSetup
    static void setupTestData() {
        // Create a standard test profile user representing employee
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'co_test',
            Email = 'compoff_test@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'CompOffTestUser',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'compoff_test_unique_user@example.com',
            Employee_IDs__c = 'CO_9999',
            IsActive = true
        );
        insert u;

        String validHolidayType = Holiday__c.Holiday_Type__c.getDescribe().getPicklistValues().isEmpty() 
            ? 'Public Holiday' 
            : Holiday__c.Holiday_Type__c.getDescribe().getPicklistValues()[0].getValue();

        // Create a Holiday record to trigger holiday comp off creation
        Holiday__c hol = new Holiday__c(
            Name = 'Test New Year Holiday',
            Holiday_Date__c = Date.today(),
            Holiday_Type__c = validHolidayType,
            Is_Active__c = true
        );
        insert hol;

        // Create the 'CO' Leave Type
        Leave_Type__c coLeaveType = new Leave_Type__c(
            Leave_Type_Name__c = 'Comp Off',
            Leave_Code__c = 'CO',
            Is_Active__c = true
        );
        insert coLeaveType;
    }

    @IsTest
    static void testWeekendOrHolidayCheckoutCreatesCompOff() {
        User u = [SELECT Id FROM User WHERE UserName = 'compoff_test_unique_user@example.com' LIMIT 1];

        // 1. Create a Check-In record today (which is set as a holiday in setup)
        Employee_Attendance__c attendance = new Employee_Attendance__c(
            Employee_Name__c = u.Id,
            Date__c = Date.today(),
            Check_In_Time__c = DateTime.now().addHours(-9)
        );
        insert attendance;

        Test.startTest();
        // 2. Perform Check-Out to trigger Comp Off request creation
        attendance.Check_Out_Time__c = DateTime.now();
        update attendance;
        Test.stopTest();

        // Verify that a CompOff_Request__c record was automatically created
        List<CompOff_Request__c> requests = [
            SELECT Id, Employee__c, Status__c, Attendance_Record__c 
            FROM CompOff_Request__c 
            WHERE Employee__c = :u.Id
        ];
        System.assertNotEquals(0, requests.size(), 'CompOff Request should be auto-created upon Holiday checkout.');
        System.assertEquals('Pending', requests[0].Status__c, 'Initial status of auto-created CompOff should be Pending.');
    }

    @IsTest
    static void testCompOffApprovalCreditsLeaveBalance() {
        User u = [SELECT Id FROM User WHERE UserName = 'compoff_test_unique_user@example.com' LIMIT 1];
        Leave_Type__c lt = [SELECT Id FROM Leave_Type__c WHERE Leave_Code__c = 'CO' LIMIT 1];

        // Manually insert a Pending CompOff Request to test approval trigger
        CompOff_Request__c coRequest = new CompOff_Request__c(
            Employee__c = u.Id,
            Status__c = 'Pending',
            Comp_Type__c = 'Full Day'
        );
        insert coRequest;

        Test.startTest();
        // Approve the CompOff Request
        coRequest.Status__c = 'Approved';
        update coRequest;
        Test.stopTest();

        // Verify Expiry Date was set in before update trigger
        CompOff_Request__c approvedRequest = [SELECT Id, Expiry_Date__c FROM CompOff_Request__c WHERE Id = :coRequest.Id];
        System.assertNotEquals(null, approvedRequest.Expiry_Date__c, 'Expiry Date should be set upon approval.');

        // Verify Leave Balance was successfully created/credited in after update trigger
        List<Employee_Leave_Balance__c> balances = [
            SELECT Id, Total_Allocated__c, Available__c, Leave_Type__c 
            FROM Employee_Leave_Balance__c 
            WHERE Employee__c = :u.Id AND Leave_Type__c = :lt.Id
        ];
        System.assertEquals(1, balances.size(), 'An Employee Leave Balance record should be created/updated.');
        System.assertEquals(1.0, balances[0].Total_Allocated__c, 'Leave balance should be credited 1.0 day for a Full Day Comp Off.');
    }
}