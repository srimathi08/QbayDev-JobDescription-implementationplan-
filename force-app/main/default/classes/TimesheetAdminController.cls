/*public with sharing class TimesheetAdminController {
    
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardStats(String startDate, String endDate) {
        try {
System.debug('getDashboardStats called with startDate: ' + startDate + ', endDate: ' + endDate);
            Date sDate = Date.valueOf(startDate);
            Date eDate = Date.valueOf(endDate);
            
            List<TimesheetEntry__c> entries = [
                SELECT Id, Total_Hours__c, Approval_Status__c, Timesheet__r.Employee__c,Project__c
                FROM TimesheetEntry__c 
                WHERE Date__c >= :sDate AND Date__c <= :eDate
                AND (NOT Timesheet__r.Employee__r.Name LIKE '%Integration%')
                AND (NOT Timesheet__r.Employee__r.Name LIKE '%Einstein%')
                AND (NOT Timesheet__r.Employee__r.Name LIKE '%Data%')
            ];
            System.debug('Found ' + entries.size() + ' timesheet entries');
            Decimal totalHours = 0;
            Decimal approvedHours = 0;
            Integer pendingCount = 0;
            Integer rejectedCount = 0;
            Set<Id> employeeIds = new Set<Id>();
            Set<Id> projectIds = new Set<Id>();
            
            for(TimesheetEntry__c entry : entries) {
                totalHours += entry.Total_Hours__c != null ? entry.Total_Hours__c : 0;
                
                if(entry.Approval_Status__c == 'Approved') {
                    approvedHours += entry.Total_Hours__c != null ? entry.Total_Hours__c : 0;
                } else if(entry.Approval_Status__c == 'Pending') {
                    pendingCount++;
                } else if(entry.Approval_Status__c == 'Rejected') {
                    rejectedCount++;
                }
                
                if(entry.Timesheet__r.Employee__c != null) {
                    employeeIds.add(entry.Timesheet__r.Employee__c);
                }
                if(entry.Project__c != null) {
                    projectIds.add(entry.Project__c);
                }
            }
            
            Map<String, Object> stats = new Map<String, Object>();
            stats.put('totalHours', totalHours);
            stats.put('pendingApprovals', pendingCount);
            stats.put('approvedHours', approvedHours);
            stats.put('rejectedEntries', rejectedCount);
            stats.put('totalEmployees', employeeIds.size());
            stats.put('activeProjects', projectIds.size());
            System.debug('Stats: ' + stats);
            return stats;
        } catch (Exception e) {
System.debug('Error in getDashboardStats: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error fetching dashboard stats: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<TimesheetEntryWrapper> getTimesheetEntries(
        String startDate, 
        String endDate, 
        String employeeFilter,
        String departmentFilter,
        String projectFilter,
        String statusFilter
    ) {
        try {
            Date sDate = Date.valueOf(startDate);
            Date eDate = Date.valueOf(endDate);
            
            String query = 'SELECT Id, Timesheet__r.Employee__r.Name, ' +
                          'Timesheet__r.Employee__r.Department, ' +
                          'Project__r.Name, Date__c, Total_Hours__c, Tasks__c, Approval_Status__c ' +
                          'FROM TimesheetEntry__c ' +
                          'WHERE Date__c >= :sDate AND Date__c <= :eDate ' +
                          'AND (NOT Timesheet__r.Employee__r.Name LIKE \'%Integration%\') ' +
                          'AND (NOT Timesheet__r.Employee__r.Name LIKE \'%Einstein%\') ' +
                          'AND (NOT Timesheet__r.Employee__r.Name LIKE \'%Data%\')';
            
            if(employeeFilter != 'All Employees') {
                query += ' AND Timesheet__r.Employee__r.Name = :employeeFilter';
            }
            
            if(departmentFilter != 'All Departments') {
                query += ' AND Timesheet__r.Employee__r.Department = :departmentFilter';
            }
            
            if(projectFilter != 'All Projects') {
                query += ' AND Project__r.Name = :projectFilter';
            }
            
            if(statusFilter != 'All Status') {
                query += ' AND Approval_Status__c = :statusFilter';
            }
            
            query += ' ORDER BY Date__c DESC, Timesheet__r.Employee__r.Name';
            System.debug('Final Query: ' + query);
            List<TimesheetEntry__c> entries = Database.query(query);
System.debug('Query returned ' + entries.size() + ' records');
            List<TimesheetEntryWrapper> wrappers = new List<TimesheetEntryWrapper>();
            
            for(TimesheetEntry__c entry : entries) {
                TimesheetEntryWrapper wrapper = new TimesheetEntryWrapper();
                wrapper.id = entry.Id;
                wrapper.employeeName = entry.Timesheet__r.Employee__r.Name;
                wrapper.department = entry.Timesheet__r.Employee__r.Department;
                wrapper.projectName = entry.Project__r.Name;
                wrapper.entryDate = entry.Date__c;
                wrapper.hours = entry.Total_Hours__c;
                wrapper.description = entry.Tasks__c;
                wrapper.status = entry.Approval_Status__c;
                wrappers.add(wrapper);
            }
            System.debug('Returning ' + wrappers.size() + ' wrappers');
            return wrappers;
        } catch (Exception e) {
 System.debug('ERROR in getTimesheetEntries: ' + e.getMessage());
            throw new AuraHandledException('Error fetching timesheet entries: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static String approveTimesheetEntry(String entryId) {
        try {
            TimesheetEntry__c entry = [SELECT Id, Approval_Status__c FROM TimesheetEntry__c WHERE Id = :entryId];
            entry.Approval_Status__c = 'Approved';
            entry.Approved_By__c = UserInfo.getUserId();
            entry.Approved_Date__c = System.now();
            update entry;
            return 'Success';
        } catch (Exception e) {
            throw new AuraHandledException('Error approving entry: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static String rejectTimesheetEntry(String entryId, String reason) {
        try {
            TimesheetEntry__c entry = [SELECT Id, Approval_Status__c FROM TimesheetEntry__c WHERE Id = :entryId];
            entry.Approval_Status__c = 'Rejected';
            /*entry.Rejection_Reason__c = reason;
            entry.Rejected_By__c = UserInfo.getUserId();
            entry.Rejection_Date__c = System.now();
            update entry;
            return 'Success';
        } catch (Exception e) {
            throw new AuraHandledException('Error rejecting entry: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<String> getFilterOptions(String filterType) {
        List<String> options = new List<String>();
        
        try {
            System.debug('getFilterOptions called for: ' + filterType);
            
            if(filterType == 'employees') {
                options.add('All Employees');
                
                // Get users who have timesheet entries
                Set<Id> employeeIds = new Set<Id>();
                for(Timesheet__c ts : [SELECT Employee__c FROM Timesheet__c WHERE Employee__c != null]) {
                    employeeIds.add(ts.Employee__c);
                }
                
                if(!employeeIds.isEmpty()) {
                    for(User u : [SELECT Name FROM User WHERE Id IN :employeeIds ORDER BY Name]) {
                        options.add(u.Name);
                    }
                }
            } else if(filterType == 'departments') {
                options.add('All Departments');
                
                // Get distinct departments from users with timesheets
                Set<String> departments = new Set<String>();
                for(User u : [
                    SELECT Department 
                    FROM User 
                    WHERE Id IN (SELECT Employee__c FROM Timesheet__c WHERE Employee__c != null)
                    AND Department != null
                ]) {
                    if(String.isNotBlank(u.Department)) {
                        departments.add(u.Department);
                    }
                }
                
                List<String> deptList = new List<String>(departments);
                deptList.sort();
                options.addAll(deptList);
                
            } else if(filterType == 'projects') {
                options.add('All Projects');
                for(Project__c p : [SELECT Name FROM Project__c WHERE Status__c = 'Active' ORDER BY Name]) {
                    options.add(p.Name);
                }
            } else if(filterType == 'status') {
                options.addAll(new List<String>{'All Status', 'Pending', 'Approved', 'Rejected'});
            }
System.debug('Filter options for ' + filterType + ': ' + options);
        } catch (Exception e) {
System.debug('Error in getFilterOptions: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            // Return at least the default option
            if(options.isEmpty()) {
                options.add('All ' + filterType);
            }
            //throw new AuraHandledException('Error getting filter options: ' + e.getMessage());
        }
        
        return options;
    }
    
    public class TimesheetEntryWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String employeeName;
        @AuraEnabled public String department;
        @AuraEnabled public String projectName;
        @AuraEnabled public Date entryDate;
        @AuraEnabled public Decimal hours;
        @AuraEnabled public String status;
    }
}*/
/*Used one */
public with sharing class TimesheetAdminController {
    
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardStats(String startDate, String endDate) {
        try {
            System.debug('getDashboardStats called with startDate: ' + startDate + ', endDate: ' + endDate);
            Date sDate = Date.valueOf(startDate);
            Date eDate = Date.valueOf(endDate);
            
            List<TimesheetEntry__c> entries = [
                SELECT Id, Total_Hours__c, Approval_Status__c, Timesheet__r.Employee__c, Project__c
                FROM TimesheetEntry__c 
                WHERE Date__c >= :sDate AND Date__c <= :eDate
                AND (NOT Timesheet__r.Employee__r.Name LIKE '%Integration%')
                AND (NOT Timesheet__r.Employee__r.Name LIKE '%Einstein%')
                AND (NOT Timesheet__r.Employee__r.Name LIKE '%Data%')
            ];
            System.debug('Found ' + entries.size() + ' timesheet entries');
            
            Decimal totalHours = 0;
            Decimal approvedHours = 0;
            Decimal pendingHours = 0;
            Decimal rejectedHours = 0;
            Integer pendingCount = 0;
            Integer rejectedCount = 0;
            Set<Id> employeeIds = new Set<Id>();
            
            for(TimesheetEntry__c entry : entries) {
                Decimal hrs = entry.Total_Hours__c != null ? entry.Total_Hours__c : 0;
                totalHours += hrs;
                
                if(entry.Approval_Status__c == 'Approved') {
                    approvedHours += hrs;
                } else if(entry.Approval_Status__c == 'Pending' || entry.Approval_Status__c == 'Submitted') {
                    pendingCount++;
                    pendingHours += hrs;
                } else if(entry.Approval_Status__c == 'Rejected') {
                    rejectedCount++;
                    rejectedHours += hrs;
                }
                
                if(entry.Timesheet__r.Employee__c != null) {
                    employeeIds.add(entry.Timesheet__r.Employee__c);
                }
            }
            
            // 1) Get all relevant users for calculations
            String userQuery = 'SELECT Id FROM User WHERE IsActive = true AND Employee_IDs__c != null ' +
                           'AND (NOT Name LIKE \'%Integration%\') ' +
                           'AND (NOT Name LIKE \'%Einstein%\') ' +
                           'AND Name NOT IN (\'IT Admin\', \'Automated Process\', \'Data.com Clean\')';
            List<User> relevantUsers = Database.query(userQuery);
            Set<Id> allUserIds = new Set<Id>();
            for(User u : relevantUsers) allUserIds.add(u.Id);

            // 2) Use service to get accurate productivity metrics across all users
            Map<Id, TimesheetProductivityService.ProductivityMetrics> allProdMap = 
                TimesheetProductivityService.calculateBulkProductivity(allUserIds, sDate, eDate);

            Decimal targetHours = 0;
            Decimal totalLeaveHours = 0;
            Decimal totalProd = 0;
            Integer usersWithTarget = 0;

            for(TimesheetProductivityService.ProductivityMetrics m : allProdMap.values()) {
                targetHours += m.targetHours;
                totalLeaveHours += m.leaveHours;
                if(m.targetHours > 0 || m.approvedHours > 0) {
                    totalProd += m.productivityPct;
                    usersWithTarget++;
                }
            }

            Decimal avgProd = usersWithTarget == 0 ? 0 : (totalProd / usersWithTarget).setScale(1);

            Map<String, Object> stats = new Map<String, Object>();
            stats.put('totalHours', totalHours);
            stats.put('pendingApprovals', pendingCount);
            stats.put('pendingHours', pendingHours);
            stats.put('approvedHours', approvedHours);
            stats.put('rejectedEntries', rejectedCount);
            stats.put('rejectedHours', rejectedHours);
            stats.put('totalEmployees', relevantUsers.size());
            stats.put('targetHours', targetHours);
            stats.put('totalLeaveHours', totalLeaveHours);
            stats.put('totalLeaveDays', (totalLeaveHours / 8.0).setScale(1));
            stats.put('avgProductivity', avgProd);
            
            return stats;
        } catch (Exception e) {
            System.debug('Error in getDashboardStats: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error fetching dashboard stats: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<TimesheetEntryWrapper> getTimesheetEntries(
        String startDate, 
        String endDate, 
        String employeeFilter,
        String departmentFilter,
        String projectFilter,
        String statusFilter
    ) {
        try {
            Date sDate = Date.valueOf(startDate);
            Date eDate = Date.valueOf(endDate);
            
            // Build dynamic query with proper filter handling
            // Build dynamic query with proper filter handling
            String query = 'SELECT Id, Timesheet__r.Employee__r.Name, ' +
                          'Timesheet__r.Employee__r.Department, ' +
                          'Project__r.Name, Date__c, Total_Hours__c, Tasks__c, Approval_Status__c, Billing_Status__c ' +
                          'FROM TimesheetEntry__c ' +
                          'WHERE Date__c >= :sDate AND Date__c <= :eDate ' +
                          'AND (NOT Timesheet__r.Employee__r.Name LIKE \'%Integration%\') ' +
                          'AND (NOT Timesheet__r.Employee__r.Name LIKE \'%Einstein%\') ' +
                          'AND (NOT Timesheet__r.Employee__r.Name LIKE \'%Data%\')';
            
            // FIXED: Handle empty/null filter values properly
            if(String.isNotBlank(employeeFilter) && employeeFilter != '' && employeeFilter != 'All Employees') {
                query += ' AND Timesheet__r.Employee__r.Name = :employeeFilter';
            }
           
            if(String.isNotBlank(departmentFilter) && departmentFilter != '' && departmentFilter != 'All Departments') {
                query += ' AND Timesheet__r.Employee__r.Department = :departmentFilter';
            }
            
            if(String.isNotBlank(projectFilter) && projectFilter != '' && projectFilter != 'All Projects') {
                query += ' AND Project__r.Name = :projectFilter';
            }
          
            if(String.isNotBlank(statusFilter) && statusFilter != '' && statusFilter != 'All Status') {
                query += ' AND Approval_Status__c = :statusFilter';
            }
            
            query += ' ORDER BY Date__c DESC, Timesheet__r.Employee__r.Name';
            System.debug('Final Query: ' + query);
            System.debug('Filter params - Employee: ' + employeeFilter + ', Department: ' + departmentFilter + 
                        ', Project: ' + projectFilter + ', Status: ' + statusFilter);
            
            List<TimesheetEntry__c> entries = Database.query(query);
            System.debug('Query returned ' + entries.size() + ' records');
            
            List<TimesheetEntryWrapper> wrappers = new List<TimesheetEntryWrapper>();
            
            for(TimesheetEntry__c entry : entries) {
                TimesheetEntryWrapper wrapper = new TimesheetEntryWrapper();
                wrapper.id = entry.Id;
                wrapper.employeeName = entry.Timesheet__r.Employee__r.Name != null ? 
                                      entry.Timesheet__r.Employee__r.Name : 'N/A';
                wrapper.department = entry.Timesheet__r.Employee__r.Department != null ? 
                                    entry.Timesheet__r.Employee__r.Department : 'N/A';
                wrapper.projectName = entry.Project__r.Name != null ? 
                                     entry.Project__r.Name : 'N/A';
                wrapper.entryDate = entry.Date__c;
                wrapper.hours = entry.Total_Hours__c != null ? entry.Total_Hours__c : 0;
                wrapper.status = entry.Approval_Status__c != null ? entry.Approval_Status__c : 'Pending';
                wrapper.billingStatus = entry.Billing_Status__c != null ? entry.Billing_Status__c : 'Billable';
                wrapper.task = entry.Tasks__c != null ? entry.Tasks__c : '';
                wrapper.description = entry.Tasks__c != null ? entry.Tasks__c : '';
                wrappers.add(wrapper);
            }
            System.debug('Returning ' + wrappers.size() + ' wrappers');
            return wrappers;
        } catch (Exception e) {
            System.debug('ERROR in getTimesheetEntries: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error fetching timesheet entries: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<EmployeeProductivityWrapper> getEmployeeProductivityStats(
        String startDate, 
        String endDate,
        String departmentFilter,
        String projectFilter
    ) {
        try {
            Date sDate = Date.valueOf(startDate);
            Date eDate = Date.valueOf(endDate);

            // Fetch active employees or those with entries in range
            String query = 'SELECT Id, FirstName, LastName, Name, Department FROM User WHERE IsActive = true AND Employee_IDs__c != null ' +
                           'AND (NOT Name LIKE \'%Integration%\') ' +
                           'AND (NOT Name LIKE \'%Einstein%\') ' +
                           'AND Name NOT IN (\'IT Admin\', \'Automated Process\', \'Data.com Clean\')';
            if (String.isNotBlank(departmentFilter) && departmentFilter != 'All Departments') {
                query += ' AND Department = :departmentFilter';
            }
            
            List<User> employees = Database.query(query);
            Set<Id> employeeIds = new Map<Id, User>(employees).keySet();

            Map<Id, TimesheetProductivityService.ProductivityMetrics> prodMap = 
                TimesheetProductivityService.calculateBulkProductivity(employeeIds, sDate, eDate);

            List<EmployeeProductivityWrapper> wrappers = new List<EmployeeProductivityWrapper>();
            for (User u : employees) {
                TimesheetProductivityService.ProductivityMetrics m = prodMap.get(u.Id);
                if (m == null) continue;

                String fName = u.FirstName != null ? u.FirstName : '';
                String lName = u.LastName != null ? u.LastName : '';
                String fullName = (fName + ' ' + lName).trim();
                if (String.isBlank(fullName)) fullName = u.Name; // Use Name as fallback if First/Last are missing

                // Only include if they have hours or we want all employees
                EmployeeProductivityWrapper w = new EmployeeProductivityWrapper();
                w.employeeId = u.Id;
                w.employeeName = fullName;
                w.department = u.Department != null ? u.Department : 'N/A';
                w.totalHours = m.totalHours;
                w.approvedHours = m.approvedHours;
                w.targetHours = m.targetHours;
                w.productivityPct = m.productivityPct;
                wrappers.add(w);
            }
            return wrappers;
        } catch (Exception e) {
            System.debug('Error in getEmployeeProductivityStats: ' + e.getMessage());
            throw new AuraHandledException('Error fetching employee productivity: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static String approveTimesheetEntry(String entryId) {
        try {
            TimesheetEntry__c entry = [SELECT Id, Approval_Status__c FROM TimesheetEntry__c WHERE Id = :entryId];
            entry.Approval_Status__c = 'Approved';
            entry.Approved_By__c = UserInfo.getUserId();
            entry.Approved_Date__c = System.now();
            update entry;
            System.debug('Entry ' + entryId + ' approved successfully');
            return 'Success';
        } catch (Exception e) {
            System.debug('Error approving entry: ' + e.getMessage());
            throw new AuraHandledException('Error approving entry: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static String rejectTimesheetEntry(String entryId, String reason) {
        try {
            TimesheetEntry__c entry = [SELECT Id, Approval_Status__c FROM TimesheetEntry__c WHERE Id = :entryId];
            entry.Approval_Status__c = 'Rejected';
            // UNCOMMENT these fields if they exist on your TimesheetEntry__c object
            // entry.Rejection_Reason__c = reason;
            // entry.Rejected_By__c = UserInfo.getUserId();
            // entry.Rejection_Date__c = System.now();
            update entry;
            System.debug('Entry ' + entryId + ' rejected with reason: ' + reason);
            return 'Success';
        } catch (Exception e) {
            System.debug('Error rejecting entry: ' + e.getMessage());
            throw new AuraHandledException('Error rejecting entry: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<String> getFilterOptions(String filterType) {
        List<String> options = new List<String>();
        
        try {
            System.debug('getFilterOptions called for: ' + filterType);
            
            if(filterType == 'employees') {
                // Get distinct employee names with timesheet entries using Set
                Set<String> employeeNames = new Set<String>();
                
                for(TimesheetEntry__c te : [
                    SELECT Timesheet__r.Employee__r.Name 
                    FROM TimesheetEntry__c 
                    WHERE Timesheet__r.Employee__r.Name != null
                ]) {
                    if(String.isNotBlank(te.Timesheet__r.Employee__r.Name)) {
                        employeeNames.add(te.Timesheet__r.Employee__r.Name);
                    }
                }
                
                List<String> empList = new List<String>(employeeNames);
                empList.sort();
                options.addAll(empList);
                
            } else if(filterType == 'departments') {
                // Get distinct departments from timesheet entries using Set to eliminate duplicates
                Set<String> departments = new Set<String>();
                
                for(TimesheetEntry__c te : [
                    SELECT Timesheet__r.Employee__r.Department 
                    FROM TimesheetEntry__c 
                    WHERE Timesheet__r.Employee__r.Department != null
                ]) {
                    if(String.isNotBlank(te.Timesheet__r.Employee__r.Department)) {
                        departments.add(te.Timesheet__r.Employee__r.Department);
                    }
                }
                
                List<String> deptList = new List<String>(departments);
                deptList.sort();
                options.addAll(deptList);
                
            } else if(filterType == 'projects') {
                // Get active projects with timesheet entries using Set
                Set<String> projectNames = new Set<String>();
                
                for(TimesheetEntry__c te : [
                    SELECT Project__r.Name 
                    FROM TimesheetEntry__c 
                    WHERE Project__r.Name != null
                ]) {
                    if(String.isNotBlank(te.Project__r.Name)) {
                        projectNames.add(te.Project__r.Name);
                    }
                }
                
                List<String> projList = new List<String>(projectNames);
                projList.sort();
                options.addAll(projList);
                
            } else if(filterType == 'status') {
                options.addAll(new List<String>{'Pending', 'Approved', 'Rejected'});
            }
            
            System.debug('Filter options for ' + filterType + ': ' + options);
        } catch (Exception e) {
            System.debug('Error in getFilterOptions: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
        }
        
        return options;
    }
   @AuraEnabled(cacheable=true)
public static List<String> searchFilterOptions(String filterType, String searchTerm) {
    List<String> results = new List<String>();
    try {
        String likeTerm = '%' + searchTerm.toLowerCase() + '%';
        if (filterType == 'employees') {
            for (User u : [
                SELECT Name FROM User 
                WHERE IsActive = true AND Name LIKE :likeTerm 
                AND (NOT Name LIKE '%Integration%') AND (NOT Name LIKE '%Einstein%') AND Name NOT IN ('IT Admin', 'Automated Process', 'Data.com Clean')
                ORDER BY Name LIMIT 50
            ]) {
                results.add(u.Name);
            }
        } else if (filterType == 'departments') {
            Set<String> uniqueDepartments = new Set<String>();
            // Replace 'Department__c' with your actual API field name if different
            for (User u : [
                SELECT Department FROM User 
                WHERE IsActive = true AND Department != null
            ]) {
                if (!String.isBlank(u.Department) && 
                    u.Department.toLowerCase().contains(searchTerm.toLowerCase())) {
                    uniqueDepartments.add(u.Department);
                }
            }
            results.addAll(uniqueDepartments);
        } else if (filterType == 'projects') {
            for (Project__c p : [
                SELECT Name FROM Project__c 
                WHERE Name LIKE :likeTerm 
                ORDER BY Name LIMIT 50
            ]) {
                results.add(p.Name);
            }
        }
        return results;
    } catch (Exception e) {
        System.debug('Error in searchFilterOptions: ' + e.getMessage());
        throw new AuraHandledException('Error searching filter options: ' + e.getMessage());
    }
}



    public class EmployeeProductivityWrapper {
        @AuraEnabled public Id employeeId;
        @AuraEnabled public String employeeName;
        @AuraEnabled public String department;
        @AuraEnabled public Decimal totalHours;
        @AuraEnabled public Decimal approvedHours;
        @AuraEnabled public Decimal targetHours;
        @AuraEnabled public Decimal productivityPct;
    }

    @AuraEnabled(cacheable=false)
    public static List<Map<String,Object>> getAdminTimesheetSummary(
        String startDateStr,
        String endDateStr,
        String departmentFilter,
        String employeeFilter
    ) {
        try {
            Date startDate = Date.valueOf(startDateStr);
            Date endDate = Date.valueOf(endDateStr);

            // Fetch all active internal and community users with Employee IDs, excluding system accounts
            String userQuery = 'SELECT Id, FirstName, LastName, Name, Employee_IDs__c, Department FROM User WHERE IsActive = true AND Employee_IDs__c != null';
            userQuery += ' AND (NOT Name LIKE \'%Integration%\') AND (NOT Name LIKE \'%Einstein%\') AND Name NOT IN (\'IT Admin\', \'Automated Process\', \'Data.com Clean\')';
            
            if (String.isNotBlank(departmentFilter) && departmentFilter != 'All Departments') {
                userQuery += ' AND Department = :departmentFilter';
            }
            if (String.isNotBlank(employeeFilter) && employeeFilter != 'All Employees') {
                userQuery += ' AND Name = :employeeFilter';
            }
            userQuery += ' ORDER BY FirstName, LastName ASC';
            List<User> users = Database.query(userQuery);
            Set<Id> userIds = new Set<Id>();
            for (User u : users) userIds.add(u.Id);

            // Use Bulk Productivity Service for all calculations in this range
            Map<Id, TimesheetProductivityService.ProductivityMetrics> prodMap = 
                TimesheetProductivityService.calculateBulkProductivity(userIds, startDate, endDate);

            // Fetch timesheet entries in range
            List<TimesheetEntry__c> entries = userIds.isEmpty() ? new List<TimesheetEntry__c>() : [
                SELECT Timesheet__r.Employee__c, Timesheet__r.Approval_Status__c,
                       Total_Hours__c, Billing_Status__c, Approval_Status__c, Status__c
                FROM TimesheetEntry__c
                WHERE Timesheet__r.Employee__c IN :userIds
                  AND Date__c >= :startDate AND Date__c <= :endDate
            ];

            List<Map<String,Object>> rows = new List<Map<String,Object>>();
            for (User u : users) {
                Id uid = u.Id;
                String fName = u.FirstName != null ? u.FirstName : '';
                String lName = u.LastName != null ? u.LastName : '';
                String fullName = (fName + ' ' + lName).trim();
                if (String.isBlank(fullName)) fullName = u.Name;

                TimesheetProductivityService.ProductivityMetrics m = prodMap.get(uid);
                if (m == null) m = new TimesheetProductivityService.ProductivityMetrics();

                // Billing-specific aggregation still needed from local entry scan
                Decimal lB=0, lNB=0, lSh=0, aB=0, aNB=0, aSh=0, rB=0, rNB=0, rSh=0;
                for (TimesheetEntry__c e : entries) {
                    if (e.Timesheet__r.Employee__c != uid) continue;
                    Decimal hrs = e.Total_Hours__c != null ? e.Total_Hours__c : 0;
                    String bill = (e.Billing_Status__c != null ? e.Billing_Status__c : '').toLowerCase();
                    String status = (e.Approval_Status__c != null ? e.Approval_Status__c : '').toLowerCase();
                    
                    if (bill == 'billable') { lB += hrs; if(status=='approved') aB += hrs; else if(status=='rejected') rB += hrs; }
                    else if (bill.contains('non')) { lNB += hrs; if(status=='approved') aNB += hrs; else if(status=='rejected') rNB += hrs; }
                    else { lSh += hrs; if(status=='approved') aSh += hrs; else if(status=='rejected') rSh += hrs; }
                }

                rows.add(new Map<String,Object>{
                    'userId'          => uid,
                    'name'            => fullName,
                    'initials'        => (fName.length()>0 && lName.length()>0) ? (fName.substring(0,1)+lName.substring(0,1)).toUpperCase() : u.Name.substring(0,1).toUpperCase(),
                    'employeeId'      => u.Employee_IDs__c != null ? String.valueOf(u.Employee_IDs__c) : '',
                    'department'      => u.Department != null ? u.Department : 'N/A',
                    'loggedBillable'  => lB, 'loggedNonBillable' => lNB, 'loggedShadow' => lSh, 'loggedTotal' => lB+lNB+lSh,
                    'approvedBillable'=> aB, 'approvedNonBillable'=> aNB, 'approvedShadow'=> aSh, 'approvedTotal'=> m.approvedHours,
                    'rejectedBillable'=> rB, 'rejectedNonBillable'=> rNB, 'rejectedShadow'=> rSh, 'rejectedTotal'=> rB+rNB+rSh,
                    'targetHours'     => m.targetHours,
                    'leaveHours'      => m.leaveHours,
                    'leaveDays'       => (m.leaveHours / 8.0).setScale(1),
                    'prodBillable'    => m.targetHours > 0 ? ((aB  * 100.0) / m.targetHours).setScale(1) : 0.0,
                    'prodNonBillable' => m.targetHours > 0 ? ((aNB * 100.0) / m.targetHours).setScale(1) : 0.0,
                    'prodShadow'      => m.targetHours > 0 ? ((aSh * 100.0) / m.targetHours).setScale(1) : 0.0,
                    'productivityRate'=> m.productivityPct
                });
            }
            return rows;
        } catch (Exception e) {
            System.debug('Error in getAdminTimesheetSummary: ' + e.getMessage());
            throw new AuraHandledException('Error fetching timesheet summary: ' + e.getMessage());
        }
    }


    public class TimesheetEntryWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String employeeName;
        @AuraEnabled public String department;
        @AuraEnabled public String projectName;
        @AuraEnabled public Date entryDate;
        @AuraEnabled public Decimal hours;
        @AuraEnabled public String status;
        @AuraEnabled public String billingStatus;
        @AuraEnabled public String task;
        @AuraEnabled public String description;
    }
}