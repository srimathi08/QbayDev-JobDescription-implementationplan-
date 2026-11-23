public without sharing class TeamLeadDashboardController {

    private without sharing class EffectiveUserResolver {
        public Id resolve() {
            Id currentUserId = UserInfo.getUserId();

            // Check 1: Manager__c stores this user's UserId directly
            Integer direct = [
                SELECT COUNT() FROM Contact
                WHERE Manager__c = :currentUserId LIMIT 1
            ];
            if (direct > 0) return currentUserId;

            // Get ContactId for portal/community user
            List<User> portalUser = [
                SELECT ContactId FROM User
                WHERE Id = :currentUserId
                AND ContactId != null
                LIMIT 1
            ];
            if (portalUser.isEmpty()) return currentUserId;

            Id myContactId = portalUser[0].ContactId;

            // Check 2: Manager__c stores the ContactId directly
            Integer viaContactId = [
                SELECT COUNT() FROM Contact
                WHERE Manager__c = :myContactId LIMIT 1
            ];
            if (viaContactId > 0) return myContactId;

            // Check 3: Another user linked to same ContactId has subordinates
            List<User> otherUsers = [
                SELECT Id FROM User
                WHERE ContactId = :myContactId
                AND Id != :currentUserId
                LIMIT 10
            ];
            for (User u : otherUsers) {
                Integer cnt = [
                    SELECT COUNT() FROM Contact
                    WHERE Manager__c = :u.Id LIMIT 1
                ];
                if (cnt > 0) return u.Id;
            }

            // Check 4: Match against all known manager IDs
            List<AggregateResult> managerIds = [
                SELECT Manager__c mgr FROM Contact
                WHERE Manager__c != null
                GROUP BY Manager__c
                LIMIT 200
            ];
            Set<Id> knownManagerIds = new Set<Id>();
            for (AggregateResult ar : managerIds) {
                knownManagerIds.add((Id) ar.get('mgr'));
            }
            if (knownManagerIds.contains(currentUserId)) return currentUserId;
            if (knownManagerIds.contains(myContactId))   return myContactId;

            for (User u : otherUsers) {
                if (knownManagerIds.contains(u.Id)) return u.Id;
            }

            return currentUserId;
        }
    }

private without sharing class TeamMemberFetcher {
    public List<Contact> fetch(Id effectiveId) {
        // Step 1: Get all contacts under this manager
        List<Contact> allContacts = [
            SELECT Id, Name, Employee_Id__c, Manager__c,
                   Birthdate, Phone, MobilePhone, Email, Title
            FROM   Contact
            WHERE  Manager__c = :effectiveId
            ORDER BY Name ASC
        ];
        if (allContacts.isEmpty()) return allContacts;

        // Step 2: Find which of those contacts have a linked User record
        Set<Id> contactIds = new Map<Id, Contact>(allContacts).keySet();
        Set<Id> contactsWithUser = new Set<Id>();
        
        // standard portal users
        for (User u : [
            SELECT ContactId FROM User
            WHERE  ContactId IN :contactIds AND IsActive = true LIMIT 200
        ]) {
            contactsWithUser.add(u.ContactId);
        }
        
        // custom internal synced users
        for (Contact c : [
            SELECT Id FROM Contact 
            WHERE Id IN :contactIds AND Internal_User__c != null
        ]) {
            contactsWithUser.add(c.Id);
        }

        // Step 3: Return only contacts that have an active linked User or internal sync
        List<Contact> result = new List<Contact>();
        for (Contact c : allContacts) {
            if (contactsWithUser.contains(c.Id)) {
                result.add(c);
            }
        }
        return result;
    }
}

    /**
     * Helper to resolve User ID from Contact ID (Supports Portal & Internal Sync)
     */
    public static Id getUserIdForContact(Id contactId) {
        if (contactId == null) return null;
        // 1. Try standard Portal link
        List<User> users = [SELECT Id FROM User WHERE ContactId = :contactId AND IsActive = true LIMIT 1];
        if (!users.isEmpty()) return users[0].Id;
        // 2. Try custom Internal sync
        List<Contact> contacts = [SELECT Internal_User__c FROM Contact WHERE Id = :contactId AND Internal_User__c != null LIMIT 1];
        if (!contacts.isEmpty()) return contacts[0].Internal_User__c;
        return null;
    }

    /**
     * Bulk helper to resolve User IDs from List of Contact IDs
     */
    public static List<Id> getUserIdsForContacts(List<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) return new List<Id>();
        Set<Id> userIds = new Set<Id>();
        // Portal
        for (User u : [SELECT Id FROM User WHERE ContactId IN :contactIds AND IsActive = true]) {
            userIds.add(u.Id);
        }
        // Internal
        for (Contact c : [SELECT Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
            userIds.add(c.Internal_User__c);
        }
        return new List<Id>(userIds);
    }

    private static Id resolveEffectiveUserId() {
        return new EffectiveUserResolver().resolve();
    }

    /* ══════════════════════════════════════════════════════
       STEP 1 — GET MY TEAM MEMBERS
       Fixed: uses EffectiveUserResolver so community/site users
       and internal users both resolve correctly.
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<Contact> getMyTeamMembers() {
        Id effectiveId = resolveEffectiveUserId();
        return new TeamMemberFetcher().fetch(effectiveId);
    }

    /* ══════════════════════════════════════════════════════
       STEP 2 — ATTENDANCE RECORDS
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<Employee_Attendance__c> getAttendanceRecords(Id contactId) {
        Id empUserId = getUserIdForContact(contactId);
        if (empUserId == null) return new List<Employee_Attendance__c>();
        return [
            SELECT  Id, Name, Date__c, Check_In_Time__c, Check_Out_Time__c,
                    Check_In_Location_Name__c, Check_Out_Location_Name__c,
                    Check_In_State__c, Check_Out_State__c, Hours_Worked__c,
                    Status__c, Work_Location__c, WFH_Approval_Status__c,
                    WFH_Reason__c, OD_Approval_Status__c, OD_Reason__c,
                    Is_OD_Request__c, Is_Multiple_Session__c, Notes__c,
                    Session_Number__c, Submitted_For_Approval__c,
                    Field_Work_Details__c, Approval_Comments__c,
                    Employee_Name__c, Employee_Name__r.Name, CreatedDate
            FROM    Employee_Attendance__c
            WHERE   Employee_Name__c = :empUserId
            ORDER BY Date__c DESC NULLS LAST, CreatedDate DESC
            LIMIT   200
        ];
    }

    /* ══════════════════════════════════════════════════════
       STEP 3 — TIMESHEET RECORDS
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<Timesheet__c> getTimesheetRecords(Id contactId) {
        Id employeeUserId = getUserIdForContact(contactId);
        if (employeeUserId == null) return new List<Timesheet__c>();
        Id currentUserId  = UserInfo.getUserId();

        List<Timesheet__c> results = [
            SELECT  Id, Name, Employee__c, Employee__r.Name, Manager__c,
                    Manager__r.Name, Approval_Status__c, Approved_By__c,
                    Approved_By__r.Name, Approved_Date__c, Approval_Token__c,
                    End_Date__c, Notes__c, Rejected_By__c, Rejected_By__r.Name
            FROM    Timesheet__c
            WHERE   Employee__c = :employeeUserId AND Manager__c = :currentUserId
            ORDER BY End_Date__c DESC LIMIT 20
        ];
        if (results.isEmpty()) {
            results = [
                SELECT  Id, Name, Employee__c, Employee__r.Name, Manager__c,
                        Manager__r.Name, Approval_Status__c, Approved_By__c,
                        Approved_By__r.Name, Approved_Date__c, Approval_Token__c,
                        End_Date__c, Notes__c, Rejected_By__c, Rejected_By__r.Name
                FROM    Timesheet__c
                WHERE   Employee__c = :employeeUserId
                ORDER BY End_Date__c DESC LIMIT 20
            ];
        }
        return results;
    }

    /* ══════════════════════════════════════════════════════
       STEP 3b — TIMESHEET ENTRIES
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<TimesheetEntry__c> getTimesheetEntries(Id contactId) {
        Id employeeUserId = getUserIdForContact(contactId);
        if (employeeUserId == null) return new List<TimesheetEntry__c>();
        Id currentUserId  = UserInfo.getUserId();

        List<Timesheet__c> sheets = [
            SELECT Id FROM Timesheet__c
            WHERE Employee__c = :employeeUserId AND Manager__c = :currentUserId
        ];
        if (sheets.isEmpty()) {
            sheets = [SELECT Id FROM Timesheet__c WHERE Employee__c = :employeeUserId];
        }
        if (sheets.isEmpty()) return new List<TimesheetEntry__c>();
        Set<Id> sheetIds = new Map<Id, Timesheet__c>(sheets).keySet();

        return [
            SELECT  Id, Name, Approval_Status__c, Approved_By__c,
                    Approved_By__r.Name, Approved_Date__c, Approver_Comments__c,
                    Billing_Status__c, Date__c, Description__c, End_Time__c,
                    Overtime_Hours__c, Project__c, Project__r.Name,
                    Regular_Hours__c, Start_Time__c, Status__c,
                    Submitted_Date__c, Task__c, Timesheet__c,
                    Timesheet__r.Name, Total_Hours__c
            FROM    TimesheetEntry__c
            WHERE   Timesheet__c IN :sheetIds
            ORDER BY Date__c DESC LIMIT 200
        ];
    }

    /* ══════════════════════════════════════════════════════
       STEP 4 — LEAVE REQUESTS
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<Leave_Request__c> getLeaveRequests(Id contactId) {
        Id empUserId = getUserIdForContact(contactId);
        if (empUserId == null) return new List<Leave_Request__c>();
        return [
            SELECT  Id, Name, Employee__c, Employee__r.Name, Employee_ID__c,
                    Leave_Type__c, Leave_Type__r.Name, Leave_Type_Name__c,
                    Start_Date__c, End_Date__c, Total_Days__c, Half_Day_Type__c,
                    Is_Half_Day__c, Is_Active__c, Is_Past_Leave__c,
                    Is_Upcoming_Leave__c, Is_Event_Based_Leave__c,
                    Event_Number__c, Applied_Date__c, Status__c, Reason__c,
                    Comments__c, Manager__c, Manager__r.Name, Manager_Comments__c,
                    Approved_By__c, Approved_By__r.Name, Approved_Date__c,
                    Rejected_By__c, Rejected_By__r.Name, Rejected_Date__c,
                    Rejection_Reason__c, Cancelled_By__c, Cancelled_Date__c,
                    Cancelled_Reason__c, Supporting_Documents__c, Year__c
            FROM    Leave_Request__c
            WHERE   Employee__c = :empUserId
            ORDER BY Start_Date__c DESC LIMIT 20
        ];
    }

@AuraEnabled
public static void updateLeaveStatus(Id leaveRequestId, String newStatus, String comments) {
    try {
        Leave_Request__c lr = [
            SELECT Id, Status__c, Employee__c,
                   Leave_Type__r.Leave_Type_Name__c,
                   Start_Date__c, End_Date__c, Total_Days__c,
                   Reason__c
            FROM Leave_Request__c
            WHERE Id = :leaveRequestId LIMIT 1
        ];

        // ✅ Accept 'Pending' and 'Pending Approval' — same guard as WFH
        String currentStatus = (lr.Status__c != null) ? lr.Status__c.toLowerCase() : '';
        if (!currentStatus.contains('pending')) {
            throw new AuraHandledException(
                'This request has already been ' + lr.Status__c.toLowerCase() +
                '. No further action needed.'
            );
        }

        String oldStatus = lr.Status__c;

        // ✅ Update record fields
        lr.Status__c = newStatus;
        if (String.isNotBlank(comments)) {
            lr.Manager_Comments__c = comments;
        }
        if (newStatus == 'Approved') {
            lr.Approved_By__c   = UserInfo.getUserId();
            lr.Approved_Date__c = Date.today();
        }
        if (newStatus == 'Rejected') {
            lr.Rejected_By__c   = UserInfo.getUserId();
            lr.Rejected_Date__c = Date.today();
            if (String.isNotBlank(comments)) {
                lr.Rejection_Reason__c = comments;
            }
        }
        update lr;

        // ✅ Update leave balance — same as LeaveRequestController / VF page does
        LeaveRequestController.updateLeaveBalance(leaveRequestId, newStatus, oldStatus);

        // ✅ Send formatted email — same style as WFH email
        sendLeaveDecisionEmail(lr, newStatus, comments);

    } catch (AuraHandledException ahe) {
        throw ahe;
    } catch (Exception e) {
        throw new AuraHandledException('Failed to update leave status: ' + e.getMessage());
    }
}

// ✅ Formatted email — mirrors WFH rejection email style
private static void sendLeaveDecisionEmail(
    Leave_Request__c lr, String decision, String reason
) {
    try {
        List<User> empList = [
            SELECT Id, Name, Email
            FROM User
            WHERE Id = :lr.Employee__c
            LIMIT 1
        ];
        if (empList.isEmpty() || String.isBlank(empList[0].Email)) return;

        String empName    = empList[0].Name;
        String empEmail   = empList[0].Email;
        String leaveType  = lr.Leave_Type__r != null
                          ? lr.Leave_Type__r.Leave_Type_Name__c : 'Leave';
        String startDate  = lr.Start_Date__c != null ? lr.Start_Date__c.format() : '—';
        String endDate    = lr.End_Date__c   != null ? lr.End_Date__c.format()   : '—';
        String days       = lr.Total_Days__c != null
                          ? String.valueOf(lr.Total_Days__c) : '—';
        String managerName  = UserInfo.getName();
        Boolean isApproved  = decision == 'Approved';

        String subject      = isApproved ? '✓ Leave Request Approved'
                                         : '✕ Leave Request Rejected';
        String statusColor  = isApproved ? '#22c55e' : '#ef4444';
        String statusText   = isApproved ? 'Approved' : 'Rejected';
        String headerColor  = isApproved ? '#16a34a'  : '#dc2626';
        String headerSymbol = isApproved ? '✓' : '✕';
        String headerTitle  = isApproved ? 'Leave Request Approved'
                                         : 'Leave Request Rejected';

        String htmlBody =
            '<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;background:#1a1a1a;color:#fff;padding:20px;">'
            + '<div style="max-width:520px;margin:0 auto;">'
            + '<h2 style="color:' + headerColor + ';">' + headerSymbol + ' ' + headerTitle + '</h2>'
            + '<p>Dear ' + empName + ',</p>'
            + '<p>Your ' + leaveType + ' request has been '
            + '<span style="color:' + statusColor + ';font-weight:bold;">' + statusText + '</span>'
            + ' by Manager.</p>'
            + '<table style="width:100%;border-collapse:collapse;margin-top:12px;">'
            + '<tr><td style="padding:8px;border:1px solid #444;font-weight:bold;">Leave Type</td>'
            + '<td style="padding:8px;border:1px solid #444;">' + leaveType + '</td></tr>'
            + '<tr><td style="padding:8px;border:1px solid #444;font-weight:bold;">Start Date</td>'
            + '<td style="padding:8px;border:1px solid #444;">' + startDate + '</td></tr>'
            + '<tr><td style="padding:8px;border:1px solid #444;font-weight:bold;">End Date</td>'
            + '<td style="padding:8px;border:1px solid #444;">' + endDate + '</td></tr>'
            + '<tr><td style="padding:8px;border:1px solid #444;font-weight:bold;">Duration</td>'
            + '<td style="padding:8px;border:1px solid #444;">' + days + ' day(s)</td></tr>';

        // ✅ Show rejection reason in red (same as WFH)
        if (!isApproved && String.isNotBlank(reason)) {
            htmlBody +=
                '<tr style="background:#3a1a1a;">'
                + '<td style="padding:8px;border:1px solid #444;font-weight:bold;">Reason for Rejection</td>'
                + '<td style="padding:8px;border:1px solid #444;color:#ef4444;">'
                + reason + '</td></tr>';
        }

        // ✅ Show manager comments on approval
        if (isApproved && String.isNotBlank(reason)) {
            htmlBody +=
                '<tr>'
                + '<td style="padding:8px;border:1px solid #444;font-weight:bold;">Manager Comments</td>'
                + '<td style="padding:8px;border:1px solid #444;">'
                + reason + '</td></tr>';
        }

        htmlBody +=
            '<tr style="background:' + (isApproved ? '#1a3a1a' : '#3a1a1a') + ';">'
            + '<td style="padding:8px;border:1px solid #444;font-weight:bold;">Status</td>'
            + '<td style="padding:8px;border:1px solid #444;color:' + statusColor
            + ';font-weight:bold;">' + statusText + '</td></tr>'
            + '</table>'
            + '<p style="margin-top:16px;">Regards,<br/><strong>' + managerName + '</strong></p>'
            + '</div></body></html>';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ empEmail });
        mail.setSubject(subject);
        mail.setHtmlBody(htmlBody);
        mail.setSaveAsActivity(false);

        // ✅ Org-wide email sender — same as WFH
        try {
            List<OrgWideEmailAddress> owea = [
                SELECT Id FROM OrgWideEmailAddress
                WHERE IsAllowAllProfiles = true LIMIT 1
            ];
            if (!owea.isEmpty()) {
                mail.setOrgWideEmailAddressId(owea[0].Id);
            }
        } catch (Exception ex) {
            System.debug('OrgWide email lookup failed: ' + ex.getMessage());
        }

        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

    } catch (Exception e) {
        // ✅ Email failure never breaks approval flow — same as WFH
        System.debug('sendLeaveDecisionEmail failed silently: ' + e.getMessage());
    }
}
    /* ══════════════════════════════════════════════════════
       STEP 6 — MONTHLY ATTENDANCE SUMMARY
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getMonthlyAttendanceSummary(Id contactId) {
        Date firstDay = Date.today().toStartOfMonth();
        Date today    = Date.today();
        Id sumUserId = getUserIdForContact(contactId);
        if (sumUserId == null) {
            return new Map<String, Object>{'total'=>0,'present'=>0,'late'=>0,'absent'=>0,'rate'=>0};
        }
        List<Employee_Attendance__c> recs = [
            SELECT Status__c FROM Employee_Attendance__c
            WHERE Employee_Name__c = :sumUserId AND Date__c >= :firstDay AND Date__c <= :today
        ];
        Integer total = recs.size(), present = 0, late = 0, absent = 0;
        for (Employee_Attendance__c r : recs) {
            String s = r.Status__c != null ? r.Status__c.toLowerCase() : '';
            if      (s.contains('present')) present++;
            else if (s.contains('late'))    late++;
            else if (s.contains('absent'))  absent++;
        }
        Decimal rate = total > 0 ? ((present + late) * 100.0 / total).setScale(1) : 0;
        return new Map<String, Object>{'total'=>total,'present'=>present,'late'=>late,'absent'=>absent,'rate'=>rate};
    }

    @AuraEnabled(cacheable=true)
    public static List<Project__c> getActiveProjects() {
        return [
            SELECT  Id, Name, Status__c, Start_Date__c, End_Date__c,
                    Description__c, Notes__c, Project_Manager__c,
                    Project_Manager__r.Name, Project_Type__c,
                    Client__c, Client__r.Name, Budget__c, Actual_Cost__c
            FROM    Project__c WHERE Status__c = 'Active' ORDER BY Name ASC LIMIT 200
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Project_Assignment__c> getProjectAssignments(Id contactId) {
        Id empUserId = getUserIdForContact(contactId);
        if (empUserId == null) return new List<Project_Assignment__c>();
        return [
            SELECT  Id, Name, Employee__c, Employee__r.Name, Employment_Status__c,
                    Project__c, Project__r.Name, Project__r.Status__c,
                    Project__r.Start_Date__c, Project__r.End_Date__c,
                    Project__r.Description__c, Project__r.Project_Type__c,
                     Project__r.Client__r.Name, Role__c
            FROM    Project_Assignment__c
            WHERE   Employee__c = :empUserId ORDER BY CreatedDate DESC NULLS LAST
        ];
    }

    @AuraEnabled
    public static ProjectAssignResult assignProjectToEmployees(
        List<Id> contactIds, Id projectId, String role, String employmentStatus
    ) {
        ProjectAssignResult res = new ProjectAssignResult();
        List<Id> userIds = getUserIdsForContacts(contactIds);
        if (userIds.isEmpty()) throw new AuraHandledException('No portal users found for selected employees.');
        
        Map<Id, Id> contactToUser = new Map<Id, Id>();
        // Match them back for the loop below
        List<User> empUsers = [SELECT Id, ContactId FROM User WHERE Id IN :userIds];
        for (User u : empUsers) { if(u.ContactId != null) contactToUser.put(u.ContactId, u.Id); }
        // Also sync contacts
        for (Contact c : [SELECT Id, Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
            contactToUser.put(c.Id, c.Internal_User__c);
        }
        Set<Id> alreadyAssigned = new Set<Id>();
        for (Project_Assignment__c existing : [
            SELECT Employee__c FROM Project_Assignment__c
            WHERE Project__c = :projectId AND Employee__c IN :userIds
        ]) { alreadyAssigned.add(existing.Employee__c); }
        List<Project_Assignment__c> toInsert = new List<Project_Assignment__c>();
        for (Id cId : contactIds) {
            Id userId = contactToUser.get(cId);
            if (userId == null) { res.errorCount++; continue; }
            if (alreadyAssigned.contains(userId)) { res.duplicateCount++; }
            else {
                toInsert.add(new Project_Assignment__c(
                    Employee__c=userId, Project__c=projectId,
                    Role__c=role, Employment_Status__c=employmentStatus
                ));
            }
        }
        if (!toInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(toInsert, false);
            for (Database.SaveResult sr : results) {
                if (sr.isSuccess()) res.successCount++;
                else { res.errorCount++; for (Database.Error err : sr.getErrors()) res.errors.add(err.getMessage()); }
            }
        }
        if (res.successCount == 0 && res.duplicateCount > 0 && res.errorCount == 0) {
            throw new AuraHandledException('Selected employee(s) already have an assignment for this project.');
        }
        return res;
    }

    @AuraEnabled
    public static void removeProjectAssignment(Id assignmentId) {
        delete [SELECT Id FROM Project_Assignment__c WHERE Id = :assignmentId LIMIT 1];
    }

    /* ══════════════════════════════════════════════════════
       TEAM ATTENDANCE SUMMARY
       viewType: 'today' | 'weekly' | 'month_0'..'month_11'
    ══════════════════════════════════════════════════════ */
    
    /* ══════════════════════════════════════════════════════
   TEAM ATTENDANCE SUMMARY  — FIXED ATTENDANCE RATE
   Formula: (Present + Leave Days + Public Holidays) / Calendar Days × 100
   viewType: 'today' | 'weekly' | 'month_0'..'month_11'
══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static List<Map<String,Object>> getTeamSummary(List<Id> contactIds, String viewType) {
        List<Id> userIdsList = getUserIdsForContacts(contactIds);
        Set<Id> userIds = new Set<Id>(userIdsList);
        Date today = Date.today();
        Date startDate, endDate, queryEndDate;

        if (viewType == 'today') {
            startDate    = today;
            endDate      = today;
            queryEndDate = today;

        } else if (viewType == 'weekly') {
            Integer dow = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(today), 7);
            Integer daysFromMon;
            if      (dow == 0) daysFromMon = 6;
            else if (dow == 6) daysFromMon = 0;
            else               daysFromMon = dow - 1;
            startDate    = today.addDays(-daysFromMon);
            endDate      = today;
            queryEndDate = today;

        } else if (viewType != null && viewType.startsWith('month_')) {
            String monthStr = viewType.substring(6).trim();
            if (!monthStr.isNumeric()) {
                startDate    = today.toStartOfMonth();
                endDate      = today;
                queryEndDate = today;
            } else {
                Integer monthIdx      = Integer.valueOf(monthStr);
                Integer year          = today.year();
                Integer month1        = monthIdx + 1;
                Integer currentMonth0 = today.month() - 1;
                startDate = Date.newInstance(year, month1, 1);
                if (month1 == 12) {
                    endDate = Date.newInstance(year + 1, 1, 1).addDays(-1);
                } else {
                    endDate = Date.newInstance(year, month1 + 1, 1).addDays(-1);
                }
                queryEndDate = (monthIdx == currentMonth0) ? today : endDate;
            }
        } else {
            // Default fallback
            startDate    = today.toStartOfMonth();
            endDate      = today;
            queryEndDate = today;
        }

// ✅ Working days for LOP — only count days elapsed so far (queryEndDate)
Integer workingDays = countWorkingDays(startDate, queryEndDate);

// ✅ For rate formula — always use FULL month bounds
// endDate = last day of the month (April 30), regardless of today
Integer calendarDaysFullMonth = startDate.daysBetween(endDate) + 1;
Integer workingDaysFullMonth  = countWorkingDays(startDate, endDate);
Integer weekendCountFullMonth = calendarDaysFullMonth - workingDaysFullMonth;

// Public holidays — query against full month too
List<Holiday__c> holidays = [
    SELECT Holiday_Date__c FROM Holiday__c
    WHERE  Holiday_Date__c >= :startDate
    AND    Holiday_Date__c <= :endDate   // ← full month end, not queryEndDate
];
Set<Date> holidayDates = new Set<Date>();
for (Holiday__c h : holidays) { holidayDates.add(h.Holiday_Date__c); }
Integer publicHolidayCount = holidayDates.size();

    // ✅ Weekends in range
    Integer weekendCount = calendarDaysFullMonth - workingDays;

    // ── User / Contact lookups ──────────────────────────────
    List<User> users = [SELECT Id, ContactId FROM User WHERE Id IN :userIds];
    Map<Id,Id> c2u = new Map<Id,Id>();
    for (User u : users) { if (u.ContactId != null) c2u.put(u.ContactId, u.Id); }
    // Backfill sync field mappings
    for (Contact c : [SELECT Id, Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
        if (c.Internal_User__c != null) c2u.put(c.Id, c.Internal_User__c);
    }

    Map<Id,Contact> conMap = new Map<Id,Contact>([
        SELECT Id, Name, Employee_Id__c FROM Contact WHERE Id IN :contactIds
    ]);

    // ── Attendance records ─────────────────────────────────
    List<Employee_Attendance__c> atts = userIds.isEmpty()
        ? new List<Employee_Attendance__c>()
        : [
            SELECT Employee_Name__c, Date__c, Status__c, Hours_Worked__c
            FROM   Employee_Attendance__c
            WHERE  Employee_Name__c IN :userIds
            AND    Date__c >= :startDate
            AND    Date__c <= :queryEndDate
        ];

    Map<Id,Integer> presMap = new Map<Id,Integer>();
    Map<Id,Integer> lateMap = new Map<Id,Integer>();
    Map<Id,Integer> absMap  = new Map<Id,Integer>();
    Map<Id,Decimal> hrsMap  = new Map<Id,Decimal>();

    for (Employee_Attendance__c r : atts) {
        Id uid = r.Employee_Name__c;
        String s = (r.Status__c != null ? r.Status__c : '').toLowerCase();
        if (!presMap.containsKey(uid)) {
            presMap.put(uid, 0); lateMap.put(uid, 0); absMap.put(uid, 0); hrsMap.put(uid, 0);
        }
        if      (s.contains('present')) { presMap.put(uid, presMap.get(uid) + 1); }
        else if (s.contains('late'))    { presMap.put(uid, presMap.get(uid) + 1);
                                          lateMap.put(uid, lateMap.get(uid) + 1); }
        else if (s.contains('absent'))  { absMap.put(uid, absMap.get(uid) + 1); }
        if (r.Hours_Worked__c != null)  { hrsMap.put(uid, hrsMap.get(uid) + r.Hours_Worked__c); }
    }

    // ── Approved leaves ────────────────────────────────────
    List<Leave_Request__c> leaves = userIds.isEmpty()
        ? new List<Leave_Request__c>()
        : [
            SELECT Employee__c, Total_Days__c
            FROM   Leave_Request__c
            WHERE  Employee__c IN :userIds
            AND    Start_Date__c <= :queryEndDate
            AND    End_Date__c   >= :startDate
            AND    Status__c = 'Approved'
        ];
    Map<Id,Decimal> lvMap = new Map<Id,Decimal>();
    for (Leave_Request__c lr : leaves) {
        Decimal d = lvMap.containsKey(lr.Employee__c) ? lvMap.get(lr.Employee__c) : 0;
        lvMap.put(lr.Employee__c, d + (lr.Total_Days__c != null ? lr.Total_Days__c : 0));
    }

    // ── Build rows ─────────────────────────────────────────
// ── Build rows ─────────────────────────────────────────
List<Map<String,Object>> rows = new List<Map<String,Object>>();
for (Id cId : contactIds) {
    Contact con  = conMap.get(cId);
    Id uid       = c2u.get(cId);
    Integer pres = uid != null && presMap.containsKey(uid) ? presMap.get(uid) : 0;
    Integer late = uid != null && lateMap.containsKey(uid) ? lateMap.get(uid) : 0;
    Integer abs2 = uid != null && absMap.containsKey(uid)  ? absMap.get(uid)  : 0;
    Decimal hrs  = uid != null && hrsMap.containsKey(uid)  ? hrsMap.get(uid)  : 0;
    Decimal lv   = uid != null && lvMap.containsKey(uid)   ? lvMap.get(uid)   : 0;

    // LOP = working days - present - approved leave (floor at 0)
    Decimal lop  = Math.max(0, workingDays - pres - lv);

    // ✅ FORMULA: (Present + Weekends + Public Holidays) / Calendar Days × 100
    // weekendCount and publicHolidayCount are the same for all employees
Decimal numerator = pres + weekendCountFullMonth + publicHolidayCount;
Decimal rate = calendarDaysFullMonth > 0
    ? (numerator * 100.0 / calendarDaysFullMonth).setScale(1)
    : 0;


    rows.add(new Map<String,Object>{
        'contactId'      => cId,
        'name'           => con != null ? con.Name           : '',
        'employeeId'     => con != null ? con.Employee_Id__c : '',
        'present'        => pres,
        'late'           => late,
        'absent'         => abs2,
        'leaveDays'      => lv,
        'lop'            => lop,
        'totalHrs'       => hrs.setScale(1),
        'workingDays'    => workingDays,
        'calendarDays'   => calendarDaysFullMonth,
        'publicHolidays' => publicHolidayCount,
        'weekends'       => weekendCountFullMonth,
        'rate'           => rate
    });
}
return rows;
}

    private static Integer countWorkingDays(Date startDate, Date endDate) {
        Integer count = 0;
        Date cur = startDate;
        while (cur <= endDate) {
            Integer dow = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(cur), 7);
            if (dow != 0 && dow != 6) count++;
            cur = cur.addDays(1);
        }
        return count;
    }
/* ══════════════════════════════════════════════════════
   TEAM TIMESHEET SUMMARY  — FIXED
   viewType: 'today' | 'weekly' | 'month_0'..'month_11'
══════════════════════════════════════════════════════ */
@AuraEnabled(cacheable=false)
public static List<Map<String,Object>> getTeamTimesheetSummary(
        List<Id> contactIds, String viewType) {
    List<Id> userIdsList = getUserIdsForContacts(contactIds);
    Set<Id> userIdsSet = new Set<Id>(userIdsList);
    Date today = Date.today();
    Date startDate, endDate;

    // ✅ FIX 1: Full month_X parsing (was missing — fell to else → always current month)
    if (viewType == 'today') {
        startDate = today;
        endDate   = today;

    } else if (viewType == 'weekly') {
        // ✅ FIX 2: Monday-based week (consistent with getTeamSummary)
        Integer dow = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(today), 7);
        Integer daysFromMon;
        if      (dow == 0) daysFromMon = 6;
        else if (dow == 6) daysFromMon = 0;
        else               daysFromMon = dow - 1;
        startDate = today.addDays(-daysFromMon);
        endDate   = today;

    } else if (viewType != null && viewType.startsWith('month_')) {
        // ✅ FIX 3: Parse month_0..month_11 correctly
        String monthStr = viewType.substring(6).trim();
        if (!monthStr.isNumeric()) {
            startDate = today.toStartOfMonth();
            endDate   = today;
        } else {
            Integer monthIdx      = Integer.valueOf(monthStr);
            Integer year          = today.year();
            Integer month1        = monthIdx + 1;          // 0-based → 1-based
            Integer currentMonth0 = today.month() - 1;
            startDate = Date.newInstance(year, month1, 1);
            if (month1 == 12) {
                endDate = Date.newInstance(year + 1, 1, 1).addDays(-1);
            } else {
                endDate = Date.newInstance(year, month1 + 1, 1).addDays(-1);
            }
            // For current month, cap at today; past months use full month end
            if (monthIdx == currentMonth0) endDate = today;
        }
    } else {
        startDate = today.toStartOfMonth();
        endDate   = today;
    }

    List<User> users = [SELECT Id, ContactId FROM User WHERE Id IN :userIdsSet];
    Map<Id,Id> c2u = new Map<Id,Id>();
    for (User u : users) {
        if (u.ContactId != null) {
            c2u.put(u.ContactId, u.Id);
        }
    }
    for (Contact c : [SELECT Id, Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
        if (c.Internal_User__c != null) c2u.put(c.Id, c.Internal_User__c);
    }
    Map<Id,Contact> conMap = new Map<Id,Contact>([
        SELECT Id, Name, Employee_Id__c FROM Contact WHERE Id IN :contactIds
    ]);

    Map<Id, TimesheetProductivityService.ProductivityMetrics> prodMap =
        TimesheetProductivityService.calculateBulkProductivity(userIdsSet, startDate, endDate);

    List<Id> userIds = new List<Id>(userIdsSet);

    List<TimesheetEntry__c> entries = userIds.isEmpty()
        ? new List<TimesheetEntry__c>()
        : [
            SELECT  Id, Timesheet__c, Timesheet__r.Employee__c,
                    Timesheet__r.Approval_Status__c, Date__c,
                    Total_Hours__c, Billing_Status__c,
                    Approval_Status__c, Status__c
            FROM    TimesheetEntry__c
            WHERE   Timesheet__r.Employee__c IN :userIds
            AND     Date__c >= :startDate
            AND     Date__c <= :endDate
        ];

    Map<Id,Decimal> logBillMap     = new Map<Id,Decimal>();
    Map<Id,Decimal> logNonBillMap  = new Map<Id,Decimal>();
    Map<Id,Decimal> logShadowMap   = new Map<Id,Decimal>();
    Map<Id,Decimal> appBillMap     = new Map<Id,Decimal>();
    Map<Id,Decimal> appNonBillMap  = new Map<Id,Decimal>();
    Map<Id,Decimal> appShadowMap   = new Map<Id,Decimal>();
    Map<Id,Decimal> rejBillMap     = new Map<Id,Decimal>();
    Map<Id,Decimal> rejNonBillMap  = new Map<Id,Decimal>();
    Map<Id,Decimal> rejShadowMap   = new Map<Id,Decimal>();
    Map<Id,Integer> submittedMap   = new Map<Id,Integer>();
    Map<Id,Integer> approvedCntMap = new Map<Id,Integer>();
    Map<Id,Integer> rejectedCntMap = new Map<Id,Integer>();

    for (TimesheetEntry__c e : entries) {
        Id uid = e.Timesheet__r.Employee__c;
        if (uid == null) continue;
        if (!logBillMap.containsKey(uid)) {
            logBillMap.put(uid,0); logNonBillMap.put(uid,0); logShadowMap.put(uid,0);
            appBillMap.put(uid,0); appNonBillMap.put(uid,0); appShadowMap.put(uid,0);
            rejBillMap.put(uid,0); rejNonBillMap.put(uid,0); rejShadowMap.put(uid,0);
            submittedMap.put(uid,0); approvedCntMap.put(uid,0); rejectedCntMap.put(uid,0);
        }
        Decimal hrs = e.Total_Hours__c != null ? e.Total_Hours__c : 0;
        String billing = (e.Billing_Status__c != null ? e.Billing_Status__c : '').toLowerCase().trim();
        Boolean isBillable    = billing == 'billable';
        Boolean isNonBillable = billing.contains('non') || billing == 'non-billable' || billing == 'nonbillable';
        Boolean isShadow      = billing == 'shadow';
        if (!isBillable && !isNonBillable && !isShadow) isBillable = true;

        if      (isBillable)    logBillMap.put(uid, logBillMap.get(uid) + hrs);
        else if (isNonBillable) logNonBillMap.put(uid, logNonBillMap.get(uid) + hrs);
        else                    logShadowMap.put(uid, logShadowMap.get(uid) + hrs);

        String entryApproval = e.Approval_Status__c != null ? e.Approval_Status__c.toLowerCase() : '';
        String sheetApproval = e.Timesheet__r.Approval_Status__c != null ? e.Timesheet__r.Approval_Status__c.toLowerCase() : '';
        String entryStatus   = e.Status__c != null ? e.Status__c.toLowerCase() : '';

        Boolean isSubmitted = entryStatus.contains('submit') || sheetApproval.contains('submit')
                           || sheetApproval.contains('pending') || sheetApproval.contains('approved')
                           || sheetApproval.contains('rejected');
        if (isSubmitted) submittedMap.put(uid, submittedMap.get(uid) + 1);

        Boolean isApproved = entryApproval.contains('approved') || sheetApproval.contains('approved');
        Boolean isRejected = entryApproval.contains('rejected') || sheetApproval.contains('rejected');

        if (isApproved) {
            approvedCntMap.put(uid, approvedCntMap.get(uid) + 1);
            if      (isBillable)    appBillMap.put(uid, appBillMap.get(uid) + hrs);
            else if (isNonBillable) appNonBillMap.put(uid, appNonBillMap.get(uid) + hrs);
            else                    appShadowMap.put(uid, appShadowMap.get(uid) + hrs);
        }
        if (isRejected) {
            rejectedCntMap.put(uid, rejectedCntMap.get(uid) + 1);
            if      (isBillable)    rejBillMap.put(uid, rejBillMap.get(uid) + hrs);
            else if (isNonBillable) rejNonBillMap.put(uid, rejNonBillMap.get(uid) + hrs);
            else                    rejShadowMap.put(uid, rejShadowMap.get(uid) + hrs);
        }
    }

    List<Map<String,Object>> rows = new List<Map<String,Object>>();
    for (Id cId : contactIds) {
        Contact con = conMap.get(cId);
        Id uid      = c2u.get(cId);

        TimesheetProductivityService.ProductivityMetrics m =
            (uid != null) ? prodMap.get(uid) : null;
        if (m == null) m = new TimesheetProductivityService.ProductivityMetrics();

        Decimal lB  = uid != null && logBillMap.containsKey(uid)    ? logBillMap.get(uid).setScale(1)    : 0;
        Decimal lNB = uid != null && logNonBillMap.containsKey(uid) ? logNonBillMap.get(uid).setScale(1) : 0;
        Decimal lSh = uid != null && logShadowMap.containsKey(uid)  ? logShadowMap.get(uid).setScale(1)  : 0;
        Decimal lT  = lB + lNB + lSh;
        Decimal aB  = uid != null && appBillMap.containsKey(uid)    ? appBillMap.get(uid).setScale(1)    : 0;
        Decimal aNB = uid != null && appNonBillMap.containsKey(uid) ? appNonBillMap.get(uid).setScale(1) : 0;
        Decimal aSh = uid != null && appShadowMap.containsKey(uid)  ? appShadowMap.get(uid).setScale(1)  : 0;
        // ✅ FIX 4: approvedTotal from locally-computed entries (not m.approvedHours which ignores month filter)
        Decimal aT  = aB + aNB + aSh;
        Decimal rB  = uid != null && rejBillMap.containsKey(uid)    ? rejBillMap.get(uid).setScale(1)    : 0;
        Decimal rNB = uid != null && rejNonBillMap.containsKey(uid) ? rejNonBillMap.get(uid).setScale(1) : 0;
        Decimal rSh = uid != null && rejShadowMap.containsKey(uid)  ? rejShadowMap.get(uid).setScale(1)  : 0;
        Decimal rT  = rB + rNB + rSh;

        Integer submt  = uid != null && submittedMap.containsKey(uid)   ? submittedMap.get(uid)   : 0;
        Integer appCnt = uid != null && approvedCntMap.containsKey(uid) ? approvedCntMap.get(uid) : 0;
        Integer rejCnt = uid != null && rejectedCntMap.containsKey(uid) ? rejectedCntMap.get(uid) : 0;

        // ✅ FIX 5: productivity % based on locally-approved hours / target
        Decimal tgt    = m.targetHours > 0 ? m.targetHours : 1.0;
        Decimal prodB  = m.targetHours > 0 ? ((aB  * 100.0) / tgt).setScale(1) : 0.0;
        Decimal prodNB = m.targetHours > 0 ? ((aNB * 100.0) / tgt).setScale(1) : 0.0;
        Decimal prodS  = m.targetHours > 0 ? ((aSh * 100.0) / tgt).setScale(1) : 0.0;
        Decimal prodT  = m.targetHours > 0 ? ((aT  * 100.0) / tgt).setScale(1) : 0.0;

        rows.add(new Map<String,Object>{
            'contactId'          => cId,
            'name'               => con != null ? con.Name           : '',
            'employeeId'         => con != null ? con.Employee_Id__c : '',
            'loggedBillable'     => lB,
            'loggedNonBillable'  => lNB,
            'loggedShadow'       => lSh,
            'loggedTotal'        => lT,
            'approvedBillable'   => aB,
            'approvedNonBillable'=> aNB,
            'approvedShadow'     => aSh,
            'approvedTotal'      => aT,   // ✅ locally computed, not m.approvedHours
            'rejectedBillable'   => rB,
            'rejectedNonBillable'=> rNB,
            'rejectedShadow'     => rSh,
            'rejectedTotal'      => rT,
            'submitted'          => submt,
            'approved'           => appCnt,
            'rejected'           => rejCnt,
            'targetHours'        => m.targetHours,
            'leaveHours'         => m.leaveHours,
            'leaveDays'          => (m.leaveHours / 8.0).setScale(1),
            'prodBillable'       => prodB,
            'prodNonBillable'    => prodNB,
            'prodShadow'         => prodS,
            'productivityRate'   => prodT,  // ✅ FIX: was m.productivityPct (cross-month from service)
            'loggedHours'        => lT,
            'rejectedHours'      => rT
        });
    }
    return rows;
}

    /* ══════════════════════════════════════════════════════
       TEAM MEMBER LEAVES — drill-down panel
       viewType: 'today' | 'weekly' | 'month_0'..'month_11'
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static List<Map<String,Object>> getTeamMemberLeaves(Id contactId, String viewType) {
        Id userId = getUserIdForContact(contactId);
        if (userId == null) return new List<Map<String,Object>>();
        Date today = Date.today();
        Date startDate, endDate;

        if (viewType == 'today') {
            startDate = today;
            endDate   = today;

        } else if (viewType == 'weekly') {
            Integer dow = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(today), 7);
            Integer daysFromMon;
            if      (dow == 0) daysFromMon = 6;
            else if (dow == 6) daysFromMon = 0;
            else               daysFromMon = dow - 1;
            startDate = today.addDays(-daysFromMon);
            endDate   = today;

        } else if (viewType != null && viewType.startsWith('month_')) {
            String monthStr = viewType.substring(6).trim();
            if (!monthStr.isNumeric()) {
                startDate = today.toStartOfMonth();
                endDate   = today;
            } else {
                Integer monthIdx      = Integer.valueOf(monthStr);
                Integer year          = today.year();
                Integer month1        = monthIdx + 1;
                Integer currentMonth0 = today.month() - 1;
                startDate = Date.newInstance(year, month1, 1);
                if (monthIdx == currentMonth0) {
                    endDate = today;
                } else {
                    if (month1 == 12) {
                        endDate = Date.newInstance(year + 1, 1, 1).addDays(-1);
                    } else {
                        endDate = Date.newInstance(year, month1 + 1, 1).addDays(-1);
                    }
                }
            }
        } else {
            startDate = today.toStartOfMonth();
            endDate   = today;
        }

        Id empUserId = getUserIdForContact(contactId);
        if (empUserId == null) return new List<Map<String,Object>>();

        List<Leave_Request__c> leaves = [
            SELECT Id, Name,
                   Leave_Type__r.Leave_Type_Name__c,
                   Leave_Type__r.Leave_Code__c,
                   Start_Date__c, End_Date__c, Total_Days__c,
                   Is_Half_Day__c, Half_Day_Type__c,
                   Status__c, Reason__c, Applied_Date__c,
                   Manager_Comments__c
            FROM Leave_Request__c
            WHERE Employee__c = :empUserId
              AND Start_Date__c <= :endDate
              AND End_Date__c   >= :startDate
              AND Status__c IN ('Approved', 'Pending')
              AND Is_Active__c = true
            ORDER BY Start_Date__c DESC
        ];

        List<Map<String,Object>> result = new List<Map<String,Object>>();
        for (Leave_Request__c lv : leaves) {
            result.add(new Map<String,Object>{
                'id'          => lv.Id,
                'leaveName'   => lv.Name,
                'leaveType'   => lv.Leave_Type__r != null ? lv.Leave_Type__r.Leave_Type_Name__c : null,
                'leaveCode'   => lv.Leave_Type__r != null ? lv.Leave_Type__r.Leave_Code__c       : null,
                'startDate'   => lv.Start_Date__c,
                'endDate'     => lv.End_Date__c,
                'totalDays'   => lv.Total_Days__c,
                'isHalfDay'   => lv.Is_Half_Day__c,
                'halfDayType' => lv.Half_Day_Type__c,
                'status'      => lv.Status__c,
                'reason'      => lv.Reason__c,
                'appliedDate' => lv.Applied_Date__c,
                'comments'    => lv.Manager_Comments__c
            });
        }
        return result;
    }

    /* ══════════════════════════════════════════════════════
       FIX 1 — LEAVE REQUESTS (non-cacheable, for post-action refresh)
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static List<Leave_Request__c> getLeaveRequestsUncached(Id contactId) {
        Id empUserId = getUserIdForContact(contactId);
        if (empUserId == null) return new List<Leave_Request__c>();
        return [
            SELECT  Id, Name, Employee__c, Employee__r.Name, Employee_ID__c,
                    Leave_Type__c, Leave_Type__r.Name, Leave_Type_Name__c,
                    Start_Date__c, End_Date__c, Total_Days__c, Half_Day_Type__c,
                    Is_Half_Day__c, Is_Active__c, Is_Past_Leave__c,
                    Is_Upcoming_Leave__c, Is_Event_Based_Leave__c,
                    Event_Number__c, Applied_Date__c, Status__c, Reason__c,
                    Comments__c, Manager__c, Manager__r.Name, Manager_Comments__c,
                    Approved_By__c, Approved_By__r.Name, Approved_Date__c,
                    Rejected_By__c, Rejected_By__r.Name, Rejected_Date__c,
                    Rejection_Reason__c, Cancelled_By__c, Cancelled_Date__c,
                    Cancelled_Reason__c, Supporting_Documents__c, Year__c
            FROM    Leave_Request__c
            WHERE   Employee__c = :empUserId
            ORDER BY Start_Date__c DESC LIMIT 20
        ];
    }

    /* ══════════════════════════════════════════════════════
       FIX 2 — DYNAMIC PICKLIST VALUES
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=true)
    public static List<String> getPicklistValues(String objectApiName, String fieldApiName) {
        List<String> values = new List<String>();
        try {
            Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectApiName);
            if (objType == null) return values;
            Schema.DescribeSObjectResult objDesc = objType.getDescribe();
            Map<String, Schema.SObjectField> fieldMap = objDesc.fields.getMap();
            Schema.SObjectField field = fieldMap.get(fieldApiName);
            if (field == null) return values;
            Schema.DescribeFieldResult fieldDesc = field.getDescribe();
            List<Schema.PicklistEntry> entries = fieldDesc.getPicklistValues();
            for (Schema.PicklistEntry entry : entries) {
                if (entry.isActive()) { values.add(entry.getLabel()); }
            }
        } catch (Exception e) {
            System.debug('getPicklistValues error: ' + e.getMessage());
        }
        return values;
    }

    /* ══════════════════════════════════════════════════════
       PENDING APPROVAL COUNTS
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static Map<String,Object> getPendingApprovalCounts(List<Id> contactIds) {
        List<Id> userIdsList = getUserIdsForContacts(contactIds);
        Set<Id> userIds = new Set<Id>(userIdsList);
        if (userIds.isEmpty()) {
            return new Map<String,Object>{'leaveCount'=>0,'timesheetCount'=>0,'wfhCount'=>0};
        }

        Integer leaveCount = [
            SELECT COUNT() FROM Leave_Request__c
            WHERE Employee__c IN :userIds
            AND Status__c = 'Pending'
            AND Is_Active__c = true
        ];

        List<Timesheet__c> pendingSheets = [
            SELECT Id FROM Timesheet__c
            WHERE Employee__c IN :userIds
            AND Approval_Status__c IN ('Submitted', 'Pending Approval','Pending')
        ];
        Set<Id> pendingSheetIds = new Map<Id,Timesheet__c>(pendingSheets).keySet();
        Integer timesheetCount = pendingSheetIds.isEmpty() ? 0 : [
            SELECT COUNT() FROM TimesheetEntry__c
            WHERE Timesheet__c IN :pendingSheetIds
              AND (Approval_Status__c = 'Submitted'
                   OR Approval_Status__c = 'Pending'
                   OR Approval_Status__c = null)
        ];

        Integer wfhCount = [
            SELECT COUNT() FROM Work_from_home_Request__c
            WHERE Employee__c IN :userIds
            AND Status__c = 'Pending'
        ];

        return new Map<String,Object>{
            'leaveCount'     => leaveCount,
            'timesheetCount' => timesheetCount,
            'wfhCount'       => wfhCount
        };
    }



    /* ══════════════════════════════════════════════════════
       ALL PENDING WFH REQUESTS
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static List<Map<String,Object>> getPendingWfhAll(List<Id> contactIds) {
        // We need the mapping to get initials/name later
        List<Id> userIdsList = getUserIdsForContacts(contactIds);
        Set<Id> userIds = new Set<Id>(userIdsList);

        // Re-resolve mapping for initials
        Map<Id,Id> u2c = new Map<Id,Id>();
        for (User u : [SELECT Id, ContactId FROM User WHERE Id IN :userIds AND ContactId != null]) {
            u2c.put(u.Id, u.ContactId);
        }
        for (Contact c : [SELECT Id, Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
            u2c.put(c.Internal_User__c, c.Id);
        }

        Map<Id,Contact> conMap = new Map<Id,Contact>([
            SELECT Id, Name, Employee_Id__c FROM Contact WHERE Id IN :contactIds
        ]);

        List<Work_from_home_Request__c> records = userIds.isEmpty()
            ? new List<Work_from_home_Request__c>()
            : [
                SELECT  Id, Name, Employee__c, Manager__c,
                        Start_Date__c, End_Date__c,
                        Reason__c, Status__c, Comments__c,
                        Rejection_Reason__c
                FROM Work_from_home_Request__c
                WHERE Employee__c IN :userIds
                  AND Status__c = 'Pending'
                ORDER BY Start_Date__c DESC
                LIMIT 500
            ];

        List<Map<String,Object>> result = new List<Map<String,Object>>();
        for (Work_from_home_Request__c r : records) {
            Id cId = u2c.get(r.Employee__c);
            Contact con = cId != null ? conMap.get(cId) : null;
            String initials = '';
            if (con != null && con.Name != null) {
                List<String> parts = con.Name.split(' ');
                for (String p : parts) {
                    if (String.isNotBlank(p)) initials += p.substring(0,1).toUpperCase();
                }
                if (initials.length() > 2) initials = initials.substring(0,2);
            }
            result.add(new Map<String,Object>{
                'id'           => r.Id,
                'recordName'   => r.Name,
                'startDate'    => r.Start_Date__c,
                'endDate'      => r.End_Date__c,
                'reason'       => r.Reason__c,
                'status'       => r.Status__c,
                'comments'     => r.Comments__c,
                'employeeName' => con != null ? con.Name           : '—',
                'employeeId'   => con != null ? con.Employee_Id__c : '—',
                'empInitials'  => initials
            });
        }
        return result;
    }
@AuraEnabled
public static void updateWfhStatus(Id attendanceId, String newStatus, String comments) {
    try {
        Work_from_home_Request__c wfh = [
            SELECT Id, Manager_Approval_Status__c, Status__c, Comments__c
            FROM Work_from_home_Request__c
            WHERE Id = :attendanceId
            LIMIT 1
        ];

        if (wfh.Manager_Approval_Status__c != null
            && wfh.Manager_Approval_Status__c != 'Pending') {
            throw new AuraHandledException(
                'This WFH request has already been ' +
                wfh.Manager_Approval_Status__c.toLowerCase() +
                '. No further action needed.'
            );
        }

        if (newStatus == 'Approved') {
            // Delegate to processManagerDecision so the 3–5 day HR
            // escalation logic, all three emails, and status updates
            // are handled correctly in one place.
            WFH_Request.processManagerDecision(attendanceId, 'Approved', comments);
        } else {
            // Rejection path — processManagerDecision handles it too
            WFH_Request.processManagerDecision(attendanceId, 'Rejected', comments);
        }

    } catch (AuraHandledException ahe) {
        throw ahe;
    } catch (Exception e) {
        throw new AuraHandledException('Failed to update WFH status: ' + e.getMessage());
    }
}

    /* ══════════════════════════════════════════════════════
       ALL PENDING LEAVE REQUESTS — for Pending Approvals view
    ══════════════════════════════════════════════════════ */
@AuraEnabled(cacheable=false)
public static List<Map<String,Object>> getPendingLeaveAll(List<Id> contactIds) {
    List<Id> userIdsList = getUserIdsForContacts(contactIds);
    Set<Id> userIds = new Set<Id>(userIdsList);
    
    Map<Id,Id> u2c = new Map<Id,Id>();
    for (User u : [SELECT Id, ContactId FROM User WHERE Id IN :userIds AND ContactId != null]) {
        u2c.put(u.Id, u.ContactId);
    }
    for (Contact c : [SELECT Id, Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
        u2c.put(c.Internal_User__c, c.Id);
    }
    Map<Id,Contact> conMap = new Map<Id,Contact>([
        SELECT Id, Name, Employee_Id__c FROM Contact WHERE Id IN :contactIds
    ]);

    // ✅ Include both 'Pending' and 'Pending Approval'
    List<Leave_Request__c> leaves = userIds.isEmpty()
        ? new List<Leave_Request__c>()
        : [
            SELECT Id, Name, Employee__c, Leave_Type__r.Leave_Type_Name__c,
                   Start_Date__c, End_Date__c, Total_Days__c,
                   Is_Half_Day__c, Half_Day_Type__c,
                   Status__c, Reason__c, Applied_Date__c
            FROM Leave_Request__c
            WHERE Employee__c IN :userIds
              AND Status__c IN ('Pending', 'Pending Approval')
              AND Is_Active__c = true
            ORDER BY Applied_Date__c ASC
        ];

    List<Map<String,Object>> result = new List<Map<String,Object>>();
    for (Leave_Request__c lv : leaves) {
        Id cId = u2c.get(lv.Employee__c);
        Contact con = cId != null ? conMap.get(cId) : null;
        String initials = '';
        if (con != null && con.Name != null) {
            List<String> parts = con.Name.split(' ');
            for (String p : parts) { 
                if (String.isNotBlank(p)) initials += p.substring(0,1).toUpperCase(); 
            }
            if (initials.length() > 2) initials = initials.substring(0,2);
        }
        result.add(new Map<String,Object>{
            'id'           => lv.Id,
            'leaveName'    => lv.Name,
            'leaveType'    => lv.Leave_Type__r != null ? lv.Leave_Type__r.Leave_Type_Name__c : null,
            'startDate'    => lv.Start_Date__c,
            'endDate'      => lv.End_Date__c,
            'totalDays'    => lv.Total_Days__c,
            'isHalfDay'    => lv.Is_Half_Day__c,
            'halfDayType'  => lv.Half_Day_Type__c,
            'status'       => lv.Status__c,
            'reason'       => lv.Reason__c,
            'appliedDate'  => lv.Applied_Date__c,
            'employeeName' => con != null ? con.Name           : '—',
            'employeeId'   => con != null ? con.Employee_Id__c : '—',
            'empInitials'  => initials
        });
    }
    return result;
}

    /* ══════════════════════════════════════════════════════
       ALL PENDING TIMESHEET ENTRIES — for Pending Approvals view
    ══════════════════════════════════════════════════════ */
    @AuraEnabled(cacheable=false)
    public static List<Map<String,Object>> getPendingTimesheetAll(List<Id> contactIds) {
        List<Id> userIdsList = getUserIdsForContacts(contactIds);
        Set<Id> userIds = new Set<Id>(userIdsList);
        
        Map<Id,Id> u2c = new Map<Id,Id>();
        for (User u : [SELECT Id, ContactId FROM User WHERE Id IN :userIds AND ContactId != null]) {
            u2c.put(u.Id, u.ContactId);
        }
        for (Contact c : [SELECT Id, Internal_User__c FROM Contact WHERE Id IN :contactIds AND Internal_User__c != null]) {
            u2c.put(c.Internal_User__c, c.Id);
        }

        Map<Id,Contact> conMap = new Map<Id,Contact>([
            SELECT Id, Name, Employee_Id__c FROM Contact WHERE Id IN :contactIds
        ]);

        List<Timesheet__c> sheets = userIds.isEmpty()
            ? new List<Timesheet__c>()
            : [
                SELECT Id, Employee__c
                FROM Timesheet__c
                WHERE Employee__c IN :userIds
                  AND Approval_Status__c IN ('Submitted','Pending Approval','Pending')
            ];
        if (sheets.isEmpty()) return new List<Map<String,Object>>();

        Map<Id,Id> sheet2user = new Map<Id,Id>();
        for (Timesheet__c s : sheets) { sheet2user.put(s.Id, s.Employee__c); }

        List<TimesheetEntry__c> entries = [
            SELECT  Id, Date__c, Start_Time__c, End_Time__c,
                    Regular_Hours__c, Overtime_Hours__c, Total_Hours__c,
                    Project__r.Name, Tasks__c, Billing_Status__c,
                    Status__c, Approval_Status__c, Timesheet__c
            FROM TimesheetEntry__c
            WHERE Timesheet__c IN :sheet2user.keySet()
              AND (Approval_Status__c = 'Submitted'
                   OR Approval_Status__c = 'Pending'
                   OR Approval_Status__c = null)
            ORDER BY Date__c DESC
            LIMIT 500
        ];

        List<Map<String,Object>> result = new List<Map<String,Object>>();
        for (TimesheetEntry__c e : entries) {
            Id uid = sheet2user.get(e.Timesheet__c);
            Id cId = uid != null ? u2c.get(uid) : null;
            Contact con = cId != null ? conMap.get(cId) : null;
            String initials = '';
            if (con != null && con.Name != null) {
                List<String> parts = con.Name.split(' ');
                for (String p : parts) { if (String.isNotBlank(p)) initials += p.substring(0,1).toUpperCase(); }
                if (initials.length() > 2) initials = initials.substring(0,2);
            }
            result.add(new Map<String,Object>{
                'id'             => e.Id,
                'timesheetId'    => e.Timesheet__c,
                'date'           => e.Date__c,
                'startTime'      => e.Start_Time__c,
                'endTime'        => e.End_Time__c,
                'regularHours'   => e.Regular_Hours__c,
                'overtimeHours'  => e.Overtime_Hours__c,
                'totalHours'     => e.Total_Hours__c,
                'projectName'    => e.Project__r != null ? e.Project__r.Name : null,
                'task'           => e.Tasks__c,
                'billingStatus'  => e.Billing_Status__c,
                'status'         => e.Status__c,
                'approvalStatus' => e.Approval_Status__c,
                'employeeName'   => con != null ? con.Name           : '—',
                'employeeId'     => con != null ? con.Employee_Id__c : '—',
                'empInitials'    => initials
            });
        }
        return result;
    }

@AuraEnabled
public static void updateTimesheetStatus(Id recordId, String status, String comment) {
    try {
        if(recordId == null) {
            throw new AuraHandledException('Invalid record Id');
        }

        TimesheetEntry__c te = [
            SELECT Id, Approval_Status__c, Approver_Comments__c
            FROM TimesheetEntry__c
            WHERE Id = :recordId
            LIMIT 1
        ];

        // Allow approve without comment
        if(status == 'Rejected' && String.isBlank(comment)) {
            throw new AuraHandledException('Comment is required for rejection');
        }

        te.Approval_Status__c = status;

        // Only set comment if provided
        if(!String.isBlank(comment)) {
            te.Approver_Comments__c = comment;
        }

        update te;

    } catch (Exception e) {
        throw new AuraHandledException(e.getMessage());
    }
}

    @AuraEnabled(cacheable=true)
    public static Boolean isCurrentUserManager() {
        Id effectiveId = resolveEffectiveUserId();
        return new TeamMemberFetcher().fetch(effectiveId).size() > 0;
    }

 
@AuraEnabled
public static void sendApprovalEmail(
    Id     recordId,
    String recordType,
    String decision,
    String subject,
    String body,
    String comments
) {
    // ✅ NEVER throw from this method — email is non-fatal
    try {
        Id employeeUserId;

        if (recordType == 'leave') {
            List<Leave_Request__c> lr = [
                SELECT Employee__c FROM Leave_Request__c 
                WHERE Id = :recordId LIMIT 1
            ];
            if (!lr.isEmpty()) employeeUserId = lr[0].Employee__c;

        } else if (recordType == 'timesheet') {
            List<TimesheetEntry__c> te = [
                SELECT Timesheet__r.Employee__c FROM TimesheetEntry__c 
                WHERE Id = :recordId LIMIT 1
            ];
            if (!te.isEmpty()) employeeUserId = te[0].Timesheet__r.Employee__c;

        } else if (recordType == 'wfh') {
            List<Work_from_home_Request__c> wfh = [
                SELECT Employee__c FROM Work_from_home_Request__c 
                WHERE Id = :recordId LIMIT 1
            ];
            if (!wfh.isEmpty()) employeeUserId = wfh[0].Employee__c;
        }

        if (employeeUserId == null) return; // ✅ Silent skip

        List<User> empList = [
            SELECT Email, Name FROM User WHERE Id = :employeeUserId LIMIT 1
        ];
        if (empList.isEmpty() || String.isBlank(empList[0].Email)) return; // ✅ Silent skip

        String finalBody = String.isNotBlank(body) ? body : '';
        if (String.isNotBlank(comments)) {
            finalBody += '\n\n--- Manager Comments ---\n' + comments;
        }
        if (String.isBlank(finalBody)) return; // ✅ Nothing to send

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ empList[0].Email });
        mail.setSubject(
            String.isNotBlank(subject) 
                ? subject 
                : 'Your ' + recordType + ' request has been ' + decision
        );
        mail.setPlainTextBody(finalBody);
        mail.setSaveAsActivity(false);

        // ✅ Safe org-wide email lookup
        try {
            List<OrgWideEmailAddress> owea = [
                SELECT Id FROM OrgWideEmailAddress 
                WHERE IsAllowAllProfiles = true LIMIT 1
            ];
            if (!owea.isEmpty()) {
                mail.setOrgWideEmailAddressId(owea[0].Id);
            }
        } catch (Exception emailEx) {
            System.debug('OrgWide email lookup failed: ' + emailEx.getMessage());
        }

        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

    } catch (Exception e) {
        // ✅ Log but NEVER re-throw — email failure must not break approval flow
        System.debug('sendApprovalEmail failed silently: ' + e.getMessage());
    }
}
 

    // ── Result Wrapper ──
    public class ProjectAssignResult {
        @AuraEnabled public Integer      successCount   = 0;
        @AuraEnabled public Integer      duplicateCount = 0;
        @AuraEnabled public Integer      errorCount     = 0;
        @AuraEnabled public List<String> errors         = new List<String>();
    }
}