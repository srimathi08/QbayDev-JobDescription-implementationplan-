public without sharing class TimesheetApprovalController {
    
    public String token { get; set; }
    public String action { get; set; }
    public String comments { get; set; }
    
    public Boolean showForm { get; set; }
    public Boolean showMessage { get; set; }
    public Boolean isSuccess { get; set; }
    public Boolean isLoading { get; set; }
    public String message { get; set; }
    
	public static final String STATUS_SUBMITTED = 'Submitted';
	public static final String STATUS_APPROVED  = 'Approved';
	public static final String STATUS_REJECTED  = 'Rejected';
    
    public static final String WH_STATUS_REQUESTED = 'WH Entry - Requested';
    public static final String WH_STATUS_APPROVED  = 'WH Entry - Approved';
    public static final String WH_STATUS_REJECTED  = 'WH Entry - Rejected';

    public Boolean isWHEntry { get; set; }
    // Timesheet details
    public String employeeName { get; set; }
    public Integer weekNumber { get; set; }
    public Integer weekYear { get; set; }
    public Decimal totalHours { get; set; }
    public Decimal billableHours { get; set; }
    public Decimal nonBillableHours { get; set; }
    public Decimal shadowHours { get; set; }
    public DateTime submittedDate { get; set; }
    public List<EntryWrapper> wrapperEntries { get; set; }
    public List<EntryWrapper> paginatedEntries { get; set; }
    public Boolean allSelected { get; set; }
    
    // Pagination variables
    public Integer pageSize { get; set; }
    public Integer pageNumber { get; set; }
    
    // Internal lists for display/logic
    private List<TimesheetEntry__c> entries;
    
    private Timesheet__c timesheet;
    private Id whTimesheetId;
    public TimesheetApprovalController() {
       // Prevent client-side / proxy caching
    ApexPages.currentPage().getHeaders().put('Pragma', 'no-cache');
    ApexPages.currentPage().getHeaders().put('Cache-Control', 'no-cache, no-store, must-revalidate'); 
		// Get parameters from URL
        token = ApexPages.currentPage().getParameters().get('token');
        action = ApexPages.currentPage().getParameters().get('action');
        
        showForm = false;
        showMessage = false;
        isLoading = false;
        isSuccess = false;
        comments = '';
        
        if (String.isBlank(token)) {
            showMessage = true;
            isSuccess = false;
            message = 'Invalid approval link. Token is missing.';
            return;
        }
        
        // Load timesheet data (NO DML here)
        loadTimesheetData();
        
        // ⭐ FIX: Don't auto-process in constructor - wait for button click
        // Remove auto-processing logic from constructor
    }
    
    private void loadTimesheetData() {
        try {

 System.debug('USER TYPE: ' + UserInfo.getUserType());
        System.debug('USER ID: ' + UserInfo.getUserId());
        System.debug('TOKEN: ' + token);

        // Add this test query to confirm Guest can read TimesheetEntry__c
        Integer teCount = [SELECT COUNT() FROM TimesheetEntry__c 
                           WHERE Approval_Token_WH__c = :token];
        System.debug('WH ENTRY COUNT FOR TOKEN: ' + teCount);

            // Query timesheet with token (READ ONLY - no DML)
            List<Timesheet__c> sheets = [
                SELECT Id, Employee__c, Manager__c, Week_Number__c, Week_Year__c,
                       Approval_Status__c, Submitted_Date__c, Token_Expiry__c,
                       Employee__r.Name, Manager__r.Name
                FROM Timesheet__c
                WHERE Approval_Token__c = :token
                LIMIT 1
            ];
            
            if (sheets.isEmpty()) {
                // Try looking for Entry level token
                List<TimesheetEntry__c> whEntries = [
                    SELECT Id, Date__c, Project__r.Name, Tasks__c, Billing_Status__c,
                           Approval_Status__c, Approver_Comments__c, Total_Hours__c,
                           Approval_Token_WH__c, Token_Expiry_WH__c,
                           Timesheet__r.Employee__r.Name, Timesheet__r.Manager__c,
                           Timesheet__r.Week_Number__c, Timesheet__r.Week_Year__c,
                           Timesheet__r.Submitted_Date__c
                    FROM TimesheetEntry__c
                    WHERE Approval_Token_WH__c = :token
                ];

                if (!whEntries.isEmpty()) {
                    isWHEntry = true;
                    TimesheetEntry__c sample = whEntries[0];
                    
                    if (sample.Token_Expiry_WH__c < DateTime.now()) {
                        showMessage = true; isSuccess = false; message = 'Approval link expired.'; return;
                    }

                    employeeName = sample.Timesheet__r.Employee__r.Name;
                    weekNumber = Integer.valueOf(sample.Timesheet__r.Week_Number__c);
                    weekYear = Integer.valueOf(sample.Timesheet__r.Week_Year__c);
                    submittedDate = sample.Timesheet__r.Submitted_Date__c;
					whTimesheetId = sample.Timesheet__c;
                    
                    wrapperEntries = new List<EntryWrapper>();
                    totalHours = 0;
                    billableHours = 0;
                    nonBillableHours = 0;
                    shadowHours = 0;

                    for (TimesheetEntry__c e : whEntries) {
                        if (e.Approval_Status__c == WH_STATUS_REQUESTED) {
                            wrapperEntries.add(new EntryWrapper(e, true));
                        }
                        
                        Decimal hrs = (e.Total_Hours__c != null ? e.Total_Hours__c : 0);
                        totalHours += hrs;

                        if (e.Billing_Status__c == 'Billable') billableHours += hrs;
                        else if (e.Billing_Status__c == 'Non-Billable') nonBillableHours += hrs;
                        else if (e.Billing_Status__c == 'Shadow') shadowHours += hrs;
                    }
                    
                    if (wrapperEntries.isEmpty()) {
                        showMessage = true; isSuccess = true; message = 'All entries in this batch have already been processed.'; return;
                    }

                    // Pagination & Hours init
                    pageSize   = 5;
                    pageNumber = 1;
                    allSelected = true;

                    showForm = true;
                    refreshPaginatedEntries();
                    return;
                }
                
                showMessage = true;
                isSuccess = false;
                message = 'Invalid or expired approval link.';
                return;
            }
            
            timesheet = sheets[0];
            
            // Check if token is expired
            if (timesheet.Token_Expiry__c < DateTime.now()) {
                showMessage = true;
                isSuccess = false;
                message = 'This approval link has expired. Please contact the employee for a new link.';
                return;
            }
            
            // Check if already processed
            if (timesheet.Approval_Status__c != STATUS_SUBMITTED) {
                showMessage = true;
                isSuccess = true;
                message = 'This timesheet has already been ' + timesheet.Approval_Status__c.toLowerCase() + '.';
                return;
            }
            
            // Verify current user is the manager (if logged in)
            if (UserInfo.getUserType() != 'Guest' && UserInfo.getUserId() != timesheet.Manager__c) {
                showMessage = true;
                isSuccess = false;
                message = 'You are not authorized to approve this timesheet.';
                return;
            }
            
            // Load ALL entries for hours summary
            entries = [
                SELECT Id, Date__c, Project__r.Name, Tasks__c, Billing_Status__c,
                       Approval_Status__c, Approver_Comments__c,
                       Total_Hours__c, Regular_Hours__c, Overtime_Hours__c
                FROM TimesheetEntry__c
                WHERE Timesheet__c = :timesheet.Id
                ORDER BY Date__c
            ];
            
            // ⭐ FIX: Only show SUBMITTED entries to manager — already-Approved ones are skipped
            wrapperEntries = new List<EntryWrapper>();
            for (TimesheetEntry__c entry : entries) {
                if (entry.Approval_Status__c == STATUS_SUBMITTED) {
                    wrapperEntries.add(new EntryWrapper(entry, true)); // Default to selected
                }
            }
            allSelected = true;
            
            if (wrapperEntries.isEmpty()) {
                showMessage = true;
                isSuccess = true;
                message = 'All entries for this timesheet have already been processed.';
                return;
            }
            
            // Pagination init
            pageSize = 5;
            pageNumber = 1;
            refreshPaginatedEntries();
            
            // Calculate hour breakdowns
            totalHours = 0;
            billableHours = 0;
            nonBillableHours = 0;
            shadowHours = 0;
            
            for (TimesheetEntry__c entry : entries) {
                Decimal hrs = (entry.Total_Hours__c != null ? entry.Total_Hours__c : 0);
                totalHours += hrs;
                
                String billing = (entry.Billing_Status__c != null ? entry.Billing_Status__c : '').toLowerCase().trim();
                if (billing == 'billable') {
                    billableHours += hrs;
                } else if (billing.contains('non') || billing == 'non-billable') {
                    nonBillableHours += hrs;
                } else if (billing == 'shadow') {
                    shadowHours += hrs;
                } else {
                    // Default to billable if not specified
                    billableHours += hrs;
                }
            }
            
            // Populate display fields
            employeeName = timesheet.Employee__r.Name;
            weekNumber = Integer.valueOf(timesheet.Week_Number__c);
            weekYear = Integer.valueOf(timesheet.Week_Year__c);
            submittedDate = timesheet.Submitted_Date__c;
            
            // Show the approval form
            showForm = true;
            
        } catch (Exception e) {
            showMessage = true;
            isSuccess = false;
            message = 'Error loading timesheet: ' + e.getMessage();
            System.debug('Error in loadTimesheetData: ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
    }
    
    // ⭐ FIX: These methods now use reRender properly
    public PageReference approveTimesheet() {
        processApproval('approve');
        return null; // Stay on same page
    }
    
    public PageReference rejectTimesheet() {
        processApproval('reject');
        return null; // Stay on same page
    }


    
    public PageReference partialApprove() {
        processPartialApproval('approve');
        return null;
    }

    public PageReference partialReject() {
        processPartialApproval('reject');
        return null;
    }
    
    private void processPartialApproval(String partialAction) {
        // This will be called when user wants to handle specific rows
        // If all selected, we can call bulk, but let's make it generic
        processApproval(partialAction);
    }
    
    public void toggleSelectAll() {
        if (wrapperEntries != null) {
            for (EntryWrapper w : wrapperEntries) {
                w.selected = allSelected;
            }
        }
        refreshPaginatedEntries();
    }
    
    public void syncAllSelected() {
        if (wrapperEntries != null) {
            Boolean all = true;
            for (EntryWrapper w : wrapperEntries) {
                if (!w.selected) {
                    all = false;
                    break;
                }
            }
            allSelected = all;
        }
        refreshPaginatedEntries();
    }
    
    public void refreshPaginatedEntries() {
        paginatedEntries = new List<EntryWrapper>();
        if (wrapperEntries == null || wrapperEntries.isEmpty()) return;
        
        Integer startIdx = (pageNumber - 1) * pageSize;
        Integer endIdx = Math.min(startIdx + pageSize, wrapperEntries.size());
        
        for (Integer i = startIdx; i < endIdx; i++) {
            paginatedEntries.add(wrapperEntries[i]);
        }
    }
    
    // Pagination Methods
    public void nextPage() {
        if (getHasNext()) {
            pageNumber++;
            refreshPaginatedEntries();
        }
    }
    
    public void previousPage() {
        if (getHasPrevious()) {
            pageNumber--;
            refreshPaginatedEntries();
        }
    }
    
    public Boolean getHasNext() {
        return (pageNumber * pageSize) < wrapperEntries.size();
    }
    
    public Boolean getHasPrevious() {
        return pageNumber > 1;
    }
    
    public Integer getTotalPages() {
        if (wrapperEntries == null || wrapperEntries.isEmpty()) return 0;
        return (Integer) Math.ceil((Decimal) wrapperEntries.size() / pageSize);
    }
    
    public Integer getStartRecord() {
        return (pageNumber - 1) * pageSize + 1;
    }
    
    public Integer getEndRecord() {
        return Math.min(pageNumber * pageSize, wrapperEntries.size());
    }
    
    private void processApproval(String approvalAction) {
    try {
        System.debug('=== APPROVAL PROCESS START ===');
        System.debug('Action: ' + approvalAction);
        System.debug('Comments: ' + comments);
        
        isLoading = true;

        // ✅ STEP 1: Handle WH entries FIRST — before any timesheet null check
        if (isWHEntry == true) {
            List<TimesheetEntry__c> whUpdates = new List<TimesheetEntry__c>();
            for (EntryWrapper w : wrapperEntries) {
                if (approvalAction == 'approve') {
                    w.entry.Approval_Status__c = w.selected ? WH_STATUS_APPROVED : WH_STATUS_REJECTED;
                } else {
                    w.entry.Approval_Status__c = w.selected ? WH_STATUS_REJECTED : WH_STATUS_APPROVED;
                }
                if (String.isNotBlank(w.rejectionComment)) {
                    w.entry.Approver_Comments__c = w.rejectionComment;
                }
                w.entry.Approval_Token_WH__c = null; // Invalidate token
                whUpdates.add(w.entry);
            }
            update whUpdates;

            // Clear token from all sibling entries sharing the same token (prevent reuse)
            if (whTimesheetId != null && String.isNotBlank(token)) {
                List<TimesheetEntry__c> siblings = [
                    SELECT Id, Approval_Token_WH__c
                    FROM TimesheetEntry__c
                    WHERE Timesheet__c = :whTimesheetId
                      AND Approval_Token_WH__c = :token
                ];
                for (TimesheetEntry__c s : siblings) {
                    s.Approval_Token_WH__c = null;
                }
                if (!siblings.isEmpty()) update siblings;
            }

            isLoading   = false;
            showForm    = false;
            showMessage = true;
            isSuccess   = true;
            message     = 'Weekend/Holiday entries have been '
                        + (approvalAction == 'approve' ? 'approved' : 'rejected')
                        + ' successfully.';

            System.debug('=== WH APPROVAL PROCESS COMPLETE ===');
            return; // Exit early — no timesheet processing needed
        }

        // ✅ STEP 2: Regular timesheet null check — only reached for weekly entries
        if (timesheet == null) {
            throw new CustomException('Timesheet data not loaded.');
        }

        // Re-query to ensure we have latest data (avoid stale data issues)
        timesheet = [
            SELECT Id, Employee__c, Manager__c, Week_Number__c, Week_Year__c,
                   Approval_Status__c, Submitted_Date__c, Token_Expiry__c,
                   Approval_Token__c, Employee__r.Name, Employee__r.Email
            FROM Timesheet__c
            WHERE Id = :timesheet.Id
            LIMIT 1
        ];

        // Validate timesheet is still in submitted state
        if (timesheet.Approval_Status__c != 'Submitted') {
            throw new CustomException('This timesheet has already been processed.');
        }

        // Validate token hasn't been used
        if (String.isBlank(timesheet.Approval_Token__c)) {
            throw new CustomException('This approval link has already been used.');
        }

        // Set approval timestamps and user (if not guest)
        if (approvalAction == 'approve') {
            timesheet.Approval_Status__c = 'Approved';
            timesheet.Approved_Date__c   = DateTime.now();
            if (UserInfo.getUserType() != 'Guest') {
                timesheet.Approved_By__c = UserInfo.getUserId();
            }
        } else {
            timesheet.Approval_Status__c = 'Rejected';
            timesheet.Rejected_Date__c   = DateTime.now();
            if (UserInfo.getUserType() != 'Guest') {
                timesheet.Rejected_By__c = UserInfo.getUserId();
            }
        }

        // ✅ STEP 3: Process individual entry statuses based on selection
        // Approve button: Checked = Approved,  Unchecked = Rejected
        // Reject  button: Checked = Rejected,  Unchecked = Approved
        List<TimesheetEntry__c> entriesToUpdate = new List<TimesheetEntry__c>();
        Integer approvedCount = 0;
        Integer rejectedCount = 0;

        for (EntryWrapper w : wrapperEntries) {
            if (approvalAction == 'approve') {
                w.entry.Approval_Status__c = w.selected ? STATUS_APPROVED : STATUS_REJECTED;
                if (!w.selected && String.isBlank(w.rejectionComment)) {
                    w.rejectionComment = 'Rejected by manager during bulk approval';
                }
            } else {
                w.entry.Approval_Status__c = w.selected ? STATUS_REJECTED : STATUS_APPROVED;
                if (w.selected && String.isBlank(w.rejectionComment)) {
                    w.rejectionComment = 'Rejected by manager';
                }
            }

            if (w.entry.Approval_Status__c == STATUS_REJECTED && String.isNotBlank(w.rejectionComment)) {
                w.entry.Approver_Comments__c = w.rejectionComment;
            }

            entriesToUpdate.add(w.entry);
            if (w.entry.Approval_Status__c == STATUS_APPROVED) approvedCount++;
            else rejectedCount++;
        }

        if (entriesToUpdate.isEmpty()) {
            throw new CustomException('No entries found to process.');
        }

        // Update entries first
        update entriesToUpdate;
        System.debug('Entries updated — Approved: ' + approvedCount + ', Rejected: ' + rejectedCount);

        // ✅ STEP 4: Recompute parent Timesheet status from ALL entries
        // (including already-Approved WH entries — don't overwrite them)
        List<TimesheetEntry__c> allCurrentEntries = [
            SELECT Approval_Status__c
            FROM TimesheetEntry__c
            WHERE Timesheet__c = :timesheet.Id
        ];

        Boolean allApproved = true;
        Boolean anyRejected = false;

        for (TimesheetEntry__c e : allCurrentEntries) {
            if (e.Approval_Status__c != STATUS_APPROVED && e.Approval_Status__c != WH_STATUS_APPROVED) allApproved = false;
            if (e.Approval_Status__c == STATUS_REJECTED  || e.Approval_Status__c == WH_STATUS_REJECTED)  anyRejected = true;
        }

        timesheet.Approval_Comments__c = comments;
        timesheet.Approval_Token__c    = null; // Invalidate token

        if (allApproved) {
            timesheet.Approval_Status__c = STATUS_APPROVED;
            timesheet.Approved_Date__c   = DateTime.now();
        } else if (anyRejected) {
            timesheet.Approval_Status__c = STATUS_REJECTED;
            timesheet.Rejected_Date__c   = DateTime.now();
        } else {
            timesheet.Approval_Status__c = STATUS_SUBMITTED; // Still has pending entries
        }

        System.debug('Final Timesheet status: ' + timesheet.Approval_Status__c);
        update timesheet;

        // ✅ STEP 5: Send notification email to employee
        sendEmployeeNotification(approvalAction);

        // Show success message
        isLoading   = false;
        showForm    = false;
        showMessage = true;
        isSuccess   = true;

        String actionText = (approvalAction == 'approve') ? 'approved' : 'rejected';
        message = 'Timesheet has been ' + actionText + ' successfully. The employee has been notified.';

        System.debug('=== APPROVAL PROCESS COMPLETE ===');

    } catch (Exception e) {
        isLoading   = false;
        showForm    = false;
        showMessage = true;
        isSuccess   = false;
        message     = 'Error processing approval: ' + e.getMessage();
        System.debug('Error in processApproval: ' + e.getMessage() + ' | ' + e.getStackTraceString());
    }
}
    
    private void sendEmployeeNotification(String approvalAction) {
        try {
            String status = (approvalAction == 'approve') ? 'Approved' : 'Rejected';
            String color = (approvalAction == 'approve') ? '#4CAF50' : '#f44336';
            
            String html = '<html><body style="font-family: Arial, sans-serif;">';
            html += '<div style="max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #ddd;">';
            html += '<h2 style="color: ' + color + ';">Timesheet ' + status + '</h2>';
            html += '<p>Hello ' + employeeName + ',</p>';
            html += '<p>Your timesheet for Week ' + weekNumber + ', ' + weekYear + ' has been <strong>' + status.toLowerCase() + '</strong>.</p>';
            
            if (String.isNotBlank(comments)) {
                html += '<div style="background-color: #f5f5f5; padding: 15px; margin: 20px 0; border-radius: 5px;">';
                html += '<h3 style="margin-top: 0;">Manager Comments:</h3>';
                html += '<p>' + comments.escapeHtml4() + '</p>';
                html += '</div>';
            }
            
            if (approvalAction == 'reject') {
                html += '<p>Please review the comments below, make necessary corrections, and resubmit your timesheet.</p>';
            } else {
                html += '<p>Please see the status of your individual entries below.</p>';
            }
            
            // Add entry status table
            html += '<h3 style="margin-top: 20px;">Entry Details:</h3>';
            html += '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px; font-size: 13px;">';
            html += '<thead><tr style="background-color: #f2f2f2;">';
            html += '<th style="padding: 8px; border: 1px solid #ddd; text-align: left;">Date</th>';
            html += '<th style="padding: 8px; border: 1px solid #ddd; text-align: left;">Project</th>';
            html += '<th style="padding: 8px; border: 1px solid #ddd; text-align: left;">Status</th>';
            html += '<th style="padding: 8px; border: 1px solid #ddd; text-align: left;">Comments</th>';
            html += '</tr></thead><tbody>';

            for (EntryWrapper w : wrapperEntries) {
                String rowColor = (w.entry.Approval_Status__c == STATUS_APPROVED) ? '#d4edda' : (w.entry.Approval_Status__c == STATUS_REJECTED ? '#f8d7da' : '#ffffff');
                html += '<tr style="background-color: ' + rowColor + ';">';
                html += '<td style="padding: 6px; border: 1px solid #ddd;">' + w.entry.Date__c.format() + '</td>';
                html += '<td style="padding: 6px; border: 1px solid #ddd;">' + (w.entry.Project__r.Name != null ? w.entry.Project__r.Name : '-') + '</td>';
                html += '<td style="padding: 6px; border: 1px solid #ddd;"><strong>' + w.entry.Approval_Status__c + '</strong></td>';
                html += '<td style="padding: 6px; border: 1px solid #ddd;">' + (String.isNotBlank(w.rejectionComment) ? w.rejectionComment.escapeHtml4() : '-') + '</td>';
                html += '</tr>';
            }
            html += '</tbody></table>';
            
            html += '<div style="margin-top: 20px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 12px;">';
            html += '<p>Total Hours: ' + totalHours + '</p>';
            html += '<p>Processed on: ' + DateTime.now().format('MMM dd, yyyy \'at\' hh:mm a') + '</p>';
            html += '</div>';
            
            html += '</div></body></html>';
            
            // Get employee email
            User employee = [SELECT Email FROM User WHERE Id = :timesheet.Employee__c LIMIT 1];
            
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new String[] { employee.Email });
            mail.setSubject('Timesheet ' + status + ': Week ' + weekNumber + ', ' + weekYear);
            mail.setHtmlBody(html);
            mail.setSaveAsActivity(false);
            // ✅ SAFE ORG-WIDE EMAIL RESOLUTION
		List<OrgWideEmailAddress> oweaList = [
    SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1
];

if (!oweaList.isEmpty()) {
    mail.setOrgWideEmailAddressId(oweaList[0].Id);
}
      
    Messaging.SendEmailResult[] res =
    Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });

if (!res[0].isSuccess()) {
    for (Messaging.SendEmailError err : res[0].getErrors()) {
        System.debug('### EMPLOYEE EMAIL FAILED: ' + err.getMessage());
    }
} else {
    System.debug('### EMPLOYEE EMAIL SENT to ' + employee.Email);
}
            
        } catch (Exception e) {
            System.debug('Error sending employee notification: ' + e.getMessage());
            // Don't throw exception - approval already processed
        }
    }
    
    public class EntryWrapper {
        public TimesheetEntry__c entry { get; set; }
        public Boolean selected { get; set; }
        public String rejectionComment { get; set; }
        
        public EntryWrapper(TimesheetEntry__c e, Boolean sel) {
            this.entry = e;
            this.selected = sel;
            this.rejectionComment = '';
        }
    }

    public class CustomException extends Exception {}
}