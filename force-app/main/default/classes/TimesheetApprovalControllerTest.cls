@IsTest
public class TimesheetApprovalControllerTest {

    // -----------------------------------------------------
    // TEST DATA SETUP
    // -----------------------------------------------------

    @TestSetup
    static void setupData() {

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User manager = new User(
            Alias = 'mgr',
            Email = 'manager@test.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Manager',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'manager' + DateTime.now().getTime() + '@test.com'
        );
        insert manager;

        User employee = new User(
            Alias = 'emp',
            Email = 'employee@test.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Employee',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'employee' + DateTime.now().getTime() + '@test.com'
        );
        insert employee;

        Timesheet__c ts = new Timesheet__c(
            Employee__c = employee.Id,
            Manager__c = manager.Id,
            Week_Number__c = 10,
            Week_Year__c = 2026,
            Approval_Status__c = 'Submitted',
            Submitted_Date__c = DateTime.now(),
            Approval_Token__c = 'VALID_TOKEN',
            Token_Expiry__c = DateTime.now().addDays(1)
        );
        insert ts;

        insert new TimesheetEntry__c(
            Timesheet__c = ts.Id,
            Date__c = Date.today(),
            Total_Hours__c = 8,
            Approval_Status__c = 'Submitted'
        );
    }

    // -----------------------------------------------------
    // MISSING TOKEN
    // -----------------------------------------------------

    @IsTest
    static void testMissingToken() {

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        // No token parameter

        TimesheetApprovalController ctrl = new TimesheetApprovalController();

        System.assertEquals(true, ctrl.showMessage);
        System.assertEquals(false, ctrl.isSuccess);
    }

    // -----------------------------------------------------
    // INVALID TOKEN
    // -----------------------------------------------------

    @IsTest
    static void testInvalidToken() {

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'BAD_TOKEN');

        TimesheetApprovalController ctrl = new TimesheetApprovalController();

        System.assertEquals(true, ctrl.showMessage);
        System.assertEquals(false, ctrl.showForm);
    }

    // -----------------------------------------------------
    // EXPIRED TOKEN
    // -----------------------------------------------------

    @IsTest
    static void testExpiredToken() {

        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        ts.Approval_Token__c = 'EXPIRED_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(-1);
        update ts;

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'EXPIRED_TOKEN');

        TimesheetApprovalController ctrl = new TimesheetApprovalController();

        System.assertEquals(true, ctrl.showMessage);
        System.assertEquals(false, ctrl.isSuccess);
    }

    // -----------------------------------------------------
    // ALREADY PROCESSED
    // -----------------------------------------------------

    @IsTest
    static void testAlreadyProcessed() {

        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        ts.Approval_Status__c = 'Approved';
        ts.Approval_Token__c = 'USED_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(1);
        update ts;

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'USED_TOKEN');

        TimesheetApprovalController ctrl = new TimesheetApprovalController();

        System.assertEquals(true, ctrl.showMessage);
        System.assertEquals(true, ctrl.isSuccess);
    }

    // -----------------------------------------------------
    // UNAUTHORIZED USER
    // -----------------------------------------------------

    @IsTest
    static void testUnauthorizedUser() {

        User randomUser = [SELECT Id FROM User WHERE LastName = 'Employee' LIMIT 1];

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'VALID_TOKEN');

        System.runAs(randomUser) {

            TimesheetApprovalController ctrl = new TimesheetApprovalController();

            System.assertEquals(true, ctrl.showMessage);
            System.assertEquals(false, ctrl.isSuccess);
        }
    }

    // -----------------------------------------------------
    // APPROVE FLOW
    // -----------------------------------------------------

    @IsTest
    static void testApproveTimesheet() {

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'VALID_TOKEN');

        System.runAs(manager) {

            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            ctrl.comments = 'Looks good';

            Test.startTest();
            ctrl.approveTimesheet();
            Test.stopTest();

            Timesheet__c ts = [
                SELECT Approval_Status__c, Approval_Token__c
                FROM Timesheet__c
                LIMIT 1
            ];

            System.assertEquals('Approved', ts.Approval_Status__c);
            System.assertEquals(null, ts.Approval_Token__c);
        }
    }

    @IsTest
    static void testSelectionAndPagination() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        
        // Add more entries to test pagination (need > 5)
        List<TimesheetEntry__c> entries = new List<TimesheetEntry__c>();
        for(Integer i=0; i<10; i++) {
            entries.add(new TimesheetEntry__c(
                Timesheet__c = ts.Id,
                Date__c = Date.today().addDays(i+1),
                Total_Hours__c = 1,
                Approval_Status__c = 'Submitted'
            ));
        }
        insert entries;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'VALID_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            
            // 1. Test Selection Logic
            ctrl.allSelected = false;
            ctrl.toggleSelectAll();
            for(TimesheetApprovalController.EntryWrapper w : ctrl.wrapperEntries) {
                System.assertEquals(false, w.selected, 'All items should be unselected');
            }

            ctrl.allSelected = true;
            ctrl.toggleSelectAll();
            System.assertEquals(true, ctrl.wrapperEntries[0].selected);

            ctrl.wrapperEntries[0].selected = false;
            ctrl.syncAllSelected();
            System.assertEquals(false, ctrl.allSelected, 'allSelected should be false if one item is unchecked');

            // 2. Test Pagination
            System.assertEquals(5, ctrl.paginatedEntries.size(), 'Page size should be 5');
            System.assertEquals(true, ctrl.getHasNext());
            System.assertEquals(false, ctrl.getHasPrevious());
            
            ctrl.nextPage();
            System.assertEquals(2, ctrl.pageNumber);
            System.assertEquals(5, ctrl.paginatedEntries.size());
            
            ctrl.nextPage();
            System.assertEquals(3, ctrl.pageNumber);
            System.assertEquals(1, ctrl.paginatedEntries.size(), 'Last page should have 1 entry (11 total)');

            ctrl.previousPage();
            System.assertEquals(2, ctrl.pageNumber);
        }
    }

    @IsTest
    static void testPartialApprovalLogic() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        insert new TimesheetEntry__c(
            Timesheet__c = ts.Id,
            Date__c = Date.today().addDays(2),
            Total_Hours__c = 4,
            Approval_Status__c = 'Submitted'
        );

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'VALID_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            
            // Unselect the second entry
            ctrl.wrapperEntries[1].selected = false;
            ctrl.wrapperEntries[1].rejectionComment = 'Partial rejection test';
            
            Test.startTest();
            ctrl.partialApprove(); // Approve Selected mode
            Test.stopTest();

            List<TimesheetEntry__c> results = [SELECT Approval_Status__c, Approver_Comments__c FROM TimesheetEntry__c WHERE Timesheet__c = :ts.Id ORDER BY Date__c];
            System.assertEquals('Approved', results[0].Approval_Status__c);
            System.assertEquals('Rejected', results[1].Approval_Status__c);
            System.assertEquals('Partial rejection test', results[1].Approver_Comments__c);
        }
    }

    // -----------------------------------------------------
    // REJECT FLOW
    // -----------------------------------------------------

    @IsTest
    static void testRejectTimesheet() {
        // ... (existing code remains)
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        ts.Approval_Status__c = 'Submitted';
        ts.Approval_Token__c = 'REJECT_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(1);
        update ts;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'REJECT_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            ctrl.comments = 'Fix hours';
            Test.startTest();
            ctrl.rejectTimesheet();
            Test.stopTest();
            Timesheet__c updated = [SELECT Approval_Status__c FROM Timesheet__c LIMIT 1];
            System.assertEquals('Rejected', updated.Approval_Status__c);
        }
    }

    @IsTest
    static void testWHApprovalControllerFlow() {
        TimesheetEntry__c te = [SELECT Id FROM TimesheetEntry__c LIMIT 1];
        te.Approval_Token_WH__c = 'WH_TOKEN';
        te.Token_Expiry_WH__c = DateTime.now().addDays(1);
        te.Approval_Status__c = 'WH Entry - Requested';
        update te;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'WH_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            System.assertEquals(true, ctrl.isWHEntry);
            System.assertNotEquals(0, ctrl.paginatedEntries.size());
            
            Test.startTest();
            ctrl.approveTimesheet();
            Test.stopTest();

            TimesheetEntry__c updated = [SELECT Approval_Status__c FROM TimesheetEntry__c WHERE Id = :te.Id];
            System.assertEquals('WH Entry - Approved', updated.Approval_Status__c);
        }
    }

    @IsTest
    static void testPrevNextPagination() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        List<TimesheetEntry__c> entries = new List<TimesheetEntry__c>{
            new TimesheetEntry__c(Timesheet__c = ts.Id, Date__c = Date.today().addDays(-1), Total_Hours__c = 1, Approval_Token_WH__c = 'PAGINATION_TOKEN', Token_Expiry_WH__c = DateTime.now().addDays(1), Approval_Status__c = 'WH Entry - Requested'),
            new TimesheetEntry__c(Timesheet__c = ts.Id, Date__c = Date.today().addDays(-2), Total_Hours__c = 1, Approval_Token_WH__c = 'PAGINATION_TOKEN', Token_Expiry_WH__c = DateTime.now().addDays(1), Approval_Status__c = 'WH Entry - Requested')
        };
        insert entries;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'PAGINATION_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            ctrl.pageSize = 1; // Force multiple pages
            ctrl.refreshPaginatedEntries();
            
            ctrl.nextPage();
            System.assertNotEquals(1, ctrl.pageNumber);
            
            ctrl.previousPage();
            System.assertEquals(1, ctrl.pageNumber);
            
            System.assertNotEquals(null, ctrl.getEndRecord());
        }
    }

    @IsTest
    static void testTokenScenarios() {
        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        
        System.runAs(manager) {
            // Missing token
            TimesheetApprovalController ctrl1 = new TimesheetApprovalController();
            System.assertEquals(true, ctrl1.showMessage);

            // Invalid token
            ApexPages.currentPage().getParameters().put('token', 'INVALID');
            TimesheetApprovalController ctrl2 = new TimesheetApprovalController();
            System.assertEquals(true, ctrl2.showMessage);
        }
    }

    @IsTest
    static void testPartialSelectionProcess() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        List<TimesheetEntry__c> entries = new List<TimesheetEntry__c>{
            new TimesheetEntry__c(Timesheet__c = ts.Id, Total_Hours__c = 5, Date__c = Date.today().addDays(-1), Approval_Status__c = 'Submitted', Billing_Status__c = 'Billable'),
            new TimesheetEntry__c(Timesheet__c = ts.Id, Total_Hours__c = 3, Date__c = Date.today().addDays(-2), Approval_Status__c = 'Submitted', Billing_Status__c = 'Shadow')
        };
        insert entries;
        
        ts.Approval_Token__c = 'PARTIAL_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(1);
        ts.Approval_Status__c = 'Submitted';
        update ts;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'PARTIAL_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            
            // wrapperEntries is sorted by Date__c
            // wrapperEntries[0] = entries[1] (earlier date)
            // wrapperEntries[1] = entries[0] (later date)
            ctrl.wrapperEntries[0].selected = true; // entries[1] -> Approved
            ctrl.wrapperEntries[1].selected = false; // entries[0] -> Rejected
            
            ctrl.approveTimesheet();
            
            TimesheetEntry__c eDenied = [SELECT Approval_Status__c FROM TimesheetEntry__c WHERE Id = :entries[0].Id];
            TimesheetEntry__c eApproved = [SELECT Approval_Status__c FROM TimesheetEntry__c WHERE Id = :entries[1].Id];
            
            System.assertEquals('Rejected', eDenied.Approval_Status__c);
            System.assertEquals('Approved', eApproved.Approval_Status__c);
        }
    }

    @IsTest
    static void testRejectionBatch() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        insert new TimesheetEntry__c(Timesheet__c = ts.Id, Date__c = Date.today().addDays(-3), Total_Hours__c = 8, Approval_Status__c = 'Submitted');
        
        ts.Approval_Token__c = 'REJECT_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(1);
        ts.Approval_Status__c = 'Submitted';
        update ts;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'REJECT_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            ctrl.comments = 'Needs more detail';
            ctrl.rejectTimesheet();
            
            Timesheet__c updatedTs = [SELECT Approval_Status__c FROM Timesheet__c WHERE Id = :ts.Id];
            System.assertEquals('Rejected', updatedTs.Approval_Status__c);
        }
    }

    @IsTest
    static void testBulkSelection() {
        TimesheetEntry__c te = [SELECT Id, Approval_Token_WH__c FROM TimesheetEntry__c LIMIT 1];
        te.Approval_Token_WH__c = 'BULK_TOKEN';
        te.Token_Expiry_WH__c = DateTime.now().addDays(1);
        te.Approval_Status__c = 'WH Entry - Requested';
        update te;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'BULK_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            ctrl.allSelected = true;
            ctrl.toggleSelectAll();
            System.assertEquals(true, ctrl.allSelected);
            
            ctrl.allSelected = false;
            ctrl.toggleSelectAll();
            System.assertEquals(false, ctrl.allSelected);
        }
    }

    @IsTest
    static void testUnauthorizedAccess() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        ts.Manager__c = null; // Unassigned
        ts.Approval_Token__c = 'UNAUTH_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(1);
        update ts;

        User otherUser = [SELECT Id FROM User WHERE LastName = 'Employee' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'UNAUTH_TOKEN');

        System.runAs(otherUser) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            ctrl.approveTimesheet();
            System.assertEquals(true, ctrl.showMessage);
        }
    }

    @IsTest
    static void testExpiredLink() {
        Timesheet__c ts = [SELECT Id FROM Timesheet__c LIMIT 1];
        ts.Approval_Token__c = 'EXPIRED_TOKEN';
        ts.Token_Expiry__c = DateTime.now().addDays(-1);
        update ts;

        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'EXPIRED_TOKEN');

        TimesheetApprovalController ctrl = new TimesheetApprovalController();
        System.assert(ctrl.message.contains('expired'), 'Message should indicate expiration: ' + ctrl.message);
    }

    @IsTest
    static void testWHMetricsInit() {
        TimesheetEntry__c te = [SELECT Id FROM TimesheetEntry__c LIMIT 1];
        te.Approval_Token_WH__c = 'METRIC_TOKEN';
        te.Token_Expiry_WH__c = DateTime.now().addDays(1);
        te.Approval_Status__c = 'WH Entry - Requested';
        te.Billing_Status__c = 'Billable';
        te.Total_Hours__c = 10;
        update te;

        User manager = [SELECT Id FROM User WHERE LastName = 'Manager' LIMIT 1];
        Test.setCurrentPage(Page.TimesheetApprovalPage);
        ApexPages.currentPage().getParameters().put('token', 'METRIC_TOKEN');

        System.runAs(manager) {
            TimesheetApprovalController ctrl = new TimesheetApprovalController();
            System.assertEquals(10, ctrl.billableHours);
            System.assertEquals(0, ctrl.shadowHours);
            
            // Cover non-billable and shadow
            te.Billing_Status__c = 'Non-Billable';
            update te;
            ctrl = new TimesheetApprovalController();
            System.assertEquals(10, ctrl.nonBillableHours);
            
            te.Billing_Status__c = 'Shadow';
            update te;
            ctrl = new TimesheetApprovalController();
            System.assertEquals(10, ctrl.shadowHours);
        }
    }
}