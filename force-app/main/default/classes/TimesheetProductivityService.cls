public with sharing class TimesheetProductivityService {
    
    public class ProductivityMetrics {
        @AuraEnabled public Decimal productivityPct;
        @AuraEnabled public Decimal totalHours;
        @AuraEnabled public Decimal approvedHours;
        @AuraEnabled public Decimal targetHours;
        @AuraEnabled public Decimal leaveHours;
        
        public ProductivityMetrics() {
            this.productivityPct = 0;
            this.totalHours = 0;
            this.approvedHours = 0;
            this.targetHours = 0;
            this.leaveHours = 0;
        }
    }

    /**
     * Calculates productivity metrics for a set of users over a specific date range.
     */
    public static Map<Id, ProductivityMetrics> calculateBulkProductivity(Set<Id> userIds, Date startDate, Date endDate) {
        Map<Id, ProductivityMetrics> result = new Map<Id, ProductivityMetrics>();
        for (Id userId : userIds) {
            result.put(userId, new ProductivityMetrics());
        }

        // 1. Fetch all relevant timesheet entries
        List<TimesheetEntry__c> entries = [
            SELECT Total_Hours__c, Approval_Status__c, Timesheet__r.Employee__c, Date__c
            FROM TimesheetEntry__c
            WHERE Timesheet__r.Employee__c IN :userIds
            AND Date__c >= :startDate
            AND Date__c <= :endDate
        ];

        for (TimesheetEntry__c te : entries) {
            ProductivityMetrics m = result.get(te.Timesheet__r.Employee__c);
            Decimal hrs = te.Total_Hours__c != null ? te.Total_Hours__c : 0;
            m.totalHours += hrs;
            if (te.Approval_Status__c == 'Approved') {
                m.approvedHours += hrs;
            }
        }

        // 2. Fetch Holidays
        List<Holiday__c> holidays = [
            SELECT Holiday_Date__c 
            FROM Holiday__c 
            WHERE Holiday_Date__c >= :startDate AND Holiday_Date__c <= :endDate
        ];
        Set<Date> holidayDates = new Set<Date>();
        for (Holiday__c h : holidays) holidayDates.add(h.Holiday_Date__c);

        // 3. Fetch Leaves
        List<Leave_Request__c> leaves = [
            SELECT Start_Date__c, End_Date__c, Is_Half_Day__c, Employee__c
            FROM Leave_Request__c 
            WHERE Employee__c IN :userIds 
            AND Status__c IN ('Approved', 'Pending')
            AND ((Start_Date__c >= :startDate AND Start_Date__c <= :endDate)
                 OR (End_Date__c >= :startDate AND End_Date__c <= :endDate))
        ];

        // Map employee to their specific leave dates
        Map<Id, Map<Date, Decimal>> employeeLeaveMap = new Map<Id, Map<Date, Decimal>>();
        for (Leave_Request__c lr : leaves) {
            if (!employeeLeaveMap.containsKey(lr.Employee__c)) {
                employeeLeaveMap.put(lr.Employee__c, new Map<Date, Decimal>());
            }
            Date s = lr.Start_Date__c < startDate ? startDate : lr.Start_Date__c;
            Date e = lr.End_Date__c > endDate ? endDate : lr.End_Date__c;
            for (Date d = s; d <= e; d = d.addDays(1)) {
                employeeLeaveMap.get(lr.Employee__c).put(d, lr.Is_Half_Day__c ? 0.5 : 1.0);
            }
        }

        // 4. Calculate Target Hours and Productivity for each user
        for (Id userId : userIds) {
            ProductivityMetrics m = result.get(userId);
            Integer workdays = 0;
            Decimal leaveDays = 0;
            Map<Date, Decimal> userLeaves = employeeLeaveMap.get(userId);

            Date baseDate = Date.newInstance(1900, 1, 7); // Sunday
            for (Date d = startDate; d <= endDate; d = d.addDays(1)) {
                Integer dayNum = Math.mod(baseDate.daysBetween(d), 7); // 0=Sun, 1=Mon, ..., 6=Sat
                if (dayNum >= 1 && dayNum <= 5) {
                    if (!holidayDates.contains(d)) {
                        workdays++;
                        if (userLeaves != null && userLeaves.containsKey(d)) {
                            leaveDays += userLeaves.get(d);
                        }
                    }
                }
            }

            m.leaveHours = leaveDays * 8.0;
            m.targetHours = (workdays - leaveDays) * 8.0;
            if (m.targetHours > 0) {
                m.productivityPct = (m.approvedHours / m.targetHours * 100).setScale(1);
            } else {
                m.productivityPct = (m.approvedHours > 0) ? 100 : 0;
            }
        }

        return result;
    }
}