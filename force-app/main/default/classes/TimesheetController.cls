public without sharing class TimesheetController {
    public class ValidationException extends Exception {}

    public static final String WH_STATUS_REQUESTED = 'WH Entry - Requested';
    public static final String WH_STATUS_APPROVED  = 'WH Entry - Approved';
    public static final String WH_STATUS_REJECTED  = 'WH Entry - Rejected';
    public static final String STATUS_DRAFT         = 'Draft';

    /* =====================================================================================
       1.  GET PROJECTS ASSIGNED TO LOGGED-IN USER
    ===================================================================================== */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getProjects() {

        List<Project_Assignment__c> assignments = [
            SELECT Project__c, Project__r.Name, Employment_Status__c
            FROM Project_Assignment__c
            WHERE Employee__c = :UserInfo.getUserId()
                  AND Project__c != null
        ];

        Map<Id, String> employmentMap = new Map<Id, String>();
        Set<Id> projectIds = new Set<Id>();

        for (Project_Assignment__c pa : assignments) {
            employmentMap.put(pa.Project__c, pa.Employment_Status__c);
            projectIds.add(pa.Project__c);
        }

        List<Map<String, String>> projectList = new List<Map<String, String>>();

        if (!projectIds.isEmpty()) {
            for (Project__c p : [
                SELECT Id, Name
                FROM Project__c
                WHERE Id IN :projectIds AND Status__c = 'Active'
            ]) {
                Map<String, String> opt = new Map<String, String>();
                opt.put('label', p.Name);
                opt.put('value', p.Id);
                opt.put('employmentStatus', employmentMap.get(p.Id));
                projectList.add(opt);
            }
        }

        return projectList;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAllActiveProjects() {
        List<Map<String, String>> projectList = new List<Map<String, String>>();
        for (Project__c p : [
            SELECT Id, Name
            FROM Project__c
            WHERE Status__c = 'Active'
            ORDER BY Name ASC
        ]) {
            Map<String, String> opt = new Map<String, String>();
            opt.put('label', p.Name);
            opt.put('value', p.Id);
            projectList.add(opt);
        }
        return projectList;
    }

    /* =====================================================================================
       2.  GET ALL TIMESHEET ENTRIES FOR LOGGED-IN USER
    ===================================================================================== */
    @AuraEnabled(cacheable=true)
    public static List<TimesheetEntry__c> getEntries() {
        return [
            SELECT Id, Date__c, Project__c, Project__r.Name,
                   Related_Project__c, Related_Project__r.Name,
                   Start_Time__c, End_Time__c, Tasks__c,
                   Regular_Hours__c, Overtime_Hours__c, Total_Hours__c,
                   Status__c, Billing_Status__c,
                   Approval_Status__c, Timesheet__c, Timesheet__r.Employee__c
            FROM TimesheetEntry__c
            WHERE Timesheet__r.Employee__c = :UserInfo.getUserId()
            ORDER BY Date__c DESC
        ];
    }

    /* =====================================================================================
       3.  GET CURRENT WEEK TOTAL HOURS FOR LOGGED-IN USER
           Called by navigation.js to populate the "Hours This Week" metric card.
    ===================================================================================== */
    @AuraEnabled(cacheable=true)
    public static Decimal getCurrentWeekTotalHours() {
        Date today     = Date.today();
        Integer wn     = getWeekNumber(today);
        Integer yr     = today.year();
        Date weekStart = getWeekStartDate(wn, yr);   // Monday of current ISO week
        Date weekEnd   = weekStart.addDays(6);       // Sunday

        AggregateResult[] agg = [
            SELECT SUM(Total_Hours__c) totalHrs
            FROM TimesheetEntry__c
            WHERE Date__c                       >= :weekStart
            AND   Date__c                       <= :weekEnd
            AND   Timesheet__r.Employee__c       = :UserInfo.getUserId()
        ];

        Object raw = agg[0].get('totalHrs');
        return raw != null ? (Decimal) raw : 0;
    }

@AuraEnabled(cacheable=true)
public static List<String> getStatusPicklistValues() {
    Schema.DescribeFieldResult fieldResult = TimesheetEntry__c.Status__c.getDescribe();
    List<Schema.PicklistEntry> ple = fieldResult.getPicklistValues();

    List<String> statuses = new List<String>();
    for (Schema.PicklistEntry pe : ple) {
        statuses.add(pe.getValue());
    }
    return statuses;
}
private static Id getManagerForUser(Id userId) {

    User u = [
        SELECT Id, ManagerId
        FROM User
        WHERE Id = :userId
        LIMIT 1
    ];

    // Directly use User.ManagerId
    Id mgr = u.ManagerId;

    // Fallback (optional but recommended)
    if (mgr == null) {
        if (Test.isRunningTest()) {
            mgr = [SELECT Id FROM User WHERE IsActive = true LIMIT 1].Id;
        } else {
            // Default HR Manager user ID
            mgr = '005e1000000ypJAAQ'; 
        }
    }

    System.debug('FINAL MANAGER SELECTED = ' + mgr);
    return mgr;
}

Public static Timesheet__c getOrCreateWeeklyTimesheet(Date entryDate, Id userId) {

    Integer weekNumber = getWeekNumber(entryDate);
    Integer year = entryDate.year();

    // Check if Timesheet exists
    List<Timesheet__c> sheets = [
        SELECT Id, Manager__c
        FROM Timesheet__c
        WHERE Employee__c = :userId
          AND Week_Number__c = :weekNumber
          AND Week_Year__c = :year
        LIMIT 1
    ];
    // ⭐ FIX: UPDATE MANAGER IF NULL
    // -------------------------
    if (!sheets.isEmpty()) {

        Timesheet__c existing = sheets[0];

        if (existing.Manager__c == null) {
            existing.Manager__c = getManagerForUser(userId);
            update existing;
        }

        return existing;
    }
   
    // -----------------------------
    // Create Timesheet
    // -----------------------------
Id ManagerId = getManagerForUser(userId);
    Timesheet__c ts = new Timesheet__c(
        //Name       = 'TS-' + weekNumber + '-' + year,
        Employee__c = userId,
        Manager__c  = ManagerId,
        Week_Number__c = weekNumber,
        Week_Year__c   = year,
        Approval_Status__c = 'Draft'
    );
System.debug('Assigning Manager__c to: ' + ManagerId);
    insert ts;
    return ts;
}


    /* =====================================================================================
       4. CREATE SINGLE TIMESHEET ENTRY
    ===================================================================================== */
    @AuraEnabled
    public static Id createTimesheetEntry(Map<String, Object> fields) {
        try {
            Date entryDate = Date.valueOf((String)fields.get('Date__c'));
            Id projectId = (Id)fields.get('Project__c');
            Decimal hours = fields.get('Total_Hours__c') != null ? Decimal.valueOf(String.valueOf(fields.get('Total_Hours__c'))) : 0;
            
            checkDateRestriction(entryDate, UserInfo.getUserId(), projectId, hours);
            Timesheet__c ts = getOrCreateWeeklyTimesheet(entryDate, UserInfo.getUserId());

        TimesheetEntry__c te = new TimesheetEntry__c();
        te.Timesheet__c = ts.Id;

        for (String key : fields.keySet()) {
            Object val = fields.get(key);

            if (val == null) continue;

            if (key == 'Date__c') {
                te.Date__c = entryDate;
            }
            else if (key == 'Start_Time__c' || key == 'End_Time__c') {
                String t = (String)val;
                if (t != null && t.contains(':')) {
                    List<String> parts = t.split(':');
                    te.put(key, Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), 0, 0));
                } else {
                    te.put(key, null);
                }
            }
            else if (key != 'Id' && key != 'Timesheet__c') {
                te.put(key, val);
            }
        }

        if (te.Approval_Status__c == null) {
            if (isRestrictedDay(te.Date__c)) {
                te.Approval_Status__c = WH_STATUS_REQUESTED;
                te.Approval_Token_WH__c = generateToken(te.Id, UserInfo.getUserId());
                te.Token_Expiry_WH__c = DateTime.now().addDays(100);
            } else {
                te.Approval_Status__c = STATUS_DRAFT;
            }
        }

        // 4) Map Billing Status if provided, or lookup if missing
        te.Billing_Status__c = mapEmploymentStatusToBillingStatus(te.Billing_Status__c);
        if (te.Billing_Status__c == null && te.Project__c != null) {
            List<Project_Assignment__c> pa = [
                SELECT Employment_Status__c
                FROM Project_Assignment__c
                WHERE Employee__c = :UserInfo.getUserId()
                AND Project__c = :te.Project__c
                LIMIT 1
            ];
            if (!pa.isEmpty()) {
                te.Billing_Status__c = mapEmploymentStatusToBillingStatus(pa[0].Employment_Status__c);
            }
        }

        insert te;
        
        // If it's a WH entry, send approval email
        if (te.Approval_Status__c == WH_STATUS_REQUESTED) {
            TimesheetApprovalService.sendBatchWHEntryApprovalEmail(new List<Id>{te.Id});
        }
        
        return te.Id;
        } catch (ValidationException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Failed to create entry: ' + e.getMessage());
        }
    }

// Fetch allowed picklist values (cache on static if needed)
public static Set<String> getValidBillingStatuses() {
    Set<String> valid = new Set<String>();
    for (Schema.PicklistEntry pe : TimesheetEntry__c.Billing_Status__c.getDescribe().getPicklistValues()) {
        valid.add(pe.getValue());
    }
    return valid;
}
    @AuraEnabled
    public static List<Id> createMultipleTimesheetEntries(List<Map<String, Object>> rows) {
        return createMultipleTimesheetEntriesWithUser(rows, UserInfo.getUserId());
    }

    public static List<Id> createMultipleTimesheetEntriesWithUser(List<Map<String, Object>> rows, Id userId) {
        try {
            if (rows == null || rows.isEmpty()) {
                throw new AuraHandledException('No entries provided.');
            }
            System.debug('rows for user ' + userId + ': ' + rows);
            System.debug('rows'+rows);
            // Id userId = UserInfo.getUserId();

        // 1) Collect distinct week/year keys and project ids
        Set<Integer> years = new Set<Integer>();
        Set<Integer> weeks = new Set<Integer>();
        Set<Id> projectIds = new Set<Id>();
        Map<String, Date> keyToSampleDate = new Map<String, Date>();
        Set<String> keys = new Set<String>();

        for (Map<String, Object> r : rows) {
            if (!r.containsKey('Date__c') || r.get('Date__c') == null) {
                throw new AuraHandledException('Each row must include Date__c.');
            }
            Date entryDate;
                try {
                    entryDate = Date.valueOf((String) r.get('Date__c'));
                    Id projectId = r.get('Project__c') != null ? (Id)r.get('Project__c') : null;
                    Decimal hours = r.get('Total_Hours__c') != null ? Decimal.valueOf(String.valueOf(r.get('Total_Hours__c'))) : 0;
                    checkDateRestriction(entryDate, userId, projectId, hours);
                } catch (ValidationException vex) {
                    throw vex; 
                } catch (Exception ex) {
                    throw new AuraHandledException('Invalid format in one of the rows: ' + ex.getMessage());
                }

            Integer wk = getWeekNumber(entryDate);
            Integer yr = entryDate.year();
            weeks.add(wk);
            years.add(yr);

            String key = String.valueOf(wk) + '#' + String.valueOf(yr);
            keys.add(key);
            // remember a sample date for this key (used if needed)
            if (!keyToSampleDate.containsKey(key)) keyToSampleDate.put(key, entryDate);

            if (r.containsKey('Project__c') && r.get('Project__c') != null) {
                projectIds.add((Id) r.get('Project__c'));
            }
        }

        // 2) Query existing Timesheet__c for this user for these years (filter then match)
        Map<String, Timesheet__c> timesheetByKey = new Map<String, Timesheet__c>();

        if (!years.isEmpty()) {
            List<Timesheet__c> existingSheets = [
                SELECT Id, Week_Number__c, Week_Year__c
                FROM Timesheet__c
                WHERE Employee__c = :userId
                AND Week_Year__c IN :years
                // we didn't filter by weekNumbers in SOQL because cross-year combinations may vary;
            ];

            for (Timesheet__c s : existingSheets) {
                String k = String.valueOf(s.Week_Number__c) + '#' + String.valueOf(s.Week_Year__c);
                if (keys.contains(k)) timesheetByKey.put(k, s);
            }
        }

        // 3) Create missing Timesheet__c records in bulk
        List<Timesheet__c> toInsertSheets = new List<Timesheet__c>();

        for (String key : keys) {
            if (!timesheetByKey.containsKey(key)) {
                List<String> parts = key.split('#');
                Integer wk = Integer.valueOf(parts[0]);
                Integer yr = Integer.valueOf(parts[1]);
Id ManagerId = getManagerForUser(userId);

                // Fetch manager once (we will fetch it after preparing the list)
                Timesheet__c ts = new Timesheet__c(
                    Employee__c = userId, Manager__c  = ManagerId,
                    Week_Number__c = wk,
                    Week_Year__c = yr,
                    Approval_Status__c = 'Draft'
                );
                toInsertSheets.add(ts);
            }
        }

        if (!toInsertSheets.isEmpty()) {
            
            insert toInsertSheets;

            // add to map
            for (Timesheet__c s : toInsertSheets) {
                String k = String.valueOf(s.Week_Number__c) + '#' + String.valueOf(s.Week_Year__c);
                timesheetByKey.put(k, s);
            }
        }

        // 4) Query Project Assignments in bulk to populate Billing_Status__c
        Map<Id, Project_Assignment__c> paByProject = new Map<Id, Project_Assignment__c>();
        if (!projectIds.isEmpty()) {
            for (Project_Assignment__c pa : [
                SELECT Project__c, Employment_Status__c
                FROM Project_Assignment__c
                WHERE Employee__c = :userId
                  AND Project__c IN :projectIds
            ]) {
                paByProject.put(pa.Project__c, pa);
            }
        }

        // 5) Prepare Batch Token for WH entries
        String sharedBatchToken = generateToken(userId, DateTime.now().getTime());
        DateTime expiry = DateTime.now().addDays(100);

        // 6) Build TimesheetEntry__c records
        List<TimesheetEntry__c> toInsertEntries = new List<TimesheetEntry__c>();

        for (Map<String, Object> r : rows) {
            Date entryDate = Date.valueOf((String) r.get('Date__c'));
            Integer wk = getWeekNumber(entryDate);
            Integer yr = entryDate.year();
            String key = String.valueOf(wk) + '#' + String.valueOf(yr);

            Timesheet__c parent = timesheetByKey.get(key);
            if (parent == null) {
                throw new AuraHandledException('Internal error: missing timesheet for week ' + wk + ' year ' + yr);
            }

            TimesheetEntry__c te = new TimesheetEntry__c();
            te.Timesheet__c = parent.Id;
            te.Date__c = entryDate;

            // map other fields
            for (String keyName : r.keySet()) {
                if (r.get(keyName) == null) continue;
                if (keyName == 'Date__c' || keyName == 'Id' || keyName == 'Timesheet__c') continue;

                if (keyName == 'Start_Time__c' || keyName == 'End_Time__c') {
                    String t = (String) r.get(keyName);
                    List<String> parts = t.split(':');
                    if (parts.size() >= 2) {
                        te.put(keyName, Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), 0, 0));
                    }
                } else {
                    te.put(keyName, r.get(keyName));
                }
            }

            // Status & Billing logic
            te.Billing_Status__c = mapEmploymentStatusToBillingStatus(te.Billing_Status__c);
            if (te.Billing_Status__c == null && te.Project__c != null && paByProject.containsKey(te.Project__c)) {
                te.Billing_Status__c = mapEmploymentStatusToBillingStatus(paByProject.get(te.Project__c).Employment_Status__c);
            }

            if (te.Approval_Status__c == null) {
                if (isRestrictedDay(te.Date__c)) {
                    te.Approval_Status__c = WH_STATUS_REQUESTED;
                    te.Approval_Token_WH__c = sharedBatchToken;
                    te.Token_Expiry_WH__c = expiry;
                } else {
                    te.Approval_Status__c = STATUS_DRAFT;
                }
            }
            toInsertEntries.add(te);
        }

        if (toInsertEntries.isEmpty()) {
            throw new AuraHandledException('No valid entries to insert.');
        }

        // 6) Insert entries in bulk
        insert toInsertEntries;

        // 7) Handle WH emails
        List<Id> batchWhIds = new List<Id>();
        for (TimesheetEntry__c inserted : toInsertEntries) {
            if (inserted.Approval_Status__c == WH_STATUS_REQUESTED) {
                batchWhIds.add(inserted.Id);
            }
        }
        if (!batchWhIds.isEmpty()) {
            TimesheetApprovalService.sendBatchWHEntryApprovalEmail(batchWhIds);
        }

        // 8) Return inserted Ids
        List<Id> ids = new List<Id>();
        for (TimesheetEntry__c t : toInsertEntries) ids.add(t.Id);

        return ids;
    } catch (ValidationException e) {
        throw new AuraHandledException(e.getMessage());
    } catch (Exception e) {
        throw new AuraHandledException('Failed to create timesheet entries: ' + e.getMessage());
    }
}
    @AuraEnabled
    public static String checkDate(Date entryDate, Id projectId, Decimal hours) {
        try {
            checkDateRestriction(entryDate, UserInfo.getUserId(), projectId, hours);
            return null; // Valid
        } catch (ValidationException e) {
            return e.getMessage(); // Return the specific error message
        } catch (Exception e) {
            return 'Validation error: ' + e.getMessage();
        }
    }

    /* =====================================================================================
       5. UPDATE TIMESHEET ENTRY
    ===================================================================================== */
    @AuraEnabled
    public static Id updateTimesheetEntry(Map<String, Object> fields) {
        try {
            System.debug('fields'+fields);
            Id entryId = (Id) fields.get('Id');

            TimesheetEntry__c te = [
                SELECT Id, Date__c, Project__c, Approval_Status__c, Billing_Status__c,Status__c, Total_Hours__c
                FROM TimesheetEntry__c
                WHERE Id = :entryId
            ];

            for (String key : fields.keySet()) {
                if (key == 'Id' || key == 'Timesheet__c') continue;

                if (key == 'Date__c') {
                    te.Date__c = Date.valueOf((String)fields.get(key));
                }
                else if (key == 'Start_Time__c' || key == 'End_Time__c') {
                    String t = (String)fields.get(key);
                    if (t != null && t.contains(':')) {
                        List<String> parts = t.split(':');
                        te.put(key, Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), 0, 0));
                    } else {
                        te.put(key, null);
                    }
                }
                else {
                    te.put(key, fields.get(key));
                }
            }

            Decimal hours = te.Total_Hours__c != null ? te.Total_Hours__c : 0;
            checkDateRestriction(te.Date__c, UserInfo.getUserId(), te.Project__c, hours);
            update te;
            return te.Id;
        } catch (ValidationException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Failed to update entry: ' + e.getMessage());
        }
    }


    /* =====================================================================================
       6. DELETE ENTRY
    ===================================================================================== */
    @AuraEnabled
    public static Id deleteTimesheetEntry(Id entryId) {
        delete [SELECT Id FROM TimesheetEntry__c WHERE Id = :entryId LIMIT 1];
        return entryId;
    }


    /* =====================================================================================
       7. GET WEEKLY ENTRIES (Mon–Fri)
    ===================================================================================== */
    @AuraEnabled(cacheable=true)
    public static List<TimesheetEntry__c> getEntriesForWeek(Integer weekNumber, Integer year) {

        Date weekStart = getWeekStartDate(weekNumber, year);
        Date weekEnd = weekStart.addDays(6); // Changed from 4 to 6 to include Weekend

        return [
            SELECT Id, Date__c, Project__c, Project__r.Name,
                   Related_Project__c, Related_Project__r.Name,
                   Start_Time__c, End_Time__c, Tasks__c,
                   Regular_Hours__c, Overtime_Hours__c, Total_Hours__c,
                   Billing_Status__c, Approval_Status__c,Status__c,
                   Timesheet__c
            FROM TimesheetEntry__c
            WHERE Timesheet__r.Employee__c = :UserInfo.getUserId()
              AND Date__c >= :weekStart
              AND Date__c <= :weekEnd
            ORDER BY Date__c
        ];
    }


    /* =====================================================================================
       8. ISO WEEK START DATE (MONDAY)
    ===================================================================================== */
    public static Date getWeekStartDate(Integer weekNumber, Integer year) {

        Date jan4 = Date.newInstance(year, 1, 4);
        DateTime jan4DT = DateTime.newInstance(year, 1, 4, 0, 0, 0);

        Integer dowJan4 = Integer.valueOf(jan4DT.format('u')); // 1 = Monday
        Date week1Monday = jan4.addDays(1 - dowJan4);

        return week1Monday.addDays((weekNumber - 1) * 7);
    }


    /* =====================================================================================
       9. GET WEEK NUMBER FROM DATE (ISO)
    ===================================================================================== */
    public static Integer getWeekNumber(Date d) {

        DateTime dt = DateTime.newInstance(d.year(), d.month(), d.day(), 0, 0, 0);
        Integer dowToday = Integer.valueOf(dt.format('u'));

        Date mondayThisWeek = d.addDays(1 - dowToday);

        Date jan4 = Date.newInstance(d.year(), 1, 4);
        DateTime jan4DT = DateTime.newInstance(d.year(), 1, 4, 0, 0, 0);

        Integer dowJan4 = Integer.valueOf(jan4DT.format('u'));
        Date week1Monday = jan4.addDays(1 - dowJan4);

        Integer diff = week1Monday.daysBetween(mondayThisWeek);

        return (diff / 7) + 1;
    }


    /* =====================================================================================
       10. EXPECTED WEEKLY HOURS (Holidays + Leave)
    ===================================================================================== */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getWeeklyHoursStatus(Integer weekNumber, Integer year) {

        Id userId = UserInfo.getUserId();
        Date weekStart = getWeekStartDate(weekNumber, year);
        Date weekEnd = weekStart.addDays(4);

        Decimal expectedHours = getExpectedWeeklyHours(userId, weekNumber, year);
        Decimal actualHours = 0;

        for (TimesheetEntry__c e : [
            SELECT Total_Hours__c
            FROM TimesheetEntry__c
            WHERE Timesheet__r.Employee__c = :userId
            AND Date__c >= :weekStart
            AND Date__c <= :weekEnd
        ]) {
            actualHours += (e.Total_Hours__c != null ? e.Total_Hours__c : 0);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('expectedHours', expectedHours);
        result.put('actualHours', actualHours);
        result.put('pendingHours', expectedHours - actualHours);
        result.put('isComplete', actualHours >= expectedHours);

        return result;
    }


    /* =====================================================================================
       11. EXPECTED HOURS WITH HOLIDAYS + LEAVE
    ===================================================================================== */
    public static Decimal getExpectedWeeklyHours(Id userId, Integer weekNumber, Integer year) {

        Date weekStart = getWeekStartDate(weekNumber, year);
        Date weekEnd = weekStart.addDays(4);

        Decimal expected = 40; // Mon–Fri, 8 hours each

        // Holidays
        Integer holidayCount = [
            SELECT COUNT()
            FROM Holiday__c
            WHERE Is_Active__c = true
              AND Holiday_Date__c >= :weekStart
              AND Holiday_Date__c <= :weekEnd
        ];
        expected -= (holidayCount * 8);

        // Leave
        List<Leave_Request__c> leaves = [
            SELECT Start_Date__c, End_Date__c, Is_Half_Day__c
            FROM Leave_Request__c
            WHERE Employee__c = :userId
              AND Status__c = 'Approved'
              AND End_Date__c >= :weekStart
              AND Start_Date__c <= :weekEnd
        ];

        for (Leave_Request__c lv : leaves) {

            Date s = lv.Start_Date__c < weekStart ? weekStart : lv.Start_Date__c;
            Date e = lv.End_Date__c > weekEnd   ? weekEnd   : lv.End_Date__c;

            if (lv.Is_Half_Day__c) {
                expected -= 4;
            }
            else {
                expected -= ((e.daysBetween(s) + 1) * 8);
            }
        }

        return (expected < 0 ? 0 : expected);
    }

@AuraEnabled
public static Map<String, Object> submitWeeklyEntriesForApproval(Integer weekNumber, Integer year) {
    try {
        // Call the new approval service that handles email notifications
        return TimesheetApprovalService.sendApprovalRequestToManager(weekNumber, year);
    } catch (Exception e) {
        throw new AuraHandledException(e.getMessage());
    }
}
// ------- Check Weekly Submission Status -------
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> checkWeeklySubmissionStatus(Integer weekNumber, Integer year) {
        List<TimesheetEntry__c> entries = getEntriesForWeek(weekNumber, year);
        
        Boolean allSubmitted = true;
        Boolean anySubmitted = false;
        Boolean canSubmit = false;

        if (entries.isEmpty()) {
            canSubmit = false;
        } else {
            for (TimesheetEntry__c entry : entries) {
                if (entry.Approval_Status__c == 'Submitted' || entry.Approval_Status__c == 'Approved' || entry.Approval_Status__c == 'WH Entry - Approved' || entry.Approval_Status__c == 'WH Entry - Requested') {
                    anySubmitted = true;
                }
                
                // New Logic: Can submit if there's at least one Draft or Rejected entry
                if (entry.Approval_Status__c == 'Draft' || entry.Approval_Status__c == 'Rejected' || entry.Approval_Status__c == 'WH Entry - Rejected') {
                    canSubmit = true;
                }
                
                if (entry.Approval_Status__c != 'Submitted' && entry.Approval_Status__c != 'Approved' && entry.Approval_Status__c != 'WH Entry - Approved') {
                    allSubmitted = false;
                }
            }
        }

        Map<String, Object> status = new Map<String, Object>();
        status.put('hasEntries', !entries.isEmpty());
        status.put('canSubmit', canSubmit);
        status.put('allSubmitted', allSubmitted);    
        status.put('entryCount', entries.size());

        return status;
    }   
@AuraEnabled(cacheable=false)
public static Map<String, Object> getMonthlyBillingBreakdown() {
    Id userId = UserInfo.getUserId();
    Date today = Date.today();
    
    // 1. Current Month Period
    Date curMonthStart = Date.newInstance(today.year(), today.month(), 1);
    
    // 2. Last Month Period
    Date lastMonthStart = curMonthStart.addMonths(-1);
    Date lastMonthEnd   = curMonthStart.addDays(-1);

    // Get Month Names
    String curMonthName = Datetime.newInstance(curMonthStart, Time.newInstance(0, 0, 0, 0)).format('MMMM');
    String lastMonthName = Datetime.newInstance(lastMonthStart, Time.newInstance(0, 0, 0, 0)).format('MMMM');

    // --- Helper for calculating productivity for a range ---
    Map<String, Object> currentStats = calculateStatsForPeriod(userId, curMonthStart, today, true);
    Map<String, Object> lastMonthStats = calculateStatsForPeriod(userId, lastMonthStart, lastMonthEnd, false);

    Map<String, Object> result = new Map<String, Object>();
    
    // Map Current Month Data
    result.put('currentMonthName', curMonthName);
    result.put('productivityPct', currentStats.get('productivityPct'));
    result.put('billablePct', currentStats.get('billablePct'));
    result.put('nonBillablePct', currentStats.get('nonBillablePct'));
    result.put('shadowPct', currentStats.get('shadowPct'));
    result.put('totalHours', currentStats.get('totalHours'));
    
    // Map Last Month Data
    result.put('lastMonthName', lastMonthName);
    result.put('lastMonthProductivityPct', lastMonthStats.get('productivityPct'));
    result.put('lastMonthBillablePct', lastMonthStats.get('billablePct'));
    result.put('lastMonthNonBillablePct', lastMonthStats.get('nonBillablePct'));
    result.put('lastMonthShadowPct', lastMonthStats.get('shadowPct'));
    result.put('lastMonthPendingHours', lastMonthStats.get('pendingHours'));
    result.put('lastMonthTotalHours', lastMonthStats.get('totalHours'));

    return result;
}

private static Map<String, Object> calculateStatsForPeriod(Id userId, Date start, Date endD, Boolean isCurrentMonth) {
    // Collect all entries for the period
    List<TimesheetEntry__c> entries = [
        SELECT Total_Hours__c, Billing_Status__c, Approval_Status__c
        FROM TimesheetEntry__c
        WHERE Timesheet__r.Employee__c = :userId
        AND Date__c >= :start
        AND Date__c <= :endD
    ];

    Decimal billableApproved = 0;
    Decimal nonBillableApproved = 0;
    Decimal shadowApproved = 0;
    Decimal pendingSubmitted = 0;
    Decimal totalLogged = 0;

    for (TimesheetEntry__c te : entries) {
        Decimal hrs = te.Total_Hours__c != null ? te.Total_Hours__c : 0;
        totalLogged += hrs;

        if (te.Approval_Status__c == 'Approved' || te.Approval_Status__c == 'WH Entry - Approved') {
            if (te.Billing_Status__c == 'Billable') billableApproved += hrs;
            else if (te.Billing_Status__c == 'Non-Billable') nonBillableApproved += hrs;
            else if (te.Billing_Status__c == 'Shadow') shadowApproved += hrs;
        } else if (te.Approval_Status__c == 'Submitted' || te.Approval_Status__c == 'WH Entry - Requested') {
            pendingSubmitted += hrs;
        }
    }

    Decimal totalApproved = billableApproved + nonBillableApproved + shadowApproved;

    // --- Target Hours Calculation (remains same) ---
    Integer totalWeekdays = 0;
    for (Date d = start; d <= endD; d = d.addDays(1)) {
        Integer dayNum = Integer.valueOf(Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('u'));
        if (dayNum >= 1 && dayNum <= 5) totalWeekdays++;
    }

    List<Holiday__c> holidays = [SELECT Holiday_Date__c FROM Holiday__c 
                                WHERE Holiday_Date__c >= :start AND Holiday_Date__c <= :endD];
    for (Holiday__c h : holidays) {
        Integer dayNum = Integer.valueOf(Datetime.newInstance(h.Holiday_Date__c, Time.newInstance(0, 0, 0, 0)).format('u'));
        if (dayNum >= 1 && dayNum <= 5) totalWeekdays--;
    }

    List<Leave_Request__c> leaves = [SELECT Start_Date__c, End_Date__c, Is_Half_Day__c 
                                    FROM Leave_Request__c 
                                    WHERE Employee__c = :userId AND Status__c IN ('Approved', 'Pending')
                                    AND ((Start_Date__c >= :start AND Start_Date__c <= :endD)
                                         OR (End_Date__c >= :start AND End_Date__c <= :endD))];
    Decimal leaveWeekdayDays = 0;
    for (Leave_Request__c lr : leaves) {
        Date s = lr.Start_Date__c < start ? start : lr.Start_Date__c;
        Date e = lr.End_Date__c > endD ? endD : lr.End_Date__c;
        for (Date d = s; d <= e; d = d.addDays(1)) {
            Integer dayNum = Integer.valueOf(Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('u'));
            if (dayNum >= 1 && dayNum <= 5) leaveWeekdayDays += (lr.Is_Half_Day__c == true ? 0.5 : 1.0);
        }
    }

    Decimal targetHours = (totalWeekdays - leaveWeekdayDays) * 8.0;
    // Productivity % is now based ONLY on totalApproved
    Decimal productivityPct = (targetHours > 0) ? (totalApproved / targetHours * 100).setScale(1) : 0;

    Map<String, Object> stats = new Map<String, Object>();
    stats.put('productivityPct', productivityPct);
    stats.put('totalHours', totalLogged);
    stats.put('pendingHours', pendingSubmitted);
    
    if (totalApproved > 0) {
        stats.put('billablePct', (billableApproved / totalApproved * 100).setScale(1));
        stats.put('nonBillablePct', (nonBillableApproved / totalApproved * 100).setScale(1));
        stats.put('shadowPct', (shadowApproved / totalApproved * 100).setScale(1));
    } else {
        stats.put('billablePct', 0);
        stats.put('nonBillablePct', 0);
        stats.put('shadowPct', 0);
    }
    
    return stats;
}

    /* =====================================================================================
       12. GET RESTRICTED DATES FOR COMPONENT VALIDATION
    ===================================================================================== */
    @AuraEnabled(cacheable=true)
    public static Map<String, List<Date>> getRestrictedDatesForWeek(Integer weekNumber, Integer year) {
        Id userId = UserInfo.getUserId();
        Date weekStart = getWeekStartDate(weekNumber, year);
        Date weekEnd = weekStart.addDays(6); // Include full week (Mon-Sun)

        Map<String, List<Date>> result = new Map<String, List<Date>>();
        List<Date> holidayDates = new List<Date>();
        List<Date> leaveDates = new List<Date>();

        // Holidays
        for (Holiday__c h : [
            SELECT Holiday_Date__c 
            FROM Holiday__c 
            WHERE Is_Active__c = true 
            AND Holiday_Date__c >= :weekStart 
            AND Holiday_Date__c <= :weekEnd
        ]) {
            holidayDates.add(h.Holiday_Date__c);
        }

        // Leaves (Approved or Pending)
        for (Leave_Request__c lv : [
            SELECT Start_Date__c, End_Date__c 
            FROM Leave_Request__c 
            WHERE Employee__c = :userId 
            AND Status__c IN ('Approved', 'Pending')
            AND ((Start_Date__c >= :weekStart AND Start_Date__c <= :weekEnd)
                 OR (End_Date__c >= :weekStart AND End_Date__c <= :weekEnd)
                 OR (Start_Date__c <= :weekStart AND End_Date__c >= :weekEnd))
        ]) {
            Date s = lv.Start_Date__c < weekStart ? weekStart : lv.Start_Date__c;
            Date e = lv.End_Date__c > weekEnd ? weekEnd : lv.End_Date__c;
            for (Date d = s; d <= e; d = d.addDays(1)) {
                leaveDates.add(d);
            }
        }

        result.put('holidays', holidayDates);
        result.put('leaves', leaveDates);
        return result;
    }

    private static void checkDateRestriction(Date entryDate, Id userId, Id projectId, Decimal hours) {
        if (entryDate == null) return;

        // 0. Project Check for Weekend/Holiday Bypass
        Boolean allowWeekend = false;
        if (projectId != null) {
            List<Project__c> projs = [SELECT Allow_Weekend_Work__c FROM Project__c WHERE Id = :projectId LIMIT 1];
            if (!projs.isEmpty()) {
                allowWeekend = projs[0].Allow_Weekend_Work__c;
            }
        }

        // 1. Weekend/Holiday Check (Relaxed - now handled by creation logic status)
        /*
        if (!allowWeekend) {
            // Robust weekend check: 0=Sunday, 6=Saturday
            Integer dayOfWeek = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(entryDate), 7);
            if (dayOfWeek == 0 || dayOfWeek == 6) {
                throw new ValidationException('Timesheet entries are not allowed on weekends for this project.');
            }

            // 2. Holiday Check
            List<Holiday__c> holidays = [
                SELECT Name FROM Holiday__c 
                WHERE Is_Active__c = true AND Holiday_Date__c = :entryDate LIMIT 1
            ];
            if (!holidays.isEmpty()) {
                throw new ValidationException('Timesheet logging is restricted today: it is a public holiday (' + holidays[0].Name + ').');
            }
        }
        */

        // 3. Leave Check (Approved or Pending)
        List<Leave_Request__c> leaves = [
            SELECT Id, Is_Half_Day__c FROM Leave_Request__c 
            WHERE Employee__c = :userId 
            AND Status__c IN ('Approved', 'Pending')
            AND Start_Date__c <= :entryDate 
            AND End_Date__c >= :entryDate 
            LIMIT 1
        ];
        if (!leaves.isEmpty()) {
            if (leaves[0].Is_Half_Day__c == true) {
                if (hours > 5) {
                    throw new ValidationException('On a half-day leave, you can log a maximum of 5 hours.');
                }
            } else {
                throw new ValidationException('Timesheet entries are not allowed while on leave (Approved/Pending).');
            }
        }
    }

    private static Boolean isRestrictedDay(Date entryDate) {
        if (entryDate == null) return false;
        
        // 1. Weekend Check
        Integer dayOfWeek = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(entryDate), 7);
        if (dayOfWeek == 0 || dayOfWeek == 6) return true;

        // 2. Holiday Check
        Integer holidayCount = [
            SELECT COUNT() FROM Holiday__c 
            WHERE Is_Active__c = true AND Holiday_Date__c = :entryDate 
            LIMIT 1
        ];
        return holidayCount > 0;
    }

    private static String generateToken(Object part1, Object part2) {
        String combined = String.valueOf(part1) + String.valueOf(part2) + String.valueOf(DateTime.now().getTime()) + UserInfo.getOrganizationId();
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(combined));
        return EncodingUtil.convertToHex(hash).substring(0, 32);
    }

    private static String mapEmploymentStatusToBillingStatus(String status) {
        if (String.isBlank(status)) return null;
        if (status == 'Non Billable') return 'Non-Billable';
        return status;
    }
}