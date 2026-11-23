public without sharing class WFH_Request {

    /* =====================================================
       For work from home components methods
    ====================================================== */

    @AuraEnabled(cacheable=true)
    public static List<String> getAllowedRequests(Id userId) {
        User u = [SELECT Id, Mode_of_work__c FROM User WHERE Id = :userId LIMIT 1];
        List<String> allowed = new List<String>();
        allowed.add('Leave');
        allowed.add('WFH');
        allowed.add('Hybrid');
        return allowed;
    }

    /* =====================================================
       Work from Home
    ====================================================== */

    @AuraEnabled(cacheable=true)
    public static Map<String, String> getManagerInfoforWFH(Id employeeId) {
        User u = [
            SELECT Id, Name, Employment_Type__c, ManagerId, Manager.Name
            FROM User WHERE Id = :employeeId LIMIT 1
        ];
        return new Map<String, String>{
            'employeeName'   => u.Name,
            'employmentType' => u.Employment_Type__c,
            'managerId'      => u.ManagerId,
            'managerName'    => u.Manager != null ? u.Manager.Name : 'No Manager'
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Holiday__c> getPublicHolidaysForDateRange(Date startDate, Date endDate) {
        try {
            return [
                SELECT Id, Name, Holiday_Date__c FROM Holiday__c
                WHERE Holiday_Date__c >= :startDate AND Holiday_Date__c <= :endDate
                ORDER BY Holiday_Date__c
            ];
        } catch (Exception e) {
            System.debug('Error fetching holidays: ' + e.getMessage());
            return new List<Holiday__c>();
        }
    }

    private static Set<Date> getPublicHolidays(Date startDate, Date endDate) {
        Set<Date> holidays = new Set<Date>();
        try {
            List<Holiday__c> holidayList = [
                SELECT Holiday_Date__c FROM Holiday__c
                WHERE Holiday_Date__c >= :startDate AND Holiday_Date__c <= :endDate
            ];
            for (Holiday__c h : holidayList) { holidays.add(h.Holiday_Date__c); }
        } catch (Exception e) {
            System.debug('Error fetching holidays: ' + e.getMessage());
        }
        return holidays;
    }

    private static Integer calculateWorkingDays(Date startDate, Date endDate) {
        Set<Date> publicHolidays = getPublicHolidays(startDate, endDate);
        Integer workingDays = 0;
        Date currentDate = startDate;
        while (currentDate <= endDate) {
            DateTime dt = DateTime.newInstance(currentDate, Time.newInstance(0,0,0,0));
            Integer dayNum = Integer.valueOf(dt.format('u'));
            if (dayNum != 6 && dayNum != 7 && !publicHolidays.contains(currentDate)) {
                workingDays++;
            }
            currentDate = currentDate.addDays(1);
        }
        return workingDays;
    }

    /* =====================================================
       Week & Cumulative Working Days Helper Methods
       - Standard work week: Monday to Sunday
       - Cumulative calculation counts: 'Approved', 'Pending', 'Pending HR Approval'
       - Excludes: 'Rejected' and 'Cancelled'
    ====================================================== */
    public static Date getWeekStartMonday(Date d) {
        if (d == null) return null;
        DateTime dt = DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0));
        Integer dayNum = Integer.valueOf(dt.format('u')); // 1=Mon ... 7=Sun
        return d.addDays(-(dayNum - 1));
    }

    public static Date getWeekEndSunday(Date d) {
        if (d == null) return null;
        return getWeekStartMonday(d).addDays(6);
    }

    public static Integer getMaxWeeklyCumulativeWFHDays(Id employeeId, Date startDate, Date endDate, Id excludeRequestId) {
        if (employeeId == null || startDate == null || endDate == null) {
            return 0;
        }

        Date rangeStart = getWeekStartMonday(startDate);
        Date rangeEnd = getWeekEndSunday(endDate);

        List<Work_from_home_Request__c> existingRequests;
        if (excludeRequestId != null) {
            existingRequests = [
                SELECT Id, Start_Date__c, End_Date__c, Status__c
                FROM Work_from_home_Request__c
                WHERE Employee__c = :employeeId
                AND Is_Active__c = true
                AND Status__c IN ('Approved', 'Pending', 'Pending HR Approval')
                AND (Start_Date__c <= :rangeEnd AND End_Date__c >= :rangeStart)
                AND Id != :excludeRequestId
            ];
        } else {
            existingRequests = [
                SELECT Id, Start_Date__c, End_Date__c, Status__c
                FROM Work_from_home_Request__c
                WHERE Employee__c = :employeeId
                AND Is_Active__c = true
                AND Status__c IN ('Approved', 'Pending', 'Pending HR Approval')
                AND (Start_Date__c <= :rangeEnd AND End_Date__c >= :rangeStart)
            ];
        }

        Set<Date> holidays = getPublicHolidays(rangeStart, rangeEnd);

        Integer maxWeeklyCount = 0;
        Date currentWeekStart = rangeStart;

        while (currentWeekStart <= rangeEnd) {
            Date currentWeekEnd = currentWeekStart.addDays(6);
            Set<Date> weekWorkingWFHDays = new Set<Date>();

            // 1. Working days of target request in this week
            Date cur = (startDate > currentWeekStart) ? startDate : currentWeekStart;
            Date limitEnd = (endDate < currentWeekEnd) ? endDate : currentWeekEnd;
            while (cur <= limitEnd) {
                DateTime dt = DateTime.newInstance(cur, Time.newInstance(0, 0, 0, 0));
                Integer dow = Integer.valueOf(dt.format('u'));
                if (dow != 6 && dow != 7 && !holidays.contains(cur)) {
                    weekWorkingWFHDays.add(cur);
                }
                cur = cur.addDays(1);
            }

            // 2. Working days of existing active requests in this week
            for (Work_from_home_Request__c ex : existingRequests) {
                Date exCur = (ex.Start_Date__c > currentWeekStart) ? ex.Start_Date__c : currentWeekStart;
                Date exLimitEnd = (ex.End_Date__c < currentWeekEnd) ? ex.End_Date__c : currentWeekEnd;
                while (exCur <= exLimitEnd) {
                    DateTime dt = DateTime.newInstance(exCur, Time.newInstance(0, 0, 0, 0));
                    Integer dow = Integer.valueOf(dt.format('u'));
                    if (dow != 6 && dow != 7 && !holidays.contains(exCur)) {
                        weekWorkingWFHDays.add(exCur);
                    }
                    exCur = exCur.addDays(1);
                }
            }

            if (weekWorkingWFHDays.size() > maxWeeklyCount) {
                maxWeeklyCount = weekWorkingWFHDays.size();
            }

            currentWeekStart = currentWeekStart.addDays(7);
        }

        return maxWeeklyCount;
    }

    public static Boolean requiresHRApproval(Work_from_home_Request__c req) {
        if (req == null) return false;

        Integer workingDays = req.Number_of_Days__c != null
            ? Integer.valueOf(req.Number_of_Days__c)
            : calculateWorkingDays(req.Start_Date__c, req.End_Date__c);

        if (workingDays >= 3) {
            return true;
        }

        Integer maxWeeklyDays = getMaxWeeklyCumulativeWFHDays(
            req.Employee__c, req.Start_Date__c, req.End_Date__c, req.Id
        );
        return maxWeeklyDays > 2;
    }

   @AuraEnabled(cacheable=false)
public static Map<String, Object> checkOverlappingRequests(Date startDate, Date endDate, Id employeeId) {
    Map<String, Object> result = new Map<String, Object>();
    Id currentUserId = UserInfo.getUserId();
    
    try {
        // ── 1. Check existing WFH requests (existing logic) ──────────────
        List<Work_from_home_Request__c> overlappingWFH = [
            SELECT Id, Start_Date__c, End_Date__c, Status__c
            FROM Work_from_home_Request__c
            WHERE Employee__c = :currentUserId
            AND Is_Active__c = true
            AND Status__c IN ('Pending', 'Approved', 'Pending HR Approval')
            AND (Start_Date__c <= :endDate AND End_Date__c >= :startDate)
            ORDER BY Start_Date__c
            LIMIT 50
        ];

        if (!overlappingWFH.isEmpty()) {
            String message = 'You already have Work From Home request(s) for the following dates:\n\n';
            for (Work_from_home_Request__c req : overlappingWFH) {
                message += '• ' + req.Start_Date__c.format() + ' to ' 
                         + req.End_Date__c.format() + ' (' + req.Status__c + ')\n';
            }
            message += '\nPlease select different dates or cancel the existing request first.';
            result.put('hasOverlap', true);
            result.put('message', message);
            result.put('hasLeaveConflict', false);
            return result;
        }

        // ── 2. ✅ NEW: Check existing Leave requests on the same dates ────
        List<Leave_Request__c> overlappingLeaves = [
            SELECT Id, Name, Start_Date__c, End_Date__c,
                   Is_Half_Day__c, Half_Day_Type__c,
                   Leave_Type__r.Leave_Type_Name__c, Status__c
            FROM Leave_Request__c
            WHERE Employee__c = :currentUserId
            AND Is_Active__c = true
            AND Status__c IN ('Pending', 'Approved')
            AND (Start_Date__c <= :endDate AND End_Date__c >= :startDate)
            LIMIT 1
        ];

        if (!overlappingLeaves.isEmpty()) {
            Leave_Request__c l = overlappingLeaves[0];
            String halfDayInfo = l.Is_Half_Day__c
                ? ' (' + l.Half_Day_Type__c + ' half-day)'
                : '';
            result.put('hasOverlap', false);
            result.put('message', '');
            result.put('hasLeaveConflict', true);
            result.put('conflictingLeave', new Map<String, Object>{
                'startDate'   => String.valueOf(l.Start_Date__c),
                'endDate'     => String.valueOf(l.End_Date__c),
                'isHalfDay'   => l.Is_Half_Day__c,
                'halfDayType' => l.Half_Day_Type__c != null ? l.Half_Day_Type__c : '',
                'leaveType'   => l.Leave_Type__r.Leave_Type_Name__c,
                'status'      => l.Status__c
            });
            return result;
        }

        // ── 3. No conflicts ───────────────────────────────────────────────
        result.put('hasOverlap', false);
        result.put('message', '');
        result.put('hasLeaveConflict', false);
        
    } catch (Exception e) {
        result.put('hasOverlap', false);
        result.put('message', '');
        result.put('hasLeaveConflict', false);
    }
    
    return result;
}

    /* =====================================================
       Submit WFH Request
    ====================================================== */

    @AuraEnabled
    public static String submitWorkFromHomeRequest(Work_from_home_Request__c wfhRequest) {
        try {
            if (wfhRequest.Start_Date__c == null || wfhRequest.End_Date__c == null)
                throw new AuraHandledException('Start Date and End Date are required');

            if (wfhRequest.End_Date__c < wfhRequest.Start_Date__c)
                throw new AuraHandledException('End Date cannot be earlier than Start Date');

            Date today = Date.today();
            if (wfhRequest.Start_Date__c < today || wfhRequest.End_Date__c < today)
                throw new AuraHandledException('Past dates are not allowed');

            User emp = [
                SELECT Id, Name, Email, ManagerId, Manager.Name, Manager.Email, Employment_Type__c
                FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
            ];

            if (emp.ManagerId == null)
                throw new AuraHandledException('Manager is not assigned');

            List<Work_from_home_Request__c> overlappingRequests = [
                SELECT Id, Start_Date__c, End_Date__c, Status__c
                FROM Work_from_home_Request__c
                WHERE Employee__c = :emp.Id AND Is_Active__c = true
                AND Status__c IN ('Pending', 'Approved', 'Pending HR Approval')
                AND (Start_Date__c <= :wfhRequest.End_Date__c AND End_Date__c >= :wfhRequest.Start_Date__c)
                LIMIT 1
            ];

            if (!overlappingRequests.isEmpty()) {
                Work_from_home_Request__c existing = overlappingRequests[0];
                throw new AuraHandledException(
                    'You already have a ' + existing.Status__c + ' WFH request from ' +
                    existing.Start_Date__c.format() + ' to ' + existing.End_Date__c.format() +
                    '. Please select different dates or cancel the existing request first.'
                );
            }

			// ✅ ADD: Also block if any Leave request exists on these dates
List<Leave_Request__c> leaveConflicts = [
    SELECT Id, Name, Start_Date__c, End_Date__c,
           Is_Half_Day__c, Half_Day_Type__c,
           Leave_Type__r.Leave_Type_Name__c, Status__c
    FROM Leave_Request__c
    WHERE Employee__c = :emp.Id
    AND Is_Active__c = true
    AND Status__c IN ('Pending', 'Approved')
    AND (Start_Date__c <= :wfhRequest.End_Date__c 
         AND End_Date__c >= :wfhRequest.Start_Date__c)
    LIMIT 1
];

if (!leaveConflicts.isEmpty()) {
    Leave_Request__c lc = leaveConflicts[0];
    String halfDayInfo = lc.Is_Half_Day__c
        ? ' (' + lc.Half_Day_Type__c + ' half-day)'
        : '';
    throw new AuraHandledException(
        'You have a ' + lc.Status__c + ' ' 
        + lc.Leave_Type__r.Leave_Type_Name__c + halfDayInfo 
        + ' leave request from ' + lc.Start_Date__c.format() 
        + ' to ' + lc.End_Date__c.format() 
        + '. WFH cannot be submitted on leave dates.'
    );
}

            Integer workingDays = calculateWorkingDays(wfhRequest.Start_Date__c, wfhRequest.End_Date__c);

            if (workingDays == 0)
                throw new AuraHandledException('No working days found in the selected date range.');

            if (workingDays > 5) {
                throw new AuraHandledException(
                    'WFH requests above 5 days require Management approval. ' +
                    'Please contact your Manager and HR directly to get approval.'
                );
            }

            wfhRequest.Employee__c         = emp.Id;
            wfhRequest.Manager__c          = emp.ManagerId;
            wfhRequest.Employment_Type__c  = emp.Employment_Type__c;
            wfhRequest.Applied_Date__c     = System.now();
            wfhRequest.Is_Active__c        = true;
            wfhRequest.Year__c             = String.valueOf(wfhRequest.Start_Date__c.year());
            wfhRequest.Number_of_Days__c   = workingDays;
            wfhRequest.Status__c           = 'Pending';
            wfhRequest.Approval_Level__c   = 'Manager';
            wfhRequest.HR_Approval_Status__c      = null;
            wfhRequest.HR_Comments__c             = null;
            wfhRequest.Comments__c                = null;
            wfhRequest.Manager_Approval_Status__c = null;

            insert wfhRequest;

            sendEmailToManager(wfhRequest, emp, workingDays);

            return wfhRequest.Id;

        } catch (DmlException dmlEx) {
            throw new AuraHandledException(dmlEx.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /* =====================================================
       Manager Decision
       - 1-2 days approved  → Final: Status = Approved
       - 3-5 days approved  → Status = Pending HR Approval + email HR
       - Any rejection      → Final: Status = Rejected
    ====================================================== */
    @AuraEnabled
    public static void processManagerDecision(Id wfhId, String decision, String comments) {
        try {
            Work_from_home_Request__c wfh = [
                SELECT Id, Employee__c, Employee__r.Name, Employee__r.Email,
                       Manager__c, Manager__r.Name, Manager__r.Email,
                       Start_Date__c, End_Date__c, Reason__c, Number_of_Days__c,
                       Status__c, Approval_Level__c
                FROM Work_from_home_Request__c
                WHERE Id = :wfhId LIMIT 1
            ];

            if (wfh.Status__c != 'Pending' || wfh.Approval_Level__c != 'Manager')
                throw new AuraHandledException('This request is no longer pending Manager approval.');

            wfh.Manager_Approval_Status__c = decision;
            wfh.Comments__c                = comments;

            if (decision == 'Rejected') {
                wfh.Status__c = 'Rejected';
                update wfh;
                sendRejectionEmailToEmployee(wfh, 'Manager', comments);

            } else if (decision == 'Approved') {
                Boolean needsHR = requiresHRApproval(wfh);

                if (!needsHR) {
                    // 1-2 days and weekly cumulative <= 2: Manager is final approver
                    wfh.Status__c = 'Approved';
                    update wfh;
                    sendApprovalEmailToEmployee(wfh, 'Manager');
                } else {
                    // 3-5 days OR cumulative weekly days > 2: Escalate to HR for Level 2
                    wfh.Status__c         = 'Pending HR Approval';
                    wfh.Approval_Level__c = 'HR';
                    update wfh;
                    sendEscalationEmailToEmployee(wfh, comments);
                    sendEmailToHR(wfh, comments);
                }
            }

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /* =====================================================
       HR Final Decision
       Approved → Status = Approved
       Rejected → Status = Rejected
    ====================================================== */
    @AuraEnabled
    public static void processHRDecision(Id wfhId, String decision, String comments) {
        try {
            Work_from_home_Request__c wfh = [
                SELECT Id, Employee__c, Employee__r.Name, Employee__r.Email,
                       Manager__c, Manager__r.Name, Manager__r.Email,
                       Start_Date__c, End_Date__c, Reason__c, Number_of_Days__c,
                       Status__c, Approval_Level__c, Comments__c
                FROM Work_from_home_Request__c
                WHERE Id = :wfhId LIMIT 1
            ];

            if (wfh.Status__c != 'Pending HR Approval' || wfh.Approval_Level__c != 'HR')
                throw new AuraHandledException('This request is no longer pending HR approval.');

            wfh.HR_Approval_Status__c = decision;
            wfh.HR_Comments__c        = comments;
            wfh.Status__c             = (decision == 'Approved') ? 'Approved' : 'Rejected';

            update wfh;

            if (decision == 'Approved') {
                sendApprovalEmailToEmployee(wfh, 'HR');
            } else {
                sendRejectionEmailToEmployee(wfh, 'HR', comments);
            }

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /* =====================================================
       Get my WFH requests (for LWC table)
    ====================================================== */
    @AuraEnabled(cacheable=true)
    public static List<Work_from_home_Request__c> getMyWFHRequests() {
        return [
            SELECT Id, Start_Date__c, End_Date__c, Number_of_Days__c,
                   Reason__c, Status__c, Approval_Level__c,
                   Manager_Approval_Status__c, HR_Approval_Status__c,
                   Cancelled_Date__c, Cancelled_Reason__c
            FROM Work_from_home_Request__c
            WHERE Employee__c = :UserInfo.getUserId()
            AND Is_Active__c = true
            ORDER BY CreatedDate DESC
        ];
    }

    /* =====================================================
       Email — Level 1 to Manager
       Table fields: Employee, Start Date, End Date, Reason only
    ====================================================== */
    private static void sendEmailToManager(
        Work_from_home_Request__c wfh,
        User employee,
        Integer workingDays
    ) {
        try {
            if (employee.Manager.Email == null) return;

            Boolean needsHR = requiresHRApproval(wfh);

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ employee.Manager.Email });
            mail.setSubject(
                'WFH Request – ' + (needsHR ? 'Level 1 Approval Needed' : 'Approval Needed') +
                ' | ' + employee.Name +
                ' (' + workingDays + ' day' + (workingDays > 1 ? 's' : '') + ')'
            );

            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            mail.setOrgWideEmailAddressId(owea.Id);

            String baseUrl = URL.getOrgDomainUrl().toExternalForm().contains('--')
                ? 'https://innovation-dream-9744--uatsandbox.sandbox.my.salesforce-sites.com/WFHApprovalSite'
                : 'https://innovation-dream-9744.my.salesforce-sites.com/WFHApprovalSite';
            String approvalUrl = baseUrl + '/apex/WFHApprovalPage?id=' + wfh.Id;

            String body = '<html><body style="font-family:Arial,sans-serif;">';
            body += '<h2 style="color:#0176d3;">WFH Request – '
                  + (needsHR ? 'Manager Approval Required (Level 1 of 2)' : 'Approval Required')
                  + '</h2>';

            if (needsHR) {
                Integer weeklyCumulative = getMaxWeeklyCumulativeWFHDays(wfh.Employee__c, wfh.Start_Date__c, wfh.End_Date__c, wfh.Id);
                String reasonDetail = (workingDays >= 3)
                    ? 'This request is for ' + workingDays + ' working days.'
                    : 'This request is for ' + workingDays + ' day(s), bringing the weekly cumulative total to ' + weeklyCumulative + ' working days (exceeding the 2-day limit).';

                body += '<div style="background:#fff3cd;border-left:4px solid #f57c00;padding:10px 14px;'
                      + 'border-radius:4px;margin-bottom:16px;font-size:13px;color:#92400e;">'
                      + '<strong>&#9432; 2-Level Approval Required</strong><br/>'
                      + reasonDetail + ' After your approval, '
                      + 'it will be forwarded to HR for final approval.'
                      + '</div>';
            }

            body += '<p>Dear ' + employee.Manager.Name + ',</p>';
            body += '<p><strong>' + employee.Name + '</strong> has submitted a WFH request '
                  + 'requiring your approval'
                  + (needsHR ? ' (Level 1 of 2).' : '.') + '</p>';

            // ── Trimmed table: Employee, Start Date, End Date, Reason only ──
            body += buildDetailsTable(wfh, employee);

            body += '<div style="text-align:center;margin:30px 0;">';
            body += '<a href="' + approvalUrl + '" style="background-color:#0176d3;color:white;'
                  + 'padding:14px 28px;text-decoration:none;border-radius:6px;'
                  + 'display:inline-block;font-weight:bold;">Review &amp; Approve / Reject</a>';
            body += '</div>';
            body += '</body></html>';

            mail.setHtmlBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        } catch (Exception e) {
            System.debug('Error sending manager email: ' + e.getMessage());
        }
    }

    /* =====================================================
       Email — Level 2 to HR
       TO: HR | CC: Manager
    ====================================================== */
    private static void sendEmailToHR(
        Work_from_home_Request__c wfh,
        String managerComments
    ) {
        try {
            String hrEmail = AppSettings.getHrEmail();
            if (String.isBlank(hrEmail)) {
                System.debug('HR email not configured in AppSettings');
                return;
            }

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ hrEmail });

            if (wfh.Manager__r.Email != null) {
                mail.setCcAddresses(new List<String>{ wfh.Manager__r.Email });
            }

            Integer requestDays = Integer.valueOf(wfh.Number_of_Days__c);
            Integer weeklyDays = getMaxWeeklyCumulativeWFHDays(wfh.Employee__c, wfh.Start_Date__c, wfh.End_Date__c, wfh.Id);
            String daysLabel = (requestDays >= 3)
                ? requestDays + ' days'
                : requestDays + ' days (Weekly Total: ' + weeklyDays + ' days)';

            mail.setSubject(
                'WFH Request – Level 2 HR Approval Needed | ' + wfh.Employee__r.Name +
                ' (' + daysLabel + ') – Manager Approved'
            );

            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            mail.setOrgWideEmailAddressId(owea.Id);

            String baseUrl = URL.getOrgDomainUrl().toExternalForm().contains('--')
                ? 'https://innovation-dream-9744--uatsandbox.sandbox.my.salesforce-sites.com/WFHApprovalSite'
                : 'https://innovation-dream-9744.my.salesforce-sites.com/WFHApprovalSite';
            String approvalUrl = baseUrl + '/apex/WFHApprovalPage?id=' + wfh.Id;

            String body = '<html><body style="font-family:Arial,sans-serif;">';
            body += '<h2 style="color:#7b5ea7;">WFH Request – HR Final Approval Required (Level 2)</h2>';
            body += '<div style="background:#f0eafa;border-left:4px solid #7b5ea7;padding:10px 14px;'
                  + 'border-radius:4px;margin-bottom:16px;font-size:13px;color:#4a3580;">'
                  + '<strong>&#10003; Manager approved this request</strong><br/>'
                  + 'Manager (' + wfh.Manager__r.Name + ') comments: '
                  + (String.isNotBlank(managerComments) ? '<em>' + managerComments + '</em>' : '<em>No comments</em>')
                  + '<br/>Your final approval is now required.'
                  + '</div>';
            body += '<p>Dear HR Team,</p>';
            body += '<p><strong>' + wfh.Employee__r.Name + '</strong>\'s WFH request has been '
                  + 'approved by their Manager and now requires your final approval.</p>';

            // ── Trimmed table: Employee, Start Date, End Date, Reason + Manager block ──
            body += '<table border="1" cellpadding="10" cellspacing="0"'
                  + ' style="border-collapse:collapse;width:100%;max-width:600px;">';
            body += '<tr style="background:#f3f3f3;"><td><strong>Employee</strong></td><td>' + wfh.Employee__r.Name + '</td></tr>';
            body += '<tr><td><strong>Start Date</strong></td><td>' + wfh.Start_Date__c.format() + '</td></tr>';
            body += '<tr style="background:#f3f3f3;"><td><strong>End Date</strong></td><td>' + wfh.End_Date__c.format() + '</td></tr>';
            body += '<tr><td><strong>Reason</strong></td><td>' + wfh.Reason__c + '</td></tr>';
            body += '<tr style="background:#f0eafa;"><td><strong>Manager</strong></td><td>' + wfh.Manager__r.Name + '</td></tr>';
            body += '<tr style="background:#f0eafa;"><td><strong>Manager Comments</strong></td>'
                  + '<td>' + (String.isNotBlank(managerComments) ? managerComments : '—') + '</td></tr>';
            body += '<tr style="background:#e8f5e9;"><td><strong>Level 1 (Manager)</strong></td>'
                  + '<td><span style="color:#2e7d32;font-weight:bold;">&#10003; Approved</span></td></tr>';
            body += '<tr style="background:#fff3cd;"><td><strong>Level 2 (HR)</strong></td>'
                  + '<td><span style="color:#f57c00;font-weight:bold;">Pending Your Approval</span></td></tr>';
            body += '</table>';

            body += '<div style="text-align:center;margin:30px 0;">';
            body += '<a href="' + approvalUrl + '" style="background-color:#7b5ea7;color:white;'
                  + 'padding:14px 28px;text-decoration:none;border-radius:6px;'
                  + 'display:inline-block;font-weight:bold;">Review &amp; Give Final Approval</a>';
            body += '</div>';
            body += '</body></html>';

            mail.setHtmlBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        } catch (Exception e) {
            System.debug('Error sending HR email: ' + e.getMessage());
        }
    }

    /* =====================================================
       Notify employee when escalated to HR
    ====================================================== */
    private static void sendEscalationEmailToEmployee(
        Work_from_home_Request__c wfh,
        String managerComments
    ) {
        try {
            if (wfh.Employee__r.Email == null) return;

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ wfh.Employee__r.Email });
            mail.setSubject('Your WFH Request – Manager Approved, Forwarded to HR');

            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            mail.setOrgWideEmailAddressId(owea.Id);

            String body = '<html><body style="font-family:Arial,sans-serif;">';
            body += '<h2 style="color:#0176d3;">WFH Request Update</h2>';
            body += '<p>Dear ' + wfh.Employee__r.Name + ',</p>';
            body += '<p>Your WFH request has been <strong style="color:#2e7d32;">approved by your Manager</strong> '
                  + '(' + wfh.Manager__r.Name + ') and forwarded to HR for final approval.</p>';
            body += '<table border="1" cellpadding="10" cellspacing="0"'
                  + ' style="border-collapse:collapse;width:100%;max-width:500px;">';
            body += '<tr style="background:#f3f3f3;"><td><strong>Start Date</strong></td><td>' + wfh.Start_Date__c.format() + '</td></tr>';
            body += '<tr><td><strong>End Date</strong></td><td>' + wfh.End_Date__c.format() + '</td></tr>';
            body += '<tr style="background:#f3f3f3;"><td><strong>Manager Comments</strong></td><td>' + (String.isNotBlank(managerComments) ? managerComments : '—') + '</td></tr>';
            body += '<tr style="background:#e8f5e9;"><td><strong>Level 1 (Manager)</strong></td>'
                  + '<td><span style="color:#2e7d32;font-weight:bold;">&#10003; Approved</span></td></tr>';
            body += '<tr style="background:#fff3cd;"><td><strong>Level 2 (HR)</strong></td>'
                  + '<td><span style="color:#f57c00;font-weight:bold;">Pending</span></td></tr>';
            body += '</table>';
            body += '<p style="color:#666;font-size:12px;">You will be notified once HR reviews your request.</p>';
            body += '</body></html>';

            mail.setHtmlBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        } catch (Exception e) {
            System.debug('Error sending escalation email: ' + e.getMessage());
        }
    }

    /* =====================================================
       Notify employee — Approved (final)
    ====================================================== */
    private static void sendApprovalEmailToEmployee(Work_from_home_Request__c wfh, String approvedBy) {
        try {
            if (wfh.Employee__r.Email == null) return;
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ wfh.Employee__r.Email });
            mail.setSubject('Your WFH Request has been Approved');
            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            mail.setOrgWideEmailAddressId(owea.Id);
            String body = '<html><body style="font-family:Arial,sans-serif;">';
            body += '<h2 style="color:#2e7d32;">&#10003; WFH Request Approved</h2>';
            body += '<p>Dear ' + wfh.Employee__r.Name + ',</p>';
            body += '<p>Your WFH request has been <strong style="color:#2e7d32;">Approved</strong> by ' + approvedBy + '.</p>';
            body += '<table border="1" cellpadding="10" cellspacing="0" style="border-collapse:collapse;width:100%;max-width:500px;">';
            body += '<tr style="background:#f3f3f3;"><td><strong>Start Date</strong></td><td>' + wfh.Start_Date__c.format() + '</td></tr>';
            body += '<tr><td><strong>End Date</strong></td><td>' + wfh.End_Date__c.format() + '</td></tr>';
            body += '<tr style="background:#e8f5e9;"><td><strong>Status</strong></td><td><span style="color:#2e7d32;font-weight:bold;">Approved</span></td></tr>';
            body += '</table>';
            body += '</body></html>';
            mail.setHtmlBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug('Error sending approval email: ' + e.getMessage());
        }
    }

    /* =====================================================
       Notify employee — Rejected
    ====================================================== */
    private static void sendRejectionEmailToEmployee(Work_from_home_Request__c wfh, String rejectedBy, String comments) {
        try {
            if (wfh.Employee__r.Email == null) return;
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ wfh.Employee__r.Email });
            mail.setSubject('Your WFH Request has been Rejected');
            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            mail.setOrgWideEmailAddressId(owea.Id);
            String body = '<html><body style="font-family:Arial,sans-serif;">';
            body += '<h2 style="color:#ba0517;">&#10007; WFH Request Rejected</h2>';
            body += '<p>Dear ' + wfh.Employee__r.Name + ',</p>';
            body += '<p>Your WFH request has been <strong style="color:#ba0517;">Rejected</strong> by ' + rejectedBy + '.</p>';
            body += '<table border="1" cellpadding="10" cellspacing="0" style="border-collapse:collapse;width:100%;max-width:500px;">';
            body += '<tr style="background:#f3f3f3;"><td><strong>Start Date</strong></td><td>' + wfh.Start_Date__c.format() + '</td></tr>';
            body += '<tr><td><strong>End Date</strong></td><td>' + wfh.End_Date__c.format() + '</td></tr>';
            body += '<tr style="background:#f3f3f3;"><td><strong>Reason for Rejection</strong></td><td>' + (String.isNotBlank(comments) ? comments : '—') + '</td></tr>';
            body += '<tr style="background:#ffe4e4;"><td><strong>Status</strong></td><td><span style="color:#ba0517;font-weight:bold;">Rejected</span></td></tr>';
            body += '</table>';
            body += '</body></html>';
            mail.setHtmlBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug('Error sending rejection email: ' + e.getMessage());
        }
    }

    /* =====================================================
       Helper: Manager notification table
       Fields: Employee, Start Date, End Date, Reason only
    ====================================================== */
    private static String buildDetailsTable(Work_from_home_Request__c wfh, User employee) {
        String t = '<table border="1" cellpadding="10" cellspacing="0"'
                 + ' style="border-collapse:collapse;width:100%;max-width:600px;">';
        t += '<tr style="background:#f3f3f3;"><td><strong>Employee</strong></td><td>' + employee.Name + '</td></tr>';
        t += '<tr><td><strong>Start Date</strong></td><td>' + wfh.Start_Date__c.format() + '</td></tr>';
        t += '<tr style="background:#f3f3f3;"><td><strong>End Date</strong></td><td>' + wfh.End_Date__c.format() + '</td></tr>';
        t += '<tr><td><strong>Reason</strong></td><td>' + wfh.Reason__c + '</td></tr>';
        t += '</table>';
        return t;
    }

    /* =====================================================
       Check employee WFH request for a given date
    ====================================================== */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> checkEmployeeWFHRequest(
            String employeeId, String checkDate) {

        Map<String, Object> result = new Map<String, Object>();
        try {
            Date targetDate = Date.valueOf(checkDate);

            List<Work_from_home_Request__c> requests = [
                SELECT Id, Status__c, Start_Date__c, End_Date__c
                FROM   Work_from_home_Request__c
                WHERE  Employee__c    = :employeeId
                  AND  Status__c     IN ('Pending', 'Approved', 'Pending HR Approval')
                  AND  Start_Date__c <= :targetDate
                  AND  End_Date__c   >= :targetDate
                LIMIT 1
            ];

            result.put('success',         true);
            result.put('hasValidRequest', !requests.isEmpty());

            if (!requests.isEmpty()) {
                result.put('requestId', requests[0].Id);
                result.put('status',    requests[0].Status__c);
            }

        } catch (Exception e) {
            result.put('success',         false);
            result.put('hasValidRequest', false);
            result.put('error',           e.getMessage());
        }
        return result;
    }

    /* =====================================================
       Cancel / Revoke WFH Request by Employee
       Allowed when:
       - Request is currently Pending, Pending HR Approval, or Approved
       - End_Date__c >= Date.today() (cannot cancel past WFH)
       - Not already Cancelled or Rejected
    ====================================================== */
    @AuraEnabled
    public static Map<String, Object> cancelWorkFromHomeRequest(Id wfhRequestId, String cancelReason) {
        Map<String, Object> response = new Map<String, Object>();
        try {
            if (wfhRequestId == null) {
                throw new AuraHandledException('Request ID is required.');
            }

            Work_from_home_Request__c wfh = [
                SELECT Id, Status__c, Start_Date__c, End_Date__c, Number_of_Days__c,
                       Reason__c, Employee__c, Employee__r.Name, Employee__r.Email,
                       Manager__c, Manager__r.Name, Manager__r.Email
                FROM Work_from_home_Request__c
                WHERE Id = :wfhRequestId
                LIMIT 1
            ];

            Id currentUserId = UserInfo.getUserId();
            if (wfh.Employee__c != currentUserId) {
                throw new AuraHandledException('You can only cancel your own Work From Home requests.');
            }

            if (wfh.Status__c == 'Cancelled') {
                throw new AuraHandledException('This request is already cancelled.');
            }

            if (wfh.Status__c == 'Rejected') {
                throw new AuraHandledException('Rejected requests cannot be cancelled.');
            }

            if (wfh.End_Date__c < Date.today()) {
                throw new AuraHandledException('Past Work From Home requests cannot be cancelled.');
            }

            String previousStatus = wfh.Status__c;
            wfh.Status__c           = 'Cancelled';
            wfh.Cancelled_Date__c   = System.now();
            wfh.Cancelled_By__c     = currentUserId;
            wfh.Cancelled_Reason__c = String.isNotBlank(cancelReason) ? cancelReason : 'Cancelled by employee';

            update wfh;

            // Send notification email to manager
            sendCancellationEmailToManager(wfh, previousStatus, cancelReason);

            response.put('success', true);
            response.put('message', 'Work From Home request cancelled successfully.');
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return response;
    }

    /* =====================================================
       Helper: Notify Manager when employee cancels WFH
    ====================================================== */
    private static void sendCancellationEmailToManager(
        Work_from_home_Request__c wfh,
        String previousStatus,
        String cancelReason
    ) {
        try {
            if (wfh.Manager__r == null || String.isBlank(wfh.Manager__r.Email)) {
                return;
            }

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ wfh.Manager__r.Email });
            mail.setSubject('WFH Request Cancelled by ' + wfh.Employee__r.Name);

            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE IsAllowAllProfiles = true LIMIT 1];
            mail.setOrgWideEmailAddressId(owea.Id);

            String body = '<html><body style="font-family:Arial,sans-serif;">';
            body += '<h2 style="color:#ba0517;">Work From Home Request Cancelled</h2>';
            body += '<p>Dear ' + wfh.Manager__r.Name + ',</p>';
            body += '<p><strong>' + wfh.Employee__r.Name + '</strong> has cancelled their Work From Home request '
                  + '(Previous Status: <strong>' + previousStatus + '</strong>).</p>';

            body += '<table border="1" cellpadding="10" cellspacing="0"'
                  + ' style="border-collapse:collapse;width:100%;max-width:600px;">';
            body += '<tr style="background:#f3f3f3;"><td><strong>Employee</strong></td><td>' + wfh.Employee__r.Name + '</td></tr>';
            body += '<tr><td><strong>Start Date</strong></td><td>' + wfh.Start_Date__c.format() + '</td></tr>';
            body += '<tr style="background:#f3f3f3;"><td><strong>End Date</strong></td><td>' + wfh.End_Date__c.format() + '</td></tr>';
            body += '<tr><td><strong>Working Days</strong></td><td>' + Integer.valueOf(wfh.Number_of_Days__c) + '</td></tr>';
            body += '<tr style="background:#f3f3f3;"><td><strong>Reason for WFH</strong></td><td>' + wfh.Reason__c + '</td></tr>';
            body += '<tr><td><strong>Cancellation Reason</strong></td><td>' 
                  + (String.isNotBlank(cancelReason) ? cancelReason : 'Not provided') + '</td></tr>';
            body += '<tr style="background:#ffe4e4;"><td><strong>Status</strong></td><td><span style="color:#ba0517;font-weight:bold;">Cancelled</span></td></tr>';
            body += '</table>';

            body += '<p style="color:#666;font-size:12px;margin-top:16px;">This record has been updated to Cancelled in the system.</p>';
            body += '</body></html>';

            mail.setHtmlBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug('Error sending cancellation email to manager: ' + e.getMessage());
        }
    }

}