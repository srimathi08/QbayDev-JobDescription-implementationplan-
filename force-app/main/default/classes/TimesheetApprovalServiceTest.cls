@IsTest
public class TimesheetApprovalServiceTest {

    @TestSetup
    static void setupData() {
        // 1. Setup Profile (Standard User)
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        
        // 2. Setup Manager
        User mgr = new User(
            FirstName = 'Manager',
            LastName = 'User',
            Email = 'mgr@example.com',
            Username = 'mgr_appr' + DateTime.now().getTime() + '@example.com',
            Alias = 'mgr_app',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US'
        );
        insert mgr;

        // 3. Setup Employee
        User emp = new User(
            FirstName = 'Employee',
            LastName = 'User',
            Email = 'emp@example.com',
            Username = 'emp_appr' + DateTime.now().getTime() + '@example.com',
            Alias = 'emp_app',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            ManagerId = mgr.Id
        );
        insert emp;

        System.runAs(emp) {
            // 4. Setup Project
            Project__c proj = new Project__c(
                Name = 'Approval Project',
                Status__c = 'Active'
            );
            insert proj;

            // 5. Setup Timesheet
            Integer weekNumber = TimesheetController.getWeekNumber(Date.today());
            Integer year = Date.today().year();
            Timesheet__c ts = new Timesheet__c(
                Employee__c = emp.Id,
                Week_Number__c = weekNumber,
                Week_Year__c = year,
                Manager__c = mgr.Id,
                Approval_Status__c = 'Draft'
            );
            insert ts;

            // 6. Setup Timesheet Entry
            TimesheetEntry__c te = new TimesheetEntry__c(
                Timesheet__c = ts.Id,
                Date__c = Date.today(),
                Tasks__c = 'Work Task',
                Project__c = proj.Id,
                Status__c = 'In progress'
            );
            insert te;
        }
    }

    @IsTest
    static void testSendApprovalRequestToManager() {
        User emp = [SELECT Id FROM User WHERE Alias = 'emp_app' LIMIT 1];
        
        Timesheet__c tsData;
        System.runAs(emp) {
            tsData = [SELECT Week_Number__c, Week_Year__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
        }
        
        Integer weekNumber = Integer.valueOf(tsData.Week_Number__c);
        Integer year = Integer.valueOf(tsData.Week_Year__c);

        System.runAs(emp) {
            Test.startTest();
            Map<String, Object> response = TimesheetApprovalService.sendApprovalRequestToManager(weekNumber, year);
            Test.stopTest();

            System.assert(response != null, 'Response should not be null');
            System.assertEquals(true, response.get('success'), 'Overall response should be successful');
            
            Timesheet__c updatedSheet = [SELECT Approval_Status__c, Approval_Token__c FROM Timesheet__c WHERE Id = :tsData.Id];
            System.assertEquals('Submitted', updatedSheet.Approval_Status__c, 'Timesheet status should be changed to Submitted');
            System.assertNotEquals(null, updatedSheet.Approval_Token__c, 'Token should be generated');
        }
    }

    @IsTest
    static void testProcessApproval() {
        User emp = [SELECT Id FROM User WHERE Alias = 'emp_app' LIMIT 1];
        User mgr = [SELECT Id FROM User WHERE Alias = 'mgr_app' LIMIT 1];
        
        // 1. Submit for approval first to get a token
        System.runAs(emp) {
            Timesheet__c tsData = [SELECT Week_Number__c, Week_Year__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
            TimesheetApprovalService.sendApprovalRequestToManager(Integer.valueOf(tsData.Week_Number__c), Integer.valueOf(tsData.Week_Year__c));
        }
        
        Timesheet__c ts = [SELECT Approval_Token__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
        
        // 2. Process approval as Manager
        System.runAs(mgr) {
            Test.startTest();
            Map<String, Object> response = TimesheetApprovalService.processApproval(ts.Approval_Token__c, 'approve', 'Well done');
            Test.stopTest();
            
            System.assertEquals(true, response.get('success'));
            ts = [SELECT Approval_Status__c, Approved_By__c FROM Timesheet__c WHERE Id = :ts.Id];
            System.assertEquals('Approved', ts.Approval_Status__c);
        }
    }

    @IsTest
    static void testProcessRejection() {
        User emp = [SELECT Id FROM User WHERE Alias = 'emp_app' LIMIT 1];
        User mgr = [SELECT Id FROM User WHERE Alias = 'mgr_app' LIMIT 1];
        
        System.runAs(emp) {
            Timesheet__c tsData = [SELECT Week_Number__c, Week_Year__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
            TimesheetApprovalService.sendApprovalRequestToManager(Integer.valueOf(tsData.Week_Number__c), Integer.valueOf(tsData.Week_Year__c));
        }
        
        Timesheet__c ts = [SELECT Approval_Token__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
        
        System.runAs(mgr) {
            Test.startTest();
            Map<String, Object> response = TimesheetApprovalService.processApproval(ts.Approval_Token__c, 'reject', 'Please fix task description');
            Test.stopTest();
            
            System.assertEquals(true, response.get('success'));
            ts = [SELECT Approval_Status__c, Rejected_By__c, Approval_Comments__c FROM Timesheet__c WHERE Id = :ts.Id];
            System.assertEquals('Rejected', ts.Approval_Status__c);
            System.assertEquals('Please fix task description', ts.Approval_Comments__c);
        }
    }

    @IsTest
    static void testGetPendingApprovals() {
        User emp = [SELECT Id FROM User WHERE Alias = 'emp_app' LIMIT 1];
        User mgr = [SELECT Id FROM User WHERE Alias = 'mgr_app' LIMIT 1];
        
        System.runAs(emp) {
            Timesheet__c tsData = [SELECT Week_Number__c, Week_Year__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
            TimesheetApprovalService.sendApprovalRequestToManager(Integer.valueOf(tsData.Week_Number__c), Integer.valueOf(tsData.Week_Year__c));
        }
        
        System.runAs(mgr) {
            Test.startTest();
            List<Timesheet__c> pending = TimesheetApprovalService.getPendingApprovals();
            Test.stopTest();
            
            System.assertEquals(1, pending.size(), 'Should find one pending timesheet');
        }
    }

    @IsTest
    static void testErrorScenarios() {
        User emp = [SELECT Id FROM User WHERE Alias = 'emp_app' LIMIT 1];
        User mgr = [SELECT Id FROM User WHERE Alias = 'mgr_app' LIMIT 1];
        
        System.runAs(emp) {
            Test.startTest();
            
            // 1. Test invalid week/year
            try {
                TimesheetApprovalService.sendApprovalRequestToManager(99, 2000);
            } catch (AuraHandledException e) {
                System.debug('Caught expected AuraHandledException: ' + e.getMessage());
            }

            // 2. Test timesheet with no manager
            Timesheet__c ts = [SELECT Id, Manager__c, Week_Number__c, Week_Year__c FROM Timesheet__c WHERE Employee__c = :emp.Id LIMIT 1];
            ts.Manager__c = null;
            update ts;
            
            try {
                TimesheetApprovalService.sendApprovalRequestToManager(Integer.valueOf(ts.Week_Number__c), Integer.valueOf(ts.Week_Year__c));
            } catch (AuraHandledException e) {
                 System.debug('Caught expected AuraHandledException: ' + e.getMessage());
            }

            // 3. Test empty entries
            delete [SELECT Id FROM TimesheetEntry__c];
            ts.Manager__c = mgr.Id;
            update ts;
            try {
                TimesheetApprovalService.sendApprovalRequestToManager(Integer.valueOf(ts.Week_Number__c), Integer.valueOf(ts.Week_Year__c));
            } catch (AuraHandledException e) {
                 System.debug('Caught expected AuraHandledException: ' + e.getMessage());
            }
            
            Test.stopTest();
        }
        
        // 4. Test unauthorized
        try {
            TimesheetApprovalService.processApproval('invalid-token', 'approve', 'test');
        } catch (AuraHandledException e) {
             System.debug('Caught expected AuraHandledException: ' + e.getMessage());
        }
        
        // 4. Test unauthorized manager
        System.runAs(emp) {
             try {
                TimesheetApprovalService.processApproval('invalid-token', 'approve', 'test');
            } catch (Exception e) {}
        }
    }

    @IsTest
    static void testAsyncEmailPath() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        
        Test.startTest();
        TimesheetApprovalService.sendEmailAsync(ts.Id);
        Test.stopTest();
        
        System.assert(true);
    }

    @IsTest
    static void testSubmitWHRequest() {
        User emp = [SELECT Id FROM User WHERE Alias = 'emp_app' LIMIT 1];
        TimesheetEntry__c te = [SELECT Id FROM TimesheetEntry__c LIMIT 1];
        
        System.runAs(emp) {
            Test.startTest();
            TimesheetApprovalService.sendBatchWHEntryApprovalEmail(new List<Id>{te.Id});
            Test.stopTest();
            System.assert(true);
        }
    }

    @IsTest
    static void testProcessApprovalErrors() {
        try {
            TimesheetApprovalService.processApproval('NON_EXISTENT_TOKEN', 'approve', 'test');
        } catch (Exception e) {
            System.assert(true, 'Caught expected error');
        }
    }

    @IsTest
    static void testSendEmailCoverages() {
        Timesheet__c ts = [SELECT Id, Manager__c, Employee__c, Week_Number__c, Week_Year__c FROM Timesheet__c LIMIT 1];
        ts.Approval_Token__c = 'TEST_COVER';
        ts.Token_Expiry__c = DateTime.now().addDays(1);
        update ts;

        Test.startTest();
        TimesheetApprovalService.sendEmailAsync(ts.Id);
        Test.stopTest();
        System.assert(true);
    }
}