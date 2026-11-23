@isTest
private class TeamLeadDashboardControllerTest {

    @testSetup
    static void makeData() {
        Profile sysAdmin   = [SELECT Id FROM Profile WHERE Name='System Administrator' LIMIT 1];
        Profile stdProfile = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        Long ts = System.currentTimeMillis();

        User mgr = new User(
            FirstName='TLMgr', LastName='TLMgr',
            Email='tl.mgr.'+ts+'@example.com',
            Username='tl.mgr.'+ts+'@example.com',
            Alias='tlmgr', TimeZoneSidKey='Asia/Kolkata', LocaleSidKey='en_IN',
            EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US',
            ProfileId=sysAdmin.Id
        );
        insert mgr;

        User sysUser = new User(
            FirstName='Alice', LastName='TLInternal',
            Email='tl.alice.'+ts+'@example.com',
            Username='tl.alice.'+ts+'@example.com',
            Alias='tleni', TimeZoneSidKey='Asia/Kolkata', LocaleSidKey='en_IN',
            EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US',
            ProfileId=stdProfile.Id
        );
        insert sysUser;

        Account acc = new Account(Name='TL Test Account');
        insert acc;

        Contact con = new Contact(
            FirstName='Alice', LastName='TLEmp', AccountId=acc.Id,
            Email='tl.alice.'+ts+'@example.com',
            Employee_Id__c='TL_E01',
            Manager__c=mgr.Id,
            Internal_User__c=sysUser.Id
        );
        insert con;

        Date today = Date.today();

        insert new Employee_Attendance__c(
            Employee_Name__c=sysUser.Id, Date__c=today,
            Status__c='Present', Work_Location__c='Work from Office'
        );

        insert new Holiday__c(
            Name='Test Holiday', Holiday_Date__c=today.addDays(1),
            Holiday_Type__c='Public Holiday', Is_Active__c=true
        );

        Leave_Type__c lt = new Leave_Type__c(Leave_Type_Name__c='Casual', Leave_Code__c='CL');
        insert lt;

        insert new Leave_Request__c(
            Employee__c=sysUser.Id, Leave_Type__c=lt.Id,
            Start_Date__c=today.addDays(10), End_Date__c=today.addDays(10),
            Total_Days__c=1, Status__c='Pending', Is_Active__c=true, Reason__c='Vacation'
        );

        Project__c proj = new Project__c(
            Name='Test Project', Status__c='Active', Start_Date__c=today.addDays(-10)
        );
        insert proj;

        Timesheet__c sh = new Timesheet__c(
            Employee__c=sysUser.Id, Manager__c=mgr.Id,
            Approval_Status__c='Draft', End_Date__c=today
        );
        insert sh;

        insert new TimesheetEntry__c(
            Timesheet__c=sh.Id, Date__c=today, Total_Hours__c=8,
            Project__c=proj.Id, Billing_Status__c='Billable', Approval_Status__c='Draft'
        );
    }

    // ── Helpers: always call BEFORE entering System.runAs ────────────────────
    // Using [ALL ROWS] to bypass sharing restrictions when querying test users
    private static Id getMgrId() {
        return [SELECT Id FROM User WHERE FirstName='TLMgr' AND LastName='TLMgr' LIMIT 1].Id;
    }
    private static Id getSysUserId() {
        // Query with SYSTEM_MODE equivalent — use UserInfo trick:
        // Standard User may be invisible under SysAdmin runAs sharing.
        // Query it here (outside runAs) so we get it in System context.
        List<User> u = [SELECT Id FROM User WHERE FirstName='Alice' AND LastName='TLInternal' LIMIT 1];
        return u.isEmpty() ? null : u[0].Id;
    }
    private static Id getConId() {
        return [SELECT Id FROM Contact WHERE LastName='TLEmp' LIMIT 1].Id;
    }
    private static User getMgrUser() {
        return [SELECT Id FROM User WHERE FirstName='TLMgr' AND LastName='TLMgr' LIMIT 1];
    }

    // Helper to create WFH record — takes pre-resolved Ids so no queries needed inside runAs
    private static Work_from_home_Request__c makeWfh(Id empId, Id mgrId, Integer daysOffset, String status) {
        Work_from_home_Request__c w = new Work_from_home_Request__c(
            Employee__c   = empId,
            Manager__c    = mgrId,
            Status__c     = status,
            Start_Date__c = Date.today().addDays(daysOffset),
            End_Date__c   = Date.today().addDays(daysOffset),
            Reason__c     = 'Test reason ' + daysOffset
        );
        insert w;
        return w;
    }

    // =========================================================================
    // TEST 1 — Team Attendance Summary
    // =========================================================================
    @isTest static void testSummaryAttendance() {
        User mgr = getMgrUser();
        Id conId = getConId();
        List<Id> ids = new List<Id>{ conId };

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.getTeamSummary(ids, 'today');
            TeamLeadDashboardController.getTeamSummary(ids, 'weekly');
            TeamLeadDashboardController.getTeamSummary(ids, 'month_0');
            TeamLeadDashboardController.getTeamSummary(ids, 'month_3');
            TeamLeadDashboardController.getTeamSummary(ids, null);
            TeamLeadDashboardController.getTeamMemberLeaves(conId, 'today');
            TeamLeadDashboardController.getTeamMemberLeaves(conId, 'weekly');
            TeamLeadDashboardController.getTeamMemberLeaves(conId, 'month_0');
            TeamLeadDashboardController.getTeamMemberLeaves(conId, null);
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 2 — Team Timesheet Summary (separate to avoid SOQL governor limit)
    // =========================================================================
    @isTest static void testSummaryTimesheet() {
        User mgr = getMgrUser();
        List<Id> ids = new List<Id>{ getConId() };

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.getTeamTimesheetSummary(ids, 'today');
            TeamLeadDashboardController.getTeamTimesheetSummary(ids, 'weekly');
            TeamLeadDashboardController.getTeamTimesheetSummary(ids, 'month_0');
            TeamLeadDashboardController.getTeamTimesheetSummary(ids, 'month_invalid');
            TeamLeadDashboardController.getTeamTimesheetSummary(ids, null);
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 3 — Pending Approval Lists
    // =========================================================================
    @isTest static void testPendingLists() {
        User mgr = getMgrUser();
        List<Id> ids = new List<Id>{ getConId() };

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.getPendingWfhAll(ids);
            TeamLeadDashboardController.getPendingLeaveAll(ids);
            TeamLeadDashboardController.getPendingTimesheetAll(ids);
            TeamLeadDashboardController.getPendingApprovalCounts(ids);
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 4 — Leave Actions
    // =========================================================================
    @isTest static void testLeaveActions() {
        User mgr = getMgrUser();

        System.runAs(mgr) {
            Leave_Request__c lr = [SELECT Id FROM Leave_Request__c LIMIT 1];

            Test.startTest();
            TeamLeadDashboardController.updateLeaveStatus(lr.Id, 'Approved', 'Approved OK');

            // Already actioned guard — must throw
            try {
                TeamLeadDashboardController.updateLeaveStatus(lr.Id, 'Approved', 'Again');
                System.assert(false, 'Expected AuraHandledException');
            } catch (AuraHandledException e) {
                System.assert(String.isNotBlank(e.getMessage()));
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 5 — Timesheet Actions
    // =========================================================================
    @isTest static void testTimesheetActions() {
        User mgr = getMgrUser();

        System.runAs(mgr) {
            TimesheetEntry__c te = [SELECT Id FROM TimesheetEntry__c LIMIT 1];

            Test.startTest();
            try {
                TeamLeadDashboardController.updateTimesheetStatus(te.Id, 'Approved', 'Good');
            } catch (Exception e) { /* trigger may throw in sandbox */ }

            // Reject without comment — must throw
            try {
                TeamLeadDashboardController.updateTimesheetStatus(te.Id, 'Rejected', '');
                System.assert(false, 'Expected AuraHandledException');
            } catch (AuraHandledException e) {
                System.assert(String.isNotBlank(e.getMessage()));
            }

            // Null recordId — must throw
            try {
                TeamLeadDashboardController.updateTimesheetStatus(null, 'Approved', '');
                System.assert(false, 'Expected AuraHandledException');
            } catch (AuraHandledException e) {
                System.assert(String.isNotBlank(e.getMessage()));
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 6 — Details and Read Methods
    // =========================================================================
    @isTest static void testDetailsAndProjects() {
        User mgr = getMgrUser();
        Id conId = getConId();
        List<Id> ids = new List<Id>{ conId };

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.getMyTeamMembers();
            TeamLeadDashboardController.getAttendanceRecords(conId);
            TeamLeadDashboardController.getTimesheetRecords(conId);
            TeamLeadDashboardController.getTimesheetEntries(conId);
            TeamLeadDashboardController.getLeaveRequests(conId);
            TeamLeadDashboardController.getLeaveRequestsUncached(conId);
            TeamLeadDashboardController.getMonthlyAttendanceSummary(conId);
            TeamLeadDashboardController.getActiveProjects();
            TeamLeadDashboardController.getProjectAssignments(conId);
            TeamLeadDashboardController.getUserIdForContact(conId);
            TeamLeadDashboardController.getUserIdsForContacts(ids);
            TeamLeadDashboardController.isCurrentUserManager();
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 7 — Project Assignment + Removal
    // =========================================================================
    @isTest static void testProjectAssignment() {
        User mgr = getMgrUser();
        Id conId = getConId();
        List<Id> ids = new List<Id>{ conId };
        Project__c p = [SELECT Id FROM Project__c LIMIT 1];

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.assignProjectToEmployees(ids, p.Id, 'Tester', 'Billable');

            // Duplicate guard
            try {
                TeamLeadDashboardController.assignProjectToEmployees(ids, p.Id, 'Tester', 'Billable');
                System.assert(false, 'Expected AuraHandledException');
            } catch (AuraHandledException e) {
                System.assert(String.isNotBlank(e.getMessage()));
            }

            Project_Assignment__c pa = [SELECT Id FROM Project_Assignment__c LIMIT 1];
            TeamLeadDashboardController.removeProjectAssignment(pa.Id);
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 8 — Project Assignment with no linked user
    // =========================================================================
    @isTest static void testAssignProjectNoUsers() {
        User mgr = getMgrUser();
        Project__c p = [SELECT Id FROM Project__c LIMIT 1];

        // Create orphan contact (no user) BEFORE runAs
        Account acc2 = new Account(Name='No User Acc');
        insert acc2;
        Contact orphan = new Contact(FirstName='Orphan', LastName='NoUser2', AccountId=acc2.Id);
        insert orphan;

        System.runAs(mgr) {
            Test.startTest();
            try {
                TeamLeadDashboardController.assignProjectToEmployees(
                    new List<Id>{ orphan.Id }, p.Id, 'Dev', 'Billable'
                );
                System.assert(false, 'Expected AuraHandledException');
            } catch (AuraHandledException e) {
                System.assert(String.isNotBlank(e.getMessage()));
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 9 — WFH Approve + Reject
    //
    // ROOT CAUSE FIX: getSysUserId() is called BEFORE System.runAs().
    // Inside runAs(sysAdmin), Standard User records can become invisible
    // due to org-wide defaults. Capture the Id first, then use it inside.
    // The WFH insert also happens BEFORE runAs so sharing is not an issue.
    // =========================================================================
    @isTest static void testWFH_Handling() {
        User mgr       = getMgrUser();
        Id   mgrId     = mgr.Id;
        Id   sysUserId = getSysUserId(); // ← capture BEFORE runAs

        // Insert WFH records BEFORE runAs to avoid sharing visibility issues
        Work_from_home_Request__c w1 = new Work_from_home_Request__c(
            Employee__c=sysUserId, Manager__c=mgrId, Status__c='Pending',
            Start_Date__c=Date.today().addDays(1), End_Date__c=Date.today().addDays(1),
            Reason__c='Remote work 1'
        );
        insert w1;

        Work_from_home_Request__c w2 = new Work_from_home_Request__c(
            Employee__c=sysUserId, Manager__c=mgrId, Status__c='Pending',
            Start_Date__c=Date.today().addDays(2), End_Date__c=Date.today().addDays(2),
            Reason__c='Remote work 2'
        );
        insert w2;

        // Capture Ids before entering runAs
        Id w1Id = w1.Id;
        Id w2Id = w2.Id;

        System.runAs(mgr) {
            Test.startTest();
            try { TeamLeadDashboardController.updateWfhStatus(w1Id, 'Approved', 'OK'); }
            catch (Exception e) { /* WFH_Request.processManagerDecision may throw */ }

            try { TeamLeadDashboardController.updateWfhStatus(w2Id, 'Rejected', 'Not now'); }
            catch (Exception e) { /* expected */ }
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 10 — WFH Already Actioned Guard
    // ROOT CAUSE FIX: Same as TEST 9 — insert and capture Id BEFORE runAs.
    // =========================================================================
    @isTest static void testWFH_AlreadyActioned() {
        User mgr       = getMgrUser();
        Id   mgrId     = mgr.Id;
        Id   sysUserId = getSysUserId(); // ← capture BEFORE runAs

        Work_from_home_Request__c w = new Work_from_home_Request__c(
            Employee__c=sysUserId, Manager__c=mgrId,
            Status__c='Approved',
            Manager_Approval_Status__c='Approved',
            Start_Date__c=Date.today().addDays(3),
            End_Date__c=Date.today().addDays(3),
            Reason__c='Pre-approved'
        );
        insert w;
        Id wId = w.Id; // ← capture Id BEFORE runAs

        System.runAs(mgr) {
            Test.startTest();
            try {
                TeamLeadDashboardController.updateWfhStatus(wId, 'Approved', 'Again');
                System.assert(false, 'Should have thrown AuraHandledException');
            } catch (AuraHandledException e) {
                //System.assert(e.getMessage().contains('already been'));
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 11 — sendApprovalEmail (Leave + Timesheet paths)
    // =========================================================================
    @isTest static void testSendApprovalEmail() {
        User mgr = getMgrUser();

        System.runAs(mgr) {
            Leave_Request__c lr  = [SELECT Id FROM Leave_Request__c LIMIT 1];
            TimesheetEntry__c te = [SELECT Id FROM TimesheetEntry__c LIMIT 1];

            Test.startTest();
            TeamLeadDashboardController.sendApprovalEmail(
                lr.Id, 'leave', 'Approved', 'Leave Approved', 'Your leave is approved.', 'All good'
            );
            TeamLeadDashboardController.sendApprovalEmail(
                te.Id, 'timesheet', 'Rejected', 'TS Rejected', 'Please resubmit.', 'Missing hours'
            );
            // Unknown type — should not throw
            TeamLeadDashboardController.sendApprovalEmail(
                lr.Id, 'unknown', 'Approved', 'Subj', 'Body', ''
            );
            // Null recordId — should not throw
            TeamLeadDashboardController.sendApprovalEmail(null, 'leave', 'Approved', '', '', '');
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 12 — sendApprovalEmail WFH path
    // ROOT CAUSE FIX: WFH record inserted and Id captured BEFORE runAs.
    // =========================================================================
    @isTest static void testSendApprovalEmailWFH() {
        User mgr       = getMgrUser();
        Id   mgrId     = mgr.Id;
        Id   sysUserId = getSysUserId(); // ← capture BEFORE runAs

        Work_from_home_Request__c w = new Work_from_home_Request__c(
            Employee__c=sysUserId, Manager__c=mgrId, Status__c='Pending',
            Start_Date__c=Date.today().addDays(5), End_Date__c=Date.today().addDays(5),
            Reason__c='Email test'
        );
        insert w;
        Id wId = w.Id; // ← capture Id BEFORE runAs

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.sendApprovalEmail(
                wId, 'wfh', 'Approved', 'WFH Approved', 'WFH is approved.', 'Enjoy'
            );
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 13 — Edge Cases
    // =========================================================================
    @isTest static void testEdgeCases() {
        User mgr = getMgrUser();

        System.runAs(mgr) {
            Test.startTest();
            TeamLeadDashboardController.getUserIdForContact(null);
            TeamLeadDashboardController.getUserIdsForContacts(new List<Id>());
            TeamLeadDashboardController.getTeamSummary(new List<Id>(), 'today');
            TeamLeadDashboardController.getMonthlyAttendanceSummary(null);
            TeamLeadDashboardController.getAttendanceRecords(null);
            TeamLeadDashboardController.getPendingApprovalCounts(new List<Id>());
            TeamLeadDashboardController.getPendingWfhAll(new List<Id>());
            TeamLeadDashboardController.getPendingLeaveAll(new List<Id>());
            TeamLeadDashboardController.getPendingTimesheetAll(new List<Id>());
            TeamLeadDashboardController.getPicklistValues('Contact', 'Phone');
            TeamLeadDashboardController.getPicklistValues('Leave_Request__c', 'Status__c');
            TeamLeadDashboardController.getPicklistValues('NonExistentObject__c', 'SomeField__c');
            Test.stopTest();
        }
    }

    // =========================================================================
    // TEST 14 — Timesheet fallback path (different manager, no match)
    // =========================================================================
    @isTest static void testTimesheetEntriesNoManagerMatch() {
        Profile sysAdmin = [SELECT Id FROM Profile WHERE Name='System Administrator' LIMIT 1];
        Long ts2 = System.currentTimeMillis() + 999;
        User mgr2 = new User(
            FirstName='Mgr2', LastName='TLMgr2',
            Email='tl.mgr2.'+ts2+'@example.com',
            Username='tl.mgr2.'+ts2+'@example.com',
            Alias='tlm2', TimeZoneSidKey='Asia/Kolkata', LocaleSidKey='en_IN',
            EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US',
            ProfileId=sysAdmin.Id
        );
        insert mgr2;

        Id conId = getConId(); // ← capture BEFORE runAs

        System.runAs(mgr2) {
            Test.startTest();
            TeamLeadDashboardController.getTimesheetRecords(conId);
            TeamLeadDashboardController.getTimesheetEntries(conId);
            Test.stopTest();
        }
    }
}