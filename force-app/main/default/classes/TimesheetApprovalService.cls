public without sharing class TimesheetApprovalService {
    
    /* =====================================================================================
       1. SEND APPROVAL REQUEST EMAIL TO MANAGER
    ===================================================================================== */
    @AuraEnabled
    public static Map<String, Object> sendApprovalRequestToManager(Integer weekNumber, Integer year) {
        try {
            Id userId = UserInfo.getUserId();
            
            System.debug('=== APPROVAL REQUEST START ===');
            System.debug('User ID: ' + userId);
            System.debug('User Type: ' + UserInfo.getUserType());
            System.debug('Week: ' + weekNumber + ', Year: ' + year);
            
            // Get the timesheet record
            Timesheet__c sheet = [
                SELECT Id, Employee__c, Manager__c, Week_Number__c, Week_Year__c, 
                       Approval_Status__c, Employee__r.Name, Employee__r.Email,
                       Manager__r.Name, Manager__r.Email
                FROM Timesheet__c
                WHERE Employee__c = :userId
                  AND Week_Number__c = :weekNumber
                  AND Week_Year__c = :year
                LIMIT 1
            ];
            
            System.debug('Timesheet found: ' + sheet.Id);
            System.debug('Manager ID: ' + sheet.Manager__c);
            System.debug('Manager Name: ' + sheet.Manager__r.Name);
            System.debug('Manager Email: ' + sheet.Manager__r.Email);
            
            if (sheet.Manager__c == null) {
                throw new AuraHandledException('No manager assigned for this timesheet.');
            }
            
            // Get ALL entries for this week
            List<TimesheetEntry__c> allEntries = [
                SELECT Id, Date__c, Project__r.Name, Tasks__c, 
                       Total_Hours__c, Regular_Hours__c, Overtime_Hours__c,
                       Approval_Status__c
                FROM TimesheetEntry__c
                WHERE Timesheet__c = :sheet.Id
                ORDER BY Date__c
            ];
            
            System.debug('Total entries found: ' + allEntries.size());
            
            if (allEntries.isEmpty()) {
                throw new AuraHandledException('No timesheet entries found for this week.');
            }
            
            // ⭐ SMART FILTER: separate pending entries from already-Approved ones
            List<TimesheetEntry__c> pendingEntries = new List<TimesheetEntry__c>();
            Integer alreadyApprovedCount = 0;
            for (TimesheetEntry__c entry : allEntries) {
                if (entry.Approval_Status__c == 'Approved' || entry.Approval_Status__c == 'WH Entry - Approved') {
                    alreadyApprovedCount++;
                } else if (entry.Approval_Status__c == 'WH Entry - Requested') {
                     throw new AuraHandledException('Please wait for Manager Approval for Weekend/Holiday entries before submitting the weekly record.');
                } else {
                    pendingEntries.add(entry);
                }
            }
            
            System.debug('Already approved: ' + alreadyApprovedCount + ', Pending: ' + pendingEntries.size());
            
            if (pendingEntries.isEmpty()) {
                throw new AuraHandledException('All entries for this week are already approved. Nothing to submit.');
            }
            
            // Update timesheet status BEFORE sending email
            sheet.Approval_Status__c = 'Submitted';
            sheet.Submitted_Date__c = DateTime.now();
            update sheet;
            
            System.debug('Timesheet status updated to Submitted');
            
            // Update ONLY Draft/Rejected/null entries → Submitted (never touch Approved)
            List<TimesheetEntry__c> entriesToUpdate = new List<TimesheetEntry__c>();
            for (TimesheetEntry__c entry : pendingEntries) {
                if (entry.Approval_Status__c == 'Draft' || entry.Approval_Status__c == 'Rejected' || entry.Approval_Status__c == null) {
                    entry.Approval_Status__c = 'Submitted';
                    entry.Submitted_Date__c = DateTime.now();
                    entriesToUpdate.add(entry);
                }
            }
            if (!entriesToUpdate.isEmpty()) {
                update entriesToUpdate;
            }
            
            System.debug('Entry statuses updated to Submitted: ' + entriesToUpdate.size());
            
            // ⭐ FIX: Use @future method to send email from community users
            // Email will ONLY contain pendingEntries — manager is not shown already-Approved rows
            if (UserInfo.getUserType() == 'CspLitePortal' || 
                UserInfo.getUserType() == 'PowerCustomerSuccess' ||
                UserInfo.getUserType() == 'CustomerSuccess') {
                // Community user - send email asynchronously (async path also filters internally)
                System.debug('Community user detected - sending email via @future');
                sendEmailAsync(sheet.Id);
            } else {
                // Internal user - send email directly with only pending entries
                System.debug('Internal user - sending email directly');
                sendManagerApprovalEmail(sheet, pendingEntries);
            }
            
            Map<String, Object> response = new Map<String, Object>();
            response.put('success', true);
            response.put('message', 'Approval request sent to ' + sheet.Manager__r.Name);
            response.put('managerEmail', sheet.Manager__r.Email);
            response.put('managerName', sheet.Manager__r.Name);
            response.put('entriesSubmitted', pendingEntries.size());
            response.put('pendingCount', pendingEntries.size());
            response.put('alreadyApprovedCount', alreadyApprovedCount);
            
            System.debug('=== APPROVAL REQUEST COMPLETE ===');
            System.debug('Response: ' + JSON.serialize(response));
            
            return response;
            
        } catch (AuraHandledException e) {
            throw e; // Re-throw already handled exceptions
        } catch (Exception e) {
            String errorMsg = e.getMessage() + ' (Line: ' + e.getLineNumber() + ')';
            System.debug('ERROR in sendApprovalRequestToManager: ' + errorMsg);
            System.debug('Stack trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error sending approval request: ' + errorMsg);
        }
    }
    
    /* =====================================================================================
       1A. ASYNC EMAIL SENDER FOR COMMUNITY USERS
    ===================================================================================== */
    @future
    public static void sendEmailAsync(Id timesheetId) {
        try {
            System.debug('=== ASYNC EMAIL START ===');
            System.debug('Timesheet ID: ' + timesheetId);
            
            // Re-query timesheet with all details
            Timesheet__c sheet = [
                SELECT Id, Employee__c, Manager__c, Week_Number__c, Week_Year__c, 
                       Approval_Status__c, Employee__r.Name, Employee__r.Email,
                       Manager__r.Name, Manager__r.Email
                FROM Timesheet__c
                WHERE Id = :timesheetId
                LIMIT 1
            ];
            
            // Get only pending (non-Approved) entries for the email body
            List<TimesheetEntry__c> entries = [
                SELECT Id, Date__c, Project__r.Name, Tasks__c, 
                       Total_Hours__c, Regular_Hours__c, Overtime_Hours__c,
                       Approval_Status__c
                FROM TimesheetEntry__c
                WHERE Timesheet__c = :timesheetId
                  AND Approval_Status__c != 'Approved'
                  AND Approval_Status__c != 'WH Entry - Approved'
                ORDER BY Date__c
            ];
            
            System.debug('Sending email for ' + entries.size() + ' entries');
            
            // Send the email
            sendManagerApprovalEmail(sheet, entries);
            
            System.debug('=== ASYNC EMAIL COMPLETE ===');
            
        } catch (Exception e) {
            System.debug('ERROR in sendEmailAsync: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
        }
    }
    
    /* =====================================================================================
       2. SEND EMAIL TO MANAGER
    ===================================================================================== */
    private static void sendManagerApprovalEmail(Timesheet__c sheet, List<TimesheetEntry__c> entries) {
        
        // Generate unique approval token
        String approvalToken = generateApprovalToken(sheet.Id);
        
        // Store token in a custom object or field for validation
        sheet.Approval_Token__c = approvalToken;
        sheet.Token_Expiry__c = DateTime.now().addDays(100); // Token valid for 100 days
        update sheet;
        
        // Build email body
        String emailBody = buildApprovalEmailBody(sheet, entries, approvalToken);
        
        // DEBUGGING: Log email details
        System.debug('=== EMAIL DEBUG ===');
        System.debug('Manager Email: ' + sheet.Manager__r.Email);
        System.debug('Manager Name: ' + sheet.Manager__r.Name);
        System.debug('Approval Token: ' + approvalToken);
        System.debug('Email Subject: Timesheet Approval Required: ' + sheet.Employee__r.Name);
        
        // Check if manager has email
        if (String.isBlank(sheet.Manager__r.Email)) {
            throw new AuraHandledException('Manager does not have an email address configured.');
        }
        
        try {
            // Send email
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new String[] { sheet.Manager__r.Email });
            mail.setSubject('Timesheet Approval Required: ' + sheet.Employee__r.Name + ' - Week ' + sheet.Week_Number__c + ', ' + sheet.Week_Year__c);
            mail.setHtmlBody(emailBody);
            mail.setSaveAsActivity(false);
            //  GENERIC ORG-WIDE EMAIL 
if (!Test.isRunningTest()) {
    OrgWideEmailAddress owea = [
        SELECT Id
        FROM OrgWideEmailAddress
        WHERE IsAllowAllProfiles = true
        LIMIT 1
    ];
    mail.setOrgWideEmailAddressId(owea.Id);
}
            Messaging.SendEmailResult[] results = Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
            
            // Check if email was sent successfully
            if (results[0].isSuccess()) {
                System.debug('Email sent successfully to: ' + sheet.Manager__r.Email);
            } else {
                System.debug('Email send failed. Errors:');
                for (Messaging.SendEmailError error : results[0].getErrors()) {
                    System.debug('Error: ' + error.getMessage());
                }
                throw new AuraHandledException('Failed to send email: ' + results[0].getErrors()[0].getMessage());
            }
        } catch (Exception e) {
            System.debug('Exception sending email: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error sending approval email: ' + e.getMessage());
        }
    }
    
    /* =====================================================================================
       3. BUILD EMAIL BODY WITH APPROVAL LINKS
    ===================================================================================== */
    private static String buildApprovalEmailBody(Timesheet__c sheet, List<TimesheetEntry__c> entries, String token) {
        // ⭐ FIX: Use the correct public Experience Site URL
        // Production vs UAT Sandbox environment detection
        String currentHost = URL.getOrgDomainUrl().getHost();
        String siteBaseUrl = 'https://innovation-dream-9744.my.site.com/TSApprovalSite';
        
        if (currentHost.contains('--uatsandbox')) {
            siteBaseUrl = 'https://innovation-dream-9744--uatsandbox.sandbox.my.site.com/tsApproval';
        }
        
        // Build approval/rejection links pointing to the VF page on the Experience Site
        String approveUrl = siteBaseUrl + '/apex/TimesheetApprovalPage?action=approve&token=' + token;
        String rejectUrl  = siteBaseUrl + '/apex/TimesheetApprovalPage?action=reject&token='  + token;
        
        // Calculate totals
        Decimal totalHours = 0;
        Decimal regularHours = 0;
        Decimal overtimeHours = 0;
        
        for (TimesheetEntry__c entry : entries) {
            totalHours += (entry.Total_Hours__c != null ? entry.Total_Hours__c : 0);
            regularHours += (entry.Regular_Hours__c != null ? entry.Regular_Hours__c : 0);
            overtimeHours += (entry.Overtime_Hours__c != null ? entry.Overtime_Hours__c : 0);
        }
        
        // Build HTML email
        String html = '<html><body style="font-family: Arial, sans-serif;">';
        html += '<div style="max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #ddd;">';
        html += '<h2 style="color: #333;">Timesheet Approval Request</h2>';
        html += '<p>Hello ' + sheet.Manager__r.Name + ',</p>';
        html += '<p><strong>' + sheet.Employee__r.Name + '</strong> has submitted their timesheet for your approval.</p>';
        
        html += '<div style="background-color: #f5f5f5; padding: 15px; margin: 20px 0; border-radius: 5px;">';
        html += '<h3 style="margin-top: 0;">Week ' + sheet.Week_Number__c + ', ' + sheet.Week_Year__c + '</h3>';
        html += '<p><strong>Total Hours:</strong> ' + totalHours + '</p>';
        html += '<p><strong>Regular Hours:</strong> ' + regularHours + '</p>';
        html += '<p><strong>Overtime Hours:</strong> ' + overtimeHours + '</p>';
        html += '</div>';
        
        // Entry details table
        html += '<h3>Timesheet Entries:</h3>';
        html += '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">';
        html += '<thead><tr style="background-color: #4CAF50; color: white;">';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: left;">Date</th>';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: left;">Project</th>';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: left;">Task</th>';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: right;">Hours</th>';
        html += '</tr></thead><tbody>';
        
        for (TimesheetEntry__c entry : entries) {
            html += '<tr>';
            html += '<td style="padding: 8px; border: 1px solid #ddd;">' + entry.Date__c.format() + '</td>';
            html += '<td style="padding: 8px; border: 1px solid #ddd;">' + (entry.Project__r.Name != null ? entry.Project__r.Name : '-') + '</td>';
            html += '<td style="padding: 8px; border: 1px solid #ddd;">' + (entry.Tasks__c != null ? entry.Tasks__c : '-') + '</td>';
            html += '<td style="padding: 8px; border: 1px solid #ddd; text-align: right;">' + entry.Total_Hours__c + '</td>';
            html += '</tr>';
        }
        
        html += '</tbody></table>';
        
        // Action buttons
        html += '<div style="margin-top: 30px; text-align: center;">';
        html += '<a href="' + approveUrl + '" style="display: inline-block; padding: 12px 30px; margin: 10px; background-color: #4CAF50; color: white; text-decoration: none; border-radius: 5px; font-weight: bold;">Approve</a>';
        html += '<a href="' + rejectUrl + '" style="display: inline-block; padding: 12px 30px; margin: 10px; background-color: #f44336; color: white; text-decoration: none; border-radius: 5px; font-weight: bold;">Reject</a>';
        html += '</div>';
        
        html += '<p style="margin-top: 30px; font-size: 12px; color: #666;">This approval link will expire in 7 days.</p>';
        html += '<p style="font-size: 12px; color: #666;">If you cannot click the buttons above, copy and paste these links:</p>';
        html += '<p style="font-size: 11px; color: #666;">Approve: ' + approveUrl + '</p>';
        html += '<p style="font-size: 11px; color: #666;">Reject: ' + rejectUrl + '</p>';
        
        html += '</div></body></html>';
        
        return html;
    }
    
    /* =====================================================================================
       4. GENERATE SECURE APPROVAL TOKEN
    ===================================================================================== */
    private static String generateApprovalToken(Id timesheetId) {
        // Create a unique token using timesheet ID and timestamp
        String timestamp = String.valueOf(DateTime.now().getTime());
        String combined = timesheetId + timestamp + UserInfo.getOrganizationId();
        
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(combined));
        return EncodingUtil.convertToHex(hash).substring(0, 32);
    }
    
    /* =====================================================================================
       5. PROCESS APPROVAL (Called from Visualforce page or API)
    ===================================================================================== */
    @AuraEnabled
    public static Map<String, Object> processApproval(String token, String action, String comments) {
        try {
            // Validate token
            List<Timesheet__c> sheets = [
                SELECT Id, Employee__c, Manager__c, Approval_Status__c, 
                       Token_Expiry__c, Employee__r.Name, Employee__r.Email,
                       Week_Number__c, Week_Year__c
                FROM Timesheet__c
                WHERE Approval_Token__c = :token
                  AND Token_Expiry__c >= :DateTime.now()
                LIMIT 1
            ];
            
            if (sheets.isEmpty()) {
                throw new AuraHandledException('Invalid or expired approval link.');
            }
            
            Timesheet__c sheet = sheets[0];
            
            // Verify current user is the manager
            if (UserInfo.getUserId() != sheet.Manager__c) {
                throw new AuraHandledException('You are not authorized to approve this timesheet.');
            }
            
            // Update timesheet status
            if (action == 'approve') {
                sheet.Approval_Status__c = 'Approved';
                sheet.Approved_Date__c = DateTime.now();
                sheet.Approved_By__c = UserInfo.getUserId();
            } else if (action == 'reject') {
                sheet.Approval_Status__c = 'Rejected';
                sheet.Rejected_Date__c = DateTime.now();
                sheet.Rejected_By__c = UserInfo.getUserId();
            } else {
                throw new AuraHandledException('Invalid action.');
            }
            
            sheet.Approval_Comments__c = comments;
            sheet.Approval_Token__c = null; // Invalidate token
            update sheet;
            
            // ⭐ SMART UPDATE: Only update Submitted entries — never overwrite already-Approved ones
            List<TimesheetEntry__c> entries = [
                SELECT Id, Approval_Status__c FROM TimesheetEntry__c WHERE Timesheet__c = :sheet.Id
            ];
            
            List<TimesheetEntry__c> toUpdate = new List<TimesheetEntry__c>();
            for (TimesheetEntry__c entry : entries) {
                if (entry.Approval_Status__c == 'Submitted') {
                    entry.Approval_Status__c = (action == 'approve') ? 'Approved' : 'Rejected';
                    toUpdate.add(entry);
                }
                // Already Approved entries are deliberately left unchanged
            }
            if (!toUpdate.isEmpty()) update toUpdate;
            
            // ⭐ SMART PARENT STATUS: Recompute sheet status based on ALL entry statuses
            Boolean allApproved = true;
            Boolean anyRejected = false;
            Boolean anySubmitted = false;
            for (TimesheetEntry__c e : [
                SELECT Approval_Status__c FROM TimesheetEntry__c WHERE Timesheet__c = :sheet.Id
            ]) {
                if (e.Approval_Status__c != 'Approved') allApproved = false;
                if (e.Approval_Status__c == 'Rejected')  anyRejected = true;
                if (e.Approval_Status__c == 'Submitted') anySubmitted = true;
            }
            if (allApproved)       sheet.Approval_Status__c = 'Approved';
            else if (anyRejected)  sheet.Approval_Status__c = 'Rejected';
            else if (anySubmitted) sheet.Approval_Status__c = 'Submitted';
            update sheet;
            
            // Send confirmation email to employee
            sendEmployeeNotificationEmail(sheet, action, comments);
            
            Map<String, Object> response = new Map<String, Object>();
            response.put('success', true);
            response.put('action', action);
            response.put('message', 'Timesheet ' + action + 'd successfully');
            
            return response;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error processing approval: ' + e.getMessage());
        }
    }
    
    /* =====================================================================================
       6. SEND NOTIFICATION TO EMPLOYEE
    ===================================================================================== */
    private static void sendEmployeeNotificationEmail(Timesheet__c sheet, String action, String comments) {
        
        String status = action == 'approve' ? 'Approved' : 'Rejected';
        String color = action == 'approve' ? '#4CAF50' : '#f44336';
        
        String html = '<html><body style="font-family: Arial, sans-serif;">';
        html += '<div style="max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #ddd;">';
        html += '<h2 style="color: ' + color + ';">Timesheet ' + status + '</h2>';
        html += '<p>Hello ' + sheet.Employee__r.Name + ',</p>';
        html += '<p>Your timesheet for Week ' + sheet.Week_Number__c + ', ' + sheet.Week_Year__c + ' has been <strong>' + status.toLowerCase() + '</strong>.</p>';
        
        if (String.isNotBlank(comments)) {
            html += '<div style="background-color: #f5f5f5; padding: 15px; margin: 20px 0; border-radius: 5px;">';
            html += '<h3 style="margin-top: 0;">Comments:</h3>';
            html += '<p>' + comments + '</p>';
            html += '</div>';
        }
        
        if (action == 'reject') {
            html += '<p>Please make necessary corrections and resubmit your timesheet.</p>';
        }
        
        html += '</div></body></html>';
        
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[] { sheet.Employee__r.Email });
        mail.setSubject('Timesheet ' + status + ': Week ' + sheet.Week_Number__c + ', ' + sheet.Week_Year__c);
        mail.setHtmlBody(html);
        mail.setSaveAsActivity(false);
        
        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
    }
    
    /* =====================================================================================
       7. ALLOW MANAGER TO VIEW PENDING APPROVALS
    ===================================================================================== */
    @AuraEnabled(cacheable=false)
    public static List<Timesheet__c> getPendingApprovals() {
        Id managerId = UserInfo.getUserId();
        
        return [
            SELECT Id, Employee__r.Name, Week_Number__c, Week_Year__c, 
                   Submitted_Date__c, Approval_Status__c,
                   (SELECT Id, Date__c, Project__r.Name, Total_Hours__c 
                    FROM TimesheetEntry__r)
            FROM Timesheet__c
            WHERE Manager__c = :managerId
              AND Approval_Status__c = 'Submitted'
            ORDER BY Submitted_Date__c DESC
        ];
    }

    /* =====================================================================================
       8. SEND BATCH WH ENTRY APPROVAL EMAIL
    ===================================================================================== */
    public static void sendBatchWHEntryApprovalEmail(List<Id> entryIds) {
        if (entryIds == null || entryIds.isEmpty()) return;

        // Query entries with full related data
        List<TimesheetEntry__c> entries = [
            SELECT Id, Date__c, Project__r.Name, Tasks__c, Total_Hours__c, 
                   Approval_Token_WH__c, Timesheet__r.Employee__r.Name, 
                   Timesheet__r.Manager__r.Name, Timesheet__r.Manager__r.Email,
                   Timesheet__r.Week_Number__c, Timesheet__r.Week_Year__c
            FROM TimesheetEntry__c
            WHERE Id IN :entryIds
        ];

        if (entries.isEmpty()) return;

        TimesheetEntry__c sample = entries[0];
        String managerEmail = sample.Timesheet__r.Manager__r.Email;
        String managerName = sample.Timesheet__r.Manager__r.Name;
        String employeeName = sample.Timesheet__r.Employee__r.Name;
        String token = sample.Approval_Token_WH__c;
        Integer weekNum = Integer.valueOf(sample.Timesheet__r.Week_Number__c);
        Integer weekYr = Integer.valueOf(sample.Timesheet__r.Week_Year__c);

        if (String.isBlank(managerEmail)) return;

        // ⭐ DYNAMIC URL RESOLUTION (Matches working weekly submission)
        String currentHost = URL.getOrgDomainUrl().getHost();
        String siteBaseUrl = 'https://innovation-dream-9744.my.site.com/TSApprovalSite';
        
        if (currentHost.contains('--uatsandbox')) {
            siteBaseUrl = 'https://innovation-dream-9744--uatsandbox.sandbox.my.site.com/tsApproval';
        }

        String approveUrl = siteBaseUrl + '/apex/TimesheetApprovalPage?action=approve&token=' + token;
        String rejectUrl  = siteBaseUrl + '/apex/TimesheetApprovalPage?action=reject&token=' + token;
        
        Decimal batchTotalHours = 0;
        for (TimesheetEntry__c e : entries) batchTotalHours += (e.Total_Hours__c != null ? e.Total_Hours__c : 0);

        String html = '<html><body style="font-family: Arial, sans-serif; color: #333;">';
        html += '<div style="max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #eee; border-radius: 8px;">';
        html += '<h2 style="color: #4f46e5;">Weekend/Holiday Entry Approval</h2>';
        html += '<p>Hello ' + managerName + ',</p>';
        html += '<p><strong>' + employeeName + '</strong> has logged hours on a weekend or holiday. These entries require your separate acceptance before they can be included in the weekly submission.</p>';
        
        html += '<div style="background-color: #f5f5f5; padding: 15px; margin: 20px 0; border-radius: 5px;">';
        html += '<h3 style="margin-top: 0;">Week ' + weekNum + ', ' + weekYr + ' (Batch)</h3>';
        html += '<p><strong>Batch Total Hours:</strong> ' + batchTotalHours + '</p>';
        html += '</div>';

        html += '<table style="width: 100%; border-collapse: collapse; margin: 20px 0;">';
        html += '<tr style="background: #4f46e5; color: white;">';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: left;">Date</th>';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: left;">Project</th>';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: left;">Task</th>';
        html += '<th style="padding: 10px; border: 1px solid #ddd; text-align: right;">Hours</th>';
        html += '</tr>';

        for (TimesheetEntry__c e : entries) {
            html += '<tr>';
            html += '<td style="padding: 10px; border: 1px solid #ddd;">' + e.Date__c.format() + '</td>';
            html += '<td style="padding: 10px; border: 1px solid #ddd;">' + (e.Project__r.Name != null ? e.Project__r.Name : '') + '</td>';
            html += '<td style="padding: 10px; border: 1px solid #ddd;">' + (e.Tasks__c != null ? e.Tasks__c : '') + '</td>';
            html += '<td style="padding: 10px; border: 1px solid #ddd; text-align: right;">' + e.Total_Hours__c + '</td>';
            html += '</tr>';
        }
        html += '</table>';

        html += '<div style="text-align: center; margin-top: 30px;">';
        html += '<a href="' + approveUrl + '" style="display: inline-block; padding: 12px 30px; margin: 10px; background-color: #4CAF50; color: white; text-decoration: none; border-radius: 5px; font-weight: bold;">Approve Batch</a>';
        html += '<a href="' + rejectUrl + '" style="display: inline-block; padding: 12px 30px; margin: 10px; background-color: #f44336; color: white; text-decoration: none; border-radius: 5px; font-weight: bold;">Reject Batch</a>';
        html += '</div>';
        
        html += '<p style="margin-top: 30px; font-size: 12px; color: #666;">If the buttons above do not work, use these links:</p>';
        html += '<p style="font-size: 11px; color: #666;">Approve: ' + approveUrl + '</p>';
        html += '<p style="font-size: 11px; color: #666;">Reject: ' + rejectUrl + '</p>';
        html += '</div></body></html>';

        try {
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new String[] { managerEmail });
            mail.setSubject('Weekend/Holiday Entry Approval: ' + employeeName + ' (' + entries.size() + ' entries)');
            mail.setHtmlBody(html);
            mail.setSaveAsActivity(false);

            List<OrgWideEmailAddress> oweaList = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            if (!oweaList.isEmpty()) mail.setOrgWideEmailAddressId(oweaList[0].Id);

            Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
        } catch (Exception ex) {
            System.debug('Error sending WH approval email: ' + ex.getMessage());
        }
    }
}