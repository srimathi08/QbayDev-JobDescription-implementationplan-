public without sharing class AttendanceSummaryController {

    // =========================================================================
    // PUBLIC ENTRY POINT
    // =========================================================================

    @AuraEnabled
    public static Map<String, Object> getMonthlySummary(String userId) {
        Map<String, Object> summary = new Map<String, Object>();

        try {
            Date today      = Date.today();
            Date monthStart = today.toStartOfMonth();

            Integer totalWeekdays = calculateWeekdaysBetween(monthStart, today);

            List<Employee_Attendance__c> monthlyRecords = [
                SELECT Id, Date__c, Check_In_Time__c, Check_Out_Time__c,
                       Hours_Worked__c, Status__c, Employee_Name__c,
                       Session_Number__c, Is_Multiple_Session__c,
                       Is_OD_Request__c, OD_Approval_Status__c,
                       Work_Location__c, WFH_Approval_Status__c
                FROM Employee_Attendance__c
                WHERE Employee_Name__c = :userId
                AND   Date__c >= :monthStart
                AND   Date__c <= :today
                ORDER BY Date__c ASC, Session_Number__c ASC
            ];

            List<Work_from_home_Request__c> wfhRequests = [
                SELECT Start_Date__c, End_Date__c, Status__c
                FROM Work_from_home_Request__c
                WHERE Employee__c = :userId
                AND ((Start_Date__c >= :monthStart AND Start_Date__c <= :today)
                  OR (End_Date__c   >= :monthStart AND End_Date__c   <= :today))
            ];

            List<Leave_Request__c> approvedLeaves = [
                SELECT Start_Date__c, End_Date__c
                FROM Leave_Request__c
                WHERE Employee__c  = :userId
                AND   Status__c    = 'Approved'
                AND   Is_Active__c = true
                AND ((Start_Date__c >= :monthStart AND Start_Date__c <= :today)
                  OR (End_Date__c   >= :monthStart AND End_Date__c   <= :today))
            ];

            // ⚠️ Using Holiday__c — change Holiday_Date__c if your field name differs
            List<Holiday__c> holidays = [
                SELECT Holiday_Date__c
                FROM   Holiday__c
                WHERE  Holiday_Date__c >= :monthStart
                AND    Holiday_Date__c <= :today
            ];

            Map<String, Integer> calc = calculateMonthlyMetricsFiltered(
                monthlyRecords, wfhRequests, approvedLeaves, holidays,
                totalWeekdays, monthStart, today
            );

            Decimal totalHours     = calculateTotalHoursAllSessions(monthlyRecords);
            Decimal avgHoursPerDay = calculateAverageHoursPerDay(monthlyRecords);
            Decimal attendanceRate = calculateAttendanceRate(calc.get('presentDays'), totalWeekdays);

            summary.put('success',           true);
            summary.put('presentDays',       calc.get('presentDays'));
            summary.put('lateDays',          calc.get('lateDays'));
            summary.put('absentDays',        calc.get('absentDays'));
            summary.put('approvedLeaveDays', calc.get('approvedLeaveDays'));
            summary.put('lopDays',           calc.get('lopDays'));
            summary.put('totalHours',        totalHours.setScale(1).toPlainString());
            summary.put('avgHoursPerDay',    avgHoursPerDay.setScale(1).toPlainString());
            summary.put('attendanceRate',    attendanceRate.setScale(1).toPlainString());
            summary.put('totalWorkingDays',  totalWeekdays);
            summary.put('monthName',         getMonthName(monthStart));
            summary.put('recordsFound',      monthlyRecords.size());
            summary.put('totalSessions',     monthlyRecords.size());

        } catch (Exception e) {
            System.debug('getMonthlySummary error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            summary.put('success',           false);
            summary.put('error',             e.getMessage());
            summary.put('presentDays',       0);
            summary.put('lateDays',          0);
            summary.put('absentDays',        0);
            summary.put('approvedLeaveDays', 0);
            summary.put('lopDays',           0);
            summary.put('totalHours',        '0.0');
            summary.put('avgHoursPerDay',    '0.0');
            summary.put('attendanceRate',    '0');
            summary.put('totalWorkingDays',  0);
            summary.put('monthName',         getMonthName(Date.today()));
            summary.put('recordsFound',      0);
            summary.put('totalSessions',     0);
        }

        return summary;
    }

    // =========================================================================
    // CORE METRICS  —  LOP RULES
    // =========================================================================
    /*
     * PRESENT (never LOP):
     *   • Work from Office / Client Place / Field Work / Business Travel
     *     → always Present; no approval column checked.
     *   • Work from Home  + WFH Approved  → Present.
     *   • Work from Home  + WFH Pending   → Present (innocent until rejected).
     *   • OD request      + OD  Approved  → Present.
     *   • OD request      + OD  Pending   → Present.
     *
     * LOP (Loss of Pay):
     *   1. Weekday with NO record + NO approved leave + NOT a holiday.
     *   2. Work from Home  + WFH Rejected → LOP.
     *   3. OD request      + OD  Rejected → LOP.
     *
     * APPROVED LEAVE:
     *   Weekday covered by approved Leave_Request__c where employee did NOT
     *   check in (half-day check-in counts as Present for that half).
     *
     * HOLIDAYS (Holiday__c):
     *   Weekday holidays excluded from absent/LOP entirely.
     */
    private static Map<String, Integer> calculateMonthlyMetricsFiltered(
        List<Employee_Attendance__c>    records,
        List<Work_from_home_Request__c> wfhRequests,
        List<Leave_Request__c>          leaveRequests,
        List<Holiday__c>                holidays,
        Integer                         totalWeekdays,
        Date                            monthStart,
        Date                            today
    ) {
        // ── Step 1: date → WFH status  ('Approved' wins on overlap) ──────────
        Map<Date, String> wfhStatusByDate = new Map<Date, String>();
        for (Work_from_home_Request__c wfh : wfhRequests) {
            Date s = wfh.Start_Date__c < monthStart ? monthStart : wfh.Start_Date__c;
            Date e = wfh.End_Date__c   > today      ? today      : wfh.End_Date__c;
            for (Date d = s; d <= e; d = d.addDays(1)) {
                if (!wfhStatusByDate.containsKey(d) || wfh.Status__c == 'Approved') {
                    wfhStatusByDate.put(d, wfh.Status__c);
                }
            }
        }

        // ── Step 2: holiday date set ──────────────────────────────────────────
        Set<Date> holidayDates = new Set<Date>();
        for (Holiday__c h : holidays) {
            if (h.Holiday_Date__c != null) holidayDates.add(h.Holiday_Date__c);
        }

        // ── Step 3: classify each attendance record ───────────────────────────
        Set<Date> presentDates = new Set<Date>();
        Set<Date> lateDates    = new Set<Date>();
        Set<Date> lopDates     = new Set<Date>(); // rejected WFH / rejected OD

        for (Employee_Attendance__c rec : records) {
            if (rec.Check_In_Time__c == null || rec.Date__c == null) continue;

            String loc = rec.Work_Location__c;

            // CASE A — Physical locations → always Present
            if (loc == 'Work from Office' ||
                loc == 'Client Place'     ||
                loc == 'Field Work'       ||
                loc == 'Business Travel') {

                presentDates.add(rec.Date__c);
                lopDates.remove(rec.Date__c);   // cancel any earlier LOP flag
                if (rec.Status__c == 'Late') lateDates.add(rec.Date__c);
                continue;
            }

            // CASE B — Work from Home
            if (loc == 'Work from Home') {
                String wfhStatus = wfhStatusByDate.get(rec.Date__c);
                if (wfhStatus == 'Rejected') {
                    if (!presentDates.contains(rec.Date__c)) lopDates.add(rec.Date__c);
                } else {
                    // Approved OR Pending → Present
                    presentDates.add(rec.Date__c);
                    lopDates.remove(rec.Date__c);
                    if (rec.Status__c == 'Late') lateDates.add(rec.Date__c);
                }
                continue;
            }

            // CASE C — OD Request
            if (rec.Is_OD_Request__c == true) {
                String odStatus = rec.OD_Approval_Status__c;
                if (odStatus == 'Rejected') {
                    if (!presentDates.contains(rec.Date__c)) lopDates.add(rec.Date__c);
                } else {
                    // Approved OR Pending → Present
                    presentDates.add(rec.Date__c);
                    lopDates.remove(rec.Date__c);
                    if (rec.Status__c == 'Late') lateDates.add(rec.Date__c);
                }
                continue;
            }

            // CASE D — Unknown location → Present
            presentDates.add(rec.Date__c);
            if (rec.Status__c == 'Late') lateDates.add(rec.Date__c);
        }

        // ── Step 4: approved-leave dates ─────────────────────────────────────
        Set<Date> leaveDates = new Set<Date>();
        for (Leave_Request__c lr : leaveRequests) {
            Date s = lr.Start_Date__c < monthStart ? monthStart : lr.Start_Date__c;
            Date e = lr.End_Date__c   > today      ? today      : lr.End_Date__c;
            for (Date d = s; d <= e; d = d.addDays(1)) {
                if (presentDates.contains(d)) continue; // half-day: employee checked in
                if (holidayDates.contains(d)) continue; // holiday trumps leave
                Datetime dt     = Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0));
                Integer  dayNum = Integer.valueOf(dt.format('u')); // 1=Mon…7=Sun
                if (dayNum >= 1 && dayNum <= 5) leaveDates.add(d);
            }
        }

        // ── Step 5: count holiday weekdays ───────────────────────────────────
        Integer holidayWeekdays = 0;
        for (Date d = monthStart; d <= today; d = d.addDays(1)) {
            Datetime dt     = Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0));
            Integer  dayNum = Integer.valueOf(dt.format('u'));
            if (dayNum >= 1 && dayNum <= 5 && holidayDates.contains(d)) {
                holidayWeekdays++;
            }
        }

        // ── Step 6: final arithmetic ──────────────────────────────────────────
        Integer presentDays       = presentDates.size();
        Integer lateDays          = lateDates.size();
        Integer approvedLeaveDays = leaveDates.size();
        Integer effectiveWeekdays = totalWeekdays - holidayWeekdays;

        Integer absentDays = effectiveWeekdays - presentDays;
        if (absentDays < 0) absentDays = 0;

        Integer lopDays = absentDays - approvedLeaveDays;
        if (lopDays < 0) lopDays = 0;

        System.debug('=== Monthly Metrics ===');
        System.debug('Total weekdays     : ' + totalWeekdays);
        System.debug('Holiday weekdays   : ' + holidayWeekdays);
        System.debug('Effective weekdays : ' + effectiveWeekdays);
        System.debug('Present dates      : ' + presentDates);
        System.debug('Late dates         : ' + lateDates);
        System.debug('Leave dates        : ' + leaveDates);
        System.debug('Rejected LOP dates : ' + lopDates);
        System.debug('presentDays        : ' + presentDays);
        System.debug('lateDays           : ' + lateDays);
        System.debug('absentDays         : ' + absentDays);
        System.debug('approvedLeaveDays  : ' + approvedLeaveDays);
        System.debug('lopDays            : ' + lopDays);

        return new Map<String, Integer>{
            'presentDays'       => presentDays,
            'lateDays'          => lateDays,
            'absentDays'        => absentDays,
            'approvedLeaveDays' => approvedLeaveDays,
            'lopDays'           => lopDays
        };
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    private static Integer calculateWeekdaysBetween(Date startDate, Date endDate) {
        Integer weekdays = 0;
        Date    current  = startDate;
        while (current <= endDate) {
            Datetime dt     = Datetime.newInstance(current, Time.newInstance(0, 0, 0, 0));
            Integer  dayNum = Integer.valueOf(dt.format('u'));
            if (dayNum >= 1 && dayNum <= 5) weekdays++;
            current = current.addDays(1);
        }
        return weekdays;
    }

    private static Decimal calculateTotalHoursAllSessions(List<Employee_Attendance__c> records) {
        Decimal total = 0;
        for (Employee_Attendance__c rec : records) {
            if (rec.Hours_Worked__c != null && rec.Hours_Worked__c > 0) total += rec.Hours_Worked__c;
        }
        return total;
    }

    private static Decimal calculateAverageHoursPerDay(List<Employee_Attendance__c> records) {
        Map<Date, Decimal> hoursPerDay = new Map<Date, Decimal>();
        for (Employee_Attendance__c rec : records) {
            if (rec.Date__c != null && rec.Hours_Worked__c != null && rec.Hours_Worked__c > 0) {
                Decimal cur = hoursPerDay.containsKey(rec.Date__c) ? hoursPerDay.get(rec.Date__c) : 0;
                hoursPerDay.put(rec.Date__c, cur + rec.Hours_Worked__c);
            }
        }
        if (hoursPerDay.isEmpty()) return 0;
        Decimal total = 0;
        for (Decimal d : hoursPerDay.values()) total += d;
        return total / hoursPerDay.size();
    }

    private static Decimal calculateAttendanceRate(Integer presentDays, Integer totalWeekdays) {
        if (totalWeekdays == 0) return 0;
        return (Decimal.valueOf(presentDays) / Decimal.valueOf(totalWeekdays)) * 100;
    }

    private static String getMonthName(Date inputDate) {
        String[] months = new String[]{
            'January','February','March','April','May','June',
            'July','August','September','October','November','December'
        };
        return months[inputDate.month() - 1] + ' ' + inputDate.year();
    }

    // =========================================================================
    // ADMIN / BULK METHODS
    // =========================================================================

    @AuraEnabled
    public static List<Map<String, Object>> getAllUsersMonthlySummary() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        try {
            Date today      = Date.today();
            Date monthStart = today.toStartOfMonth();
            Set<String> usersWithAttendance = new Set<String>();
            for (Employee_Attendance__c rec : [
                SELECT Employee_Name__c FROM Employee_Attendance__c
                WHERE Date__c >= :monthStart AND Date__c <= :today
            ]) {
                usersWithAttendance.add(rec.Employee_Name__c);
            }
            for (User u : [
                SELECT Id, Name, Email, Profile.Name
                FROM User
                WHERE Id IN :usersWithAttendance AND IsActive = true LIMIT 100
            ]) {
                Map<String, Object> s = getMonthlySummary(u.Id);
                s.put('userName',  u.Name);
                s.put('userEmail', u.Email);
                s.put('userId',    u.Id);
                result.add(s);
            }
        } catch (Exception e) {
            System.debug('getAllUsersMonthlySummary error: ' + e.getMessage());
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean shouldShowCheckInPopup() {
        if (System.now().time() >= Time.newInstance(12, 0, 0, 0)) return false;
        Integer checkInCount = [
            SELECT COUNT() FROM Employee_Attendance__c
            WHERE Employee_Name__c = :UserInfo.getUserId()
            AND   Date__c          = :Date.today()
            AND   Check_In_Time__c != NULL
        ];
        return checkInCount == 0;
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Integer> getMyRequestCountsForCurrentWeek() {
        Id   userId     = UserInfo.getUserId();
        Date today      = Date.today();
        Date monthStart = today.toStartOfMonth();
        Date monthEnd   = monthStart.addMonths(1).addDays(-1);

        Map<String, Integer> counts = new Map<String, Integer>();

        counts.put('pendingLeave', [
            SELECT COUNT() FROM Leave_Request__c
            WHERE Employee__c = :userId AND Status__c = 'Pending' AND Is_Active__c = true
            AND ((Start_Date__c >= :monthStart AND Start_Date__c <= :monthEnd)
              OR (End_Date__c   >= :monthStart AND End_Date__c   <= :monthEnd))
        ]);
        counts.put('approvedLeave', [
            SELECT COUNT() FROM Leave_Request__c
            WHERE Employee__c = :userId AND Status__c = 'Approved' AND Is_Active__c = true
            AND ((Start_Date__c >= :monthStart AND Start_Date__c <= :monthEnd)
              OR (End_Date__c   >= :monthStart AND End_Date__c   <= :monthEnd))
        ]);
        counts.put('pendingWFH', [
            SELECT COUNT() FROM Work_from_home_Request__c
            WHERE Employee__c = :userId AND Status__c = 'Pending' AND Is_Active__c = true
            AND ((Start_Date__c >= :monthStart AND Start_Date__c <= :monthEnd)
              OR (End_Date__c   >= :monthStart AND End_Date__c   <= :monthEnd))
        ]);
        counts.put('submittedTimesheet', [
            SELECT COUNT() FROM TimesheetEntry__c
            WHERE Timesheet__r.Employee__c = :userId
            AND (Approval_Status__c = 'Submitted' OR Status__c = 'Submitted')
            AND Date__c >= :monthStart AND Date__c <= :monthEnd
        ]);
        counts.put('pendingOD', [
            SELECT COUNT() FROM Employee_Attendance__c
            WHERE Employee_Name__c    = :userId
            AND   Is_OD_Request__c    = true
            AND   OD_Approval_Status__c = 'Pending'
            AND   Date__c >= :monthStart AND Date__c <= :monthEnd
        ]);

        return counts;
    }
}