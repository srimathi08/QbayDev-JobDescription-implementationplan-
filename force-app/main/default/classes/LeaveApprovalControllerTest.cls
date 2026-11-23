@isTest
private class LeaveApprovalControllerTest {

    // ===================================================================
    // HELPER: Create test users
    // ===================================================================
    private static User createManager() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User mgr = new User(
            FirstName='Manager', LastName='Leave',
            Email='mgr_leave@testorg.com',
            Username='mgr_leave_' + System.currentTimeMillis() + '@testorg.com',
            Alias='mgrlv', TimeZoneSidKey='America/Los_Angeles',
            LocaleSidKey='en_US', EmailEncodingKey='UTF-8',
            LanguageLocaleKey='en_US', ProfileId=p.Id
        );
        insert mgr;
        return mgr;
    }

    private static User createEmployee(Id managerId) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User emp = new User(
            FirstName='Employee', LastName='Leave',
            Email='emp_leave@testorg.com',
            Username='emp_leave_' + System.currentTimeMillis() + '@testorg.com',
            Alias='emplv', TimeZoneSidKey='America/Los_Angeles',
            LocaleSidKey='en_US', EmailEncodingKey='UTF-8',
            LanguageLocaleKey='en_US', ProfileId=p.Id,
            ManagerId=managerId
        );
        insert emp;
        return emp;
    }

    // ===================================================================
    // HELPER: Create leave type and pending leave request
    // ===================================================================
    private static Leave_Type__c createLeaveType() {
        Leave_Type__c lt = new Leave_Type__c(
            Leave_Type_Name__c = 'Casual Leave',
            Leave_Code__c      = 'CL'
        );
        insert lt;
        return lt;
    }

    private static Leave_Request__c createLeaveRequest(Id empId, Id managerId, Id leaveTypeId, String status) {
        Leave_Request__c lr = new Leave_Request__c(
            Employee__c     = empId,
            Manager__c      = managerId,
            Leave_Type__c   = leaveTypeId,
            Start_Date__c   = Date.today().addDays(5),
            End_Date__c     = Date.today().addDays(6),
            Total_Days__c   = 2,
            Status__c       = status,
            Is_Active__c    = true,
            Reason__c       = 'Test leave reason',
            Applied_Date__c = DateTime.now(),
            Rejection_Reason__c = (status == 'Rejected')  ? 'Test rejection reason'    : null,
            Cancelled_Reason__c = (status == 'Cancelled') ? 'Test cancellation reason' : null
        );
        insert lr;
        return lr;
    }

    // ===================================================================
    // HELPER: Build a PageReference with parameters
    // ===================================================================
    private static PageReference buildPage(String requestId, String managerId) {
        PageReference pg = Page.LeaveApprovalPage;
        if (String.isNotBlank(requestId)) {
            pg.getParameters().put('id',  requestId);
        }
        if (String.isNotBlank(managerId)) {
            pg.getParameters().put('mgr', managerId);
        }
        return pg;
    }

    // ===================================================================
    // TEST: Constructor — blank requestId shows error
    // ===================================================================
    @isTest
    static void testConstructor_BlankRequestId() {
        PageReference pg = Page.LeaveApprovalPage;
        Test.setCurrentPage(pg);

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        System.assertEquals(true,  ctrl.showError,  'showError should be true for blank ID');
        System.assertEquals(false, ctrl.showSuccess, 'showSuccess should be false');
        System.assertNotEquals(null, ctrl.errorMessage, 'errorMessage should not be null');
    }

    // ===================================================================
    // TEST: Constructor — valid requestId, Pending status loads form
    // ===================================================================
    @isTest
    static void testConstructor_ValidPendingRequest() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        System.assertEquals(false, ctrl.showError,   'showError should be false');
        System.assertEquals(false, ctrl.showInfo,    'showInfo should be false for Pending');
        System.assertNotEquals(null, ctrl.leaveRequest, 'leaveRequest should be loaded');
        System.assertEquals('Employee Leave', ctrl.employeeName, 'employeeName should match');
        System.assertEquals('Casual Leave',   ctrl.leaveTypeName, 'leaveTypeName should match');
        System.assertNotEquals(null, ctrl.startDate,  'startDate should not be null');
        System.assertNotEquals(null, ctrl.endDate,    'endDate should not be null');
        System.assertNotEquals(null, ctrl.totalDays,  'totalDays should not be null');
        System.assertEquals('Test leave reason', ctrl.reason, 'reason should match');
    }

    // ===================================================================
    // TEST: Constructor — already Approved status shows info
    // ===================================================================
    @isTest
    static void testConstructor_AlreadyApproved_ShowsInfo() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Approved');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        System.assertEquals(true,  ctrl.showInfo,  'showInfo should be true for already-processed request');
        System.assertEquals(false, ctrl.showError, 'showError should be false');
        System.assertNotEquals(null, ctrl.infoMessage, 'infoMessage should not be null');
        System.assert(ctrl.infoMessage.contains('Approved'), 'infoMessage should mention Approved');
    }

    // ===================================================================
    // TEST: Constructor — already Rejected status shows info
    // ===================================================================
    @isTest
    static void testConstructor_AlreadyRejected_ShowsInfo() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Rejected');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        System.assertEquals(true, ctrl.showInfo, 'showInfo should be true for Rejected');
        System.assert(ctrl.infoMessage.contains('Rejected'), 'infoMessage should mention Rejected');
    }

    // ===================================================================
    // TEST: Constructor — already Cancelled status shows info
    // ===================================================================
    @isTest
    static void testConstructor_AlreadyCancelled_ShowsInfo() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Cancelled');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        System.assertEquals(true, ctrl.showInfo, 'showInfo should be true for Cancelled');
    }

    // ===================================================================
    // TEST: Constructor — invalid/non-existent requestId shows error
    // ===================================================================
    @isTest
    static void testConstructor_InvalidRequestId_ShowsError() {
        PageReference pg = Page.LeaveApprovalPage;
        pg.getParameters().put('id', 'a00000000000001AAA'); // non-existent
        Test.setCurrentPage(pg);

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        System.assertEquals(true, ctrl.showError, 'showError should be true for invalid ID');
        System.assertNotEquals(null, ctrl.errorMessage, 'errorMessage should not be null');
    }

    // ===================================================================
    // TEST: approveRequest — happy path
    // ===================================================================
    @isTest
    static void testApproveRequest_HappyPath() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Approved. Enjoy your leave.';

        Test.startTest();
        PageReference result = ctrl.approveRequest();
        Test.stopTest();

        System.assertEquals(null,       result,           'approveRequest should return null');
        System.assertEquals(true,       ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Approved', ctrl.actionTaken, 'actionTaken should be Approved');
        System.assertEquals(null,       ctrl.leaveRequest,'leaveRequest should be cleared');

        Leave_Request__c updated = [SELECT Status__c, Manager_Comments__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals('Approved',                    updated.Status__c,          'Status should be Approved');
        System.assertEquals('Approved. Enjoy your leave.', updated.Manager_Comments__c,'Comments should be saved');
    }

    // ===================================================================
    // TEST: approveRequest — null leaveRequest (already processed)
    // ===================================================================
    @isTest
    static void testApproveRequest_NullLeaveRequest() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.leaveRequest = null;

        Test.startTest();
        PageReference result = ctrl.approveRequest();
        Test.stopTest();

        System.assertEquals(null, result,         'Should return null');
        System.assertEquals(true, ctrl.showInfo,  'showInfo should be true');
    }

    // ===================================================================
    // TEST: cancelRequest — happy path
    // ===================================================================
    @isTest
    static void testCancelRequest_HappyPath() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Cancelled due to project requirements.';

        Test.startTest();
        PageReference result = ctrl.cancelRequest();
        Test.stopTest();

        System.assertEquals(null,        result,           'cancelRequest should return null');
        System.assertEquals(true,        ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Cancelled', ctrl.actionTaken, 'actionTaken should be Cancelled');
        System.assertEquals(null,        ctrl.leaveRequest,'leaveRequest should be cleared');

        Leave_Request__c updated = [SELECT Status__c, Cancelled_Reason__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals('Cancelled', updated.Status__c, 'Status should be Cancelled');
    }

    // ===================================================================
    // TEST: cancelRequest — null leaveRequest (already processed)
    // ===================================================================
    @isTest
    static void testCancelRequest_NullLeaveRequest() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.leaveRequest = null;

        Test.startTest();
        PageReference result = ctrl.cancelRequest();
        Test.stopTest();

        System.assertEquals(null, result,        'Should return null');
        System.assertEquals(true, ctrl.showInfo, 'showInfo should be true');
    }

    // ===================================================================
    // TEST: rejectRequest — happy path with rejection reason
    // ===================================================================
    @isTest
    static void testRejectRequest_HappyPath() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.rejectionReason = 'Critical project deadline during this period.';

        Test.startTest();
        PageReference result = ctrl.rejectRequest();
        Test.stopTest();

        System.assertEquals(null,       result,           'rejectRequest should return null');
        System.assertEquals(true,       ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Rejected', ctrl.actionTaken, 'actionTaken should be Rejected');
        System.assertEquals(null,       ctrl.leaveRequest,'leaveRequest should be cleared');

        Leave_Request__c updated = [SELECT Status__c, Rejection_Reason__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals('Rejected', updated.Status__c, 'Status should be Rejected');
        System.assertEquals('Critical project deadline during this period.', updated.Rejection_Reason__c);
    }

    // ===================================================================
    // TEST: rejectRequest — blank rejectionReason adds page message
    // ===================================================================
    @isTest
    static void testRejectRequest_BlankReason_AddsMessage() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.rejectionReason = '';

        Test.startTest();
        PageReference result = ctrl.rejectRequest();
        Test.stopTest();

        System.assertEquals(null,  result,           'Should return null without processing');
        System.assertEquals(false, ctrl.showSuccess, 'showSuccess should stay false');

        List<ApexPages.Message> msgs = ApexPages.getMessages();
        System.assert(!msgs.isEmpty(), 'Should have a page message');
        System.assert(msgs[0].getSummary().contains('required'), 'Message should mention required');
    }

    // ===================================================================
    // TEST: rejectRequest — null rejectionReason treated as blank
    // ===================================================================
    @isTest
    static void testRejectRequest_NullReason_AddsMessage() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.rejectionReason = null; // null also treated as blank

        Test.startTest();
        PageReference result = ctrl.rejectRequest();
        Test.stopTest();

        System.assertEquals(null,  result,           'Should return null without processing');
        System.assertEquals(false, ctrl.showSuccess, 'showSuccess should stay false');

        List<ApexPages.Message> msgs = ApexPages.getMessages();
        System.assert(!msgs.isEmpty(), 'Should have a page message for null reason');
    }

    // ===================================================================
    // TEST: rejectRequest — null leaveRequest (already processed)
    // ===================================================================
    @isTest
    static void testRejectRequest_NullLeaveRequest() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.leaveRequest   = null;
        ctrl.rejectionReason = 'Some reason';

        Test.startTest();
        PageReference result = ctrl.rejectRequest();
        Test.stopTest();

        System.assertEquals(null, result,        'Should return null');
        System.assertEquals(true, ctrl.showInfo, 'showInfo should be true');
    }

    // ===================================================================
    // TEST: approveRequest — with manager comments included in email
    // ===================================================================
    @isTest
    static void testApproveRequest_WithManagerComments_EmailSent() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Great! Approved with full pay.';

        Test.startTest();
        ctrl.approveRequest();
        Test.stopTest();

        System.assertEquals(true,       ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Approved', ctrl.actionTaken);
    }

    // ===================================================================
    // TEST: cancelRequest — without manager comments (null comments path)
    // ===================================================================
    @isTest
    static void testCancelRequest_NoComments_NullEmailRow() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = null;

        Test.startTest();
        ctrl.cancelRequest();
        Test.stopTest();

        System.assertEquals(true, ctrl.showSuccess, 'showSuccess should be true');
    }

    // ===================================================================
    // TEST: rejectRequest — verifies Rejected_Date__c set to today
    // ===================================================================
    @isTest
    static void testRejectRequest_SetsRejectedDate() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.rejectionReason = 'Not approved due to staffing.';

        Test.startTest();
        ctrl.rejectRequest();
        Test.stopTest();

        Leave_Request__c updated = [
            SELECT Status__c, Rejected_Date__c, Manager_Comments__c
            FROM Leave_Request__c WHERE Id = :lr.Id
        ];
        System.assertEquals('Rejected',   updated.Status__c,        'Status should be Rejected');
        System.assertEquals(Date.today(), updated.Rejected_Date__c, 'Rejected_Date__c should be today');
        System.assertEquals('Not approved due to staffing.', updated.Manager_Comments__c);
    }

    // ===================================================================
    // TEST: approveRequest — verifies Approved_Date__c is set
    // ===================================================================
    @isTest
    static void testApproveRequest_SetsApprovedDate() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();

        Test.startTest();
        ctrl.approveRequest();
        Test.stopTest();

        Leave_Request__c updated = [
            SELECT Status__c, Approved_Date__c, Approved_By__c
            FROM Leave_Request__c WHERE Id = :lr.Id
        ];
        System.assertEquals('Approved', updated.Status__c,       'Status should be Approved');
        System.assertNotEquals(null,     updated.Approved_Date__c, 'Approved_Date__c should be set');
    }

    // ===================================================================
    // TEST: cancelRequest — verifies Cancelled_Date__c and Cancelled_Reason__c
    // ===================================================================
    @isTest
    static void testCancelRequest_SetsCancelledFields() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Cancellation reason provided.';

        Test.startTest();
        ctrl.cancelRequest();
        Test.stopTest();

        Leave_Request__c updated = [
            SELECT Status__c, Cancelled_Date__c, Cancelled_Reason__c
            FROM Leave_Request__c WHERE Id = :lr.Id
        ];
        System.assertEquals('Cancelled', updated.Status__c,         'Status should be Cancelled');
        System.assertNotEquals(null,      updated.Cancelled_Date__c, 'Cancelled_Date__c should be set');
        System.assertEquals('Cancellation reason provided.', updated.Cancelled_Reason__c);
    }

    // ===================================================================
    // TEST: approveRequest — Approved_By__c is populated with managerId
    // ===================================================================
    @isTest
    static void testApproveRequest_SetsApprovedBy() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Looks good.';

        Test.startTest();
        ctrl.approveRequest();
        Test.stopTest();

        Leave_Request__c updated = [SELECT Approved_By__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals(mgr.Id, updated.Approved_By__c, 'Approved_By__c should be set to managerId');
    }

    // ===================================================================
    // TEST: cancelRequest — Approved_By__c is populated with managerId
    // ===================================================================
    @isTest
    static void testCancelRequest_SetsApprovedBy() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Cancelled.';

        Test.startTest();
        ctrl.cancelRequest();
        Test.stopTest();

        Leave_Request__c updated = [SELECT Approved_By__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals(mgr.Id, updated.Approved_By__c, 'Approved_By__c should be set to managerId on cancel');
    }

    // ===================================================================
    // TEST: rejectRequest — Approved_By__c is populated with managerId
    // ===================================================================
    @isTest
    static void testRejectRequest_SetsApprovedBy() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.rejectionReason = 'Resource needed on-site.';

        Test.startTest();
        ctrl.rejectRequest();
        Test.stopTest();

        Leave_Request__c updated = [SELECT Approved_By__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals(mgr.Id, updated.Approved_By__c, 'Approved_By__c should be set to managerId on reject');
    }

    // ===================================================================
    // TEST: approveRequest — no manager param (managerId is blank)
    // ===================================================================
    @isTest
    static void testApproveRequest_NoManagerParam() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        // Only pass the request id, not the manager param
        PageReference pg = Page.LeaveApprovalPage;
        pg.getParameters().put('id', lr.Id);
        Test.setCurrentPage(pg);

        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'No manager param test.';

        Test.startTest();
        PageReference result = ctrl.approveRequest();
        Test.stopTest();

        // Should still succeed — managerId will be blank/null
        System.assertEquals(true,       ctrl.showSuccess, 'showSuccess should be true even without mgr param');
        System.assertEquals('Approved', ctrl.actionTaken);
    }

    // ===================================================================
    // TEST: cancelRequest — no manager param (managerId is blank)
    // ===================================================================
    @isTest
    static void testCancelRequest_NoManagerParam() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        PageReference pg = Page.LeaveApprovalPage;
        pg.getParameters().put('id', lr.Id);
        Test.setCurrentPage(pg);

        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = 'Cancel without manager param.';

        Test.startTest();
        PageReference result = ctrl.cancelRequest();
        Test.stopTest();

        System.assertEquals(true,        ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Cancelled', ctrl.actionTaken);
    }

    // ===================================================================
    // TEST: rejectRequest — no manager param (managerId is blank)
    // ===================================================================
    @isTest
    static void testRejectRequest_NoManagerParam() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        PageReference pg = Page.LeaveApprovalPage;
        pg.getParameters().put('id', lr.Id);
        Test.setCurrentPage(pg);

        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.rejectionReason = 'Reject without manager param.';

        Test.startTest();
        PageReference result = ctrl.rejectRequest();
        Test.stopTest();

        System.assertEquals(true,       ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Rejected', ctrl.actionTaken);
    }

    // ===================================================================
    // TEST: All public getter properties are accessible after load
    // ===================================================================
    @isTest
    static void testAllPublicProperties_Accessible() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));

        Test.startTest();
        LeaveApprovalController ctrl = new LeaveApprovalController();
        Test.stopTest();

        // Verify all public properties are populated and accessible
        System.assertNotEquals(null, ctrl.leaveRequest,   'leaveRequest should not be null');
        System.assertNotEquals(null, ctrl.employeeName,   'employeeName should not be null');
        System.assertNotEquals(null, ctrl.employeeEmail,  'employeeEmail should not be null');
        System.assertNotEquals(null, ctrl.leaveTypeName,  'leaveTypeName should not be null');
        System.assertNotEquals(null, ctrl.startDate,      'startDate should not be null');
        System.assertNotEquals(null, ctrl.endDate,        'endDate should not be null');
        System.assertNotEquals(null, ctrl.totalDays,      'totalDays should not be null');
        System.assertNotEquals(null, ctrl.reason,         'reason should not be null');
        System.assertEquals(false,   ctrl.showSuccess,    'showSuccess defaults to false');
        System.assertEquals(false,   ctrl.showError,      'showError defaults to false');
        System.assertEquals(false,   ctrl.showInfo,       'showInfo defaults to false');
    }

    // ===================================================================
    // TEST: managerComments and rejectionReason setters work correctly
    // ===================================================================
    @isTest
    static void testSetterProperties() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();

        ctrl.managerComments  = 'Test manager comment';
        ctrl.rejectionReason  = 'Test rejection reason';

        System.assertEquals('Test manager comment',  ctrl.managerComments,  'managerComments setter/getter should work');
        System.assertEquals('Test rejection reason', ctrl.rejectionReason,  'rejectionReason setter/getter should work');
    }

    // ===================================================================
    // TEST: approveRequest — empty string managerComments (edge case)
    // ===================================================================
    @isTest
    static void testApproveRequest_EmptyStringComments() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = ''; // empty string

        Test.startTest();
        PageReference result = ctrl.approveRequest();
        Test.stopTest();

        System.assertEquals(true,       ctrl.showSuccess, 'showSuccess should be true with empty comments');
        System.assertEquals('Approved', ctrl.actionTaken, 'actionTaken should be Approved');
    }

    // ===================================================================
    // TEST: cancelRequest — empty string managerComments (edge case)
    // ===================================================================
    @isTest
    static void testCancelRequest_EmptyStringComments() {
        User mgr = createManager();
        User emp = createEmployee(mgr.Id);
        Leave_Type__c lt = createLeaveType();
        Leave_Request__c lr = createLeaveRequest(emp.Id, mgr.Id, lt.Id, 'Pending');

        Test.setCurrentPage(buildPage(lr.Id, mgr.Id));
        LeaveApprovalController ctrl = new LeaveApprovalController();
        ctrl.managerComments = ''; // empty string — Salesforce stores as null in DB

        Test.startTest();
        PageReference result = ctrl.cancelRequest();
        Test.stopTest();

        System.assertEquals(true,        ctrl.showSuccess, 'showSuccess should be true');
        System.assertEquals('Cancelled', ctrl.actionTaken);

        Leave_Request__c updated = [SELECT Status__c, Cancelled_Reason__c FROM Leave_Request__c WHERE Id = :lr.Id];
        System.assertEquals('Cancelled', updated.Status__c);
        // Salesforce normalises empty string to null on DML — assert null or blank
        System.assert(String.isBlank(updated.Cancelled_Reason__c), 'Cancelled_Reason__c should be blank/null for empty input');
    }
}