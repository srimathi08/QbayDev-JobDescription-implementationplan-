/**
 * @description Admin Attendance View Controller - Enhanced with Dropdown Filters
 * @author Salesforce Consultant
 * @date 2025-10-17
 * @version 2.2 - WFH Approval status & Reason read from Work_from_home_Request__c; removed WFH Reason from CSV export
 *
 * Features:
 * - Shows all active employees across the date range
 * - Employee ID / Name / Department / Date Range filters
 * - Pagination and in-memory sorting
 * - WFH Approval status and WFH Reason from WFH requests
 * - CSV export (Status / Work Mode and WFH Approval, excluding WFH Reason)
 */
public without sharing class AdminAttendanceViewController {

    /**
     * @description Main method to retrieve attendance records for admin view
     * Shows ALL active employees across the date range, including
     * Work from Office, Work from Home, On Leave, Holidays, Weekends, and Missing Check-in.
     * @param filterParams Map containing all filter parameters
     * @return Map containing records, total count, and metadata
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getAdminAttendanceRecords(Map<String, Object> filterParams) {
        Map<String, Object> response = new Map<String, Object>();

        try {
            System.debug('=== ADMIN ATTENDANCE VIEW - GET ALL EMPLOYEE RECORDS ===');
            System.debug('Filter Parameters: ' + JSON.serializePretty(filterParams));

            // Validate admin permissions
            if (!hasAdminPermission()) {
                throw new AuraHandledException('Access Denied: You do not have permission to view admin attendance data');
            }

            // Extract filter parameters
            String employeeId = getFilterValue(filterParams, 'employeeId');
            String employeeName = getFilterValue(filterParams, 'employeeName');
            String department = getFilterValue(filterParams, 'department');
            Date startDate = getDateValue(filterParams, 'startDate');
            Date endDate = getDateValue(filterParams, 'endDate');

            // Pagination parameters
            Integer pageSize = getIntegerValue(filterParams, 'pageSize', 20);
            Integer pageNumber = getIntegerValue(filterParams, 'pageNumber', 1);
            Integer offset = (pageNumber - 1) * pageSize;

            // Sorting parameters
            String sortField = getFilterValue(filterParams, 'sortField');
            String sortDirection = getFilterValue(filterParams, 'sortDirection');
            if (String.isBlank(sortField)) {
                sortField = 'Date__c';
                sortDirection = 'DESC';
            }

            // Default Date Handling
            if (endDate == null) {
                endDate = Date.today();
            }
            if (startDate == null) {
                startDate = endDate.addDays(-7);
            }
            if (startDate > endDate) {
                Date temp = startDate;
                startDate = endDate;
                endDate = temp;
            }
            // Safeguard date range to max 31 days if querying all employees to prevent heap limits
            if (startDate.daysBetween(endDate) > 31 && String.isBlank(employeeId) && String.isBlank(employeeName)) {
                startDate = endDate.addDays(-31);
            }

            // 1. Query Active Employees (User)
            String userQuery = 'SELECT Id, Name, Email, Department, ManagerId, Manager.Name, Employee_IDs__c ' +
                               'FROM User WHERE IsActive = true AND Employee_IDs__c != null ';
            if (String.isNotBlank(employeeId)) {
                userQuery += ' AND Employee_IDs__c = \'' + String.escapeSingleQuotes(employeeId) + '\'';
            }
            if (String.isNotBlank(employeeName)) {
                userQuery += ' AND Name = \'' + String.escapeSingleQuotes(employeeName) + '\'';
            }
            if (String.isNotBlank(department)) {
                userQuery += ' AND Department = \'' + String.escapeSingleQuotes(department) + '\'';
            }
            userQuery += ' ORDER BY Name ASC LIMIT 1000';

            List<User> userList = Database.query(userQuery);
            Set<Id> userIds = new Set<Id>();
            for (User u : userList) {
                userIds.add(u.Id);
            }

            // 2. Query Attendance Records for these users in [startDate, endDate]
            Map<String, Employee_Attendance__c> attendanceMap = new Map<String, Employee_Attendance__c>();
            if (!userIds.isEmpty()) {
                List<Employee_Attendance__c> attList = [
                    SELECT Id, Name, Employee_Name__c, Employee_Name__r.Name, Employee_Name__r.Email,
                           Employee_Name__r.Employee_IDs__c, Employee_Name__r.Department,
                           Employee_Name__r.Manager.Name,
                           Date__c, Check_In_Time__c, Check_Out_Time__c, Hours_Worked__c,
                           Work_Location__c, Check_In_Location_Name__c, Check_Out_Location_Name__c,
                           WFH_Reason__c, WFH_Approval_Status__c, Status__c,
                           CreatedDate, LastModifiedDate
                    FROM Employee_Attendance__c
                    WHERE Employee_Name__c IN :userIds
                    AND Date__c >= :startDate
                    AND Date__c <= :endDate
                ];
                for (Employee_Attendance__c att : attList) {
                    attendanceMap.put(att.Employee_Name__c + '_' + String.valueOf(att.Date__c), att);
                }
            }

            // 3. Query Approved Leaves in [startDate, endDate]
            Map<String, Leave_Request__c> leaveMap = new Map<String, Leave_Request__c>();
            if (!userIds.isEmpty()) {
                try {
                    List<Leave_Request__c> leaveList = [
                        SELECT Id, Employee__c, Start_Date__c, End_Date__c, Status__c,
                               Leave_Type__c, Leave_Type__r.Leave_Code__c, Leave_Type__r.Leave_Type_Name__c,
                               Is_Half_Day__c, Half_Day_Type__c
                        FROM Leave_Request__c
                        WHERE Employee__c IN :userIds
                        AND Status__c = 'Approved'
                        AND (
                            (Start_Date__c >= :startDate AND Start_Date__c <= :endDate)
                            OR (End_Date__c >= :startDate AND End_Date__c <= :endDate)
                            OR (Start_Date__c <= :startDate AND End_Date__c >= :endDate)
                        )
                    ];
                    for (Leave_Request__c lr : leaveList) {
                        Date cur = lr.Start_Date__c < startDate ? startDate : lr.Start_Date__c;
                        Date last = lr.End_Date__c > endDate ? endDate : lr.End_Date__c;
                        while (cur <= last) {
                            leaveMap.put(lr.Employee__c + '_' + String.valueOf(cur), lr);
                            cur = cur.addDays(1);
                        }
                    }
                } catch (Exception e) {
                    System.debug('Leave Query note: ' + e.getMessage());
                }
            }

            // 4. Query Holidays in [startDate, endDate]
            Map<Date, Holiday__c> holidayMap = new Map<Date, Holiday__c>();
            try {
                List<Holiday__c> holidays = [
                    SELECT Id, Name, Holiday_Date__c
                    FROM Holiday__c
                    WHERE Holiday_Date__c >= :startDate AND Holiday_Date__c <= :endDate
                ];
                for (Holiday__c h : holidays) {
                    holidayMap.put(h.Holiday_Date__c, h);
                }
            } catch (Exception e) {
                System.debug('Holiday Query note: ' + e.getMessage());
            }

            // 4b. ✅ Query WFH requests (real approval status and reason) in [startDate, endDate]
            // Key format: employeeId_yyyy-MM-dd
            Map<String, Work_from_home_Request__c> wfhRequestMap = new Map<String, Work_from_home_Request__c>();
            if (!userIds.isEmpty()) {
                try {
                    Boolean hasRequestType = Schema.sObjectType.Work_from_home_Request__c.fields.getMap().containsKey('Request_Type__c');
                    String wfhQuery = 'SELECT Employee__c, Start_Date__c, End_Date__c, Status__c, Reason__c' +
                                      (hasRequestType ? ', Request_Type__c' : '') +
                                      ' FROM Work_from_home_Request__c' +
                                      ' WHERE Employee__c IN :userIds' +
                                      ' AND Start_Date__c <= :endDate' +
                                      ' AND End_Date__c >= :startDate' +
                                      ' ORDER BY CreatedDate ASC';

                    for (Work_from_home_Request__c w : (List<Work_from_home_Request__c>) Database.query(wfhQuery)) {
                        // Skip weekend/holiday work permissions - only normal WFH requests (if field exists)
                        if (hasRequestType) {
                            String reqType = (String) w.get('Request_Type__c');
                            if (reqType == 'Weekend Work' || reqType == 'Holiday Work') {
                                continue;
                            }
                        }
                        Date cur = w.Start_Date__c < startDate ? startDate : w.Start_Date__c;
                        Date last = w.End_Date__c > endDate ? endDate : w.End_Date__c;
                        while (cur <= last) {
                            // later requests overwrite earlier ones
                            wfhRequestMap.put(w.Employee__c + '_' + String.valueOf(cur), w);
                            cur = cur.addDays(1);
                        }
                    }
                } catch (Exception e) {
                    System.debug('WFH Request Query note: ' + e.getMessage());
                }
            }

            // 5. Assemble all rows (dates x employees)
            List<Map<String, Object>> allRows = new List<Map<String, Object>>();
            Integer totalDays = startDate.daysBetween(endDate);

            for (Integer d = totalDays; d >= 0; d--) {
                Date currDate = startDate.addDays(d);
                DateTime dt = DateTime.newInstance(currDate, Time.newInstance(12, 0, 0, 0));
                String dayOfWeek = dt.format('EEE');
                Boolean isWeekend = (dayOfWeek == 'Sat' || dayOfWeek == 'Sun');
                Boolean isHoliday = holidayMap.containsKey(currDate);
                String holidayName = isHoliday ? holidayMap.get(currDate).Name : '';

                for (User u : userList) {
                    String key = u.Id + '_' + String.valueOf(currDate);
                    Employee_Attendance__c att = attendanceMap.get(key);
                    Leave_Request__c leave = leaveMap.get(key);

                    Map<String, Object> formattedRecord = new Map<String, Object>();

                    // Basic & Employee Info
                    formattedRecord.put('employeeId', u.Employee_IDs__c != null ? String.valueOf(u.Employee_IDs__c) : '--');
                    formattedRecord.put('employeeName', u.Name);
                    formattedRecord.put('employeeEmail', u.Email);
                    formattedRecord.put('department', u.Department != null ? u.Department : '--');
                    formattedRecord.put('managerName', u.Manager != null ? u.Manager.Name : '--');

                    // Date
                    formattedRecord.put('date', currDate.format());
                    formattedRecord.put('dateValue', currDate);

                    if (att != null && att.Check_In_Time__c != null) {
                        // === PRESENT (Checked in) ===
                        formattedRecord.put('recordId', att.Id);
                        formattedRecord.put('recordName', att.Name);
                        formattedRecord.put('hasAttendanceRecord', true);

                        formattedRecord.put('checkInTime', formatDateTime(att.Check_In_Time__c));
                        formattedRecord.put('checkInTimeValue', att.Check_In_Time__c);

                        if (att.Check_Out_Time__c != null) {
                            formattedRecord.put('checkOutTime', formatDateTime(att.Check_Out_Time__c));
                            formattedRecord.put('checkOutTimeValue', att.Check_Out_Time__c);
                        } else {
                            formattedRecord.put('checkOutTime', '--');
                            formattedRecord.put('checkOutTimeValue', null);
                        }

                        if (att.Hours_Worked__c != null && att.Hours_Worked__c > 0) {
                            formattedRecord.put('hoursWorked', formatHoursWorked(att.Hours_Worked__c));
                            formattedRecord.put('hoursWorkedValue', att.Hours_Worked__c);
                        } else {
                            formattedRecord.put('hoursWorked', '00h 00m');
                            formattedRecord.put('hoursWorkedValue', 0);
                        }

                        String displayLoc = att.Check_In_Location_Name__c;
                        if (String.isBlank(displayLoc)) {
                            displayLoc = att.Work_Location__c;
                        }
                        if (String.isBlank(displayLoc)) {
                            displayLoc = 'Office';
                        }
                        formattedRecord.put('location', displayLoc);
                        formattedRecord.put('workLocation', att.Work_Location__c);
                        formattedRecord.put('checkInLocationName', att.Check_In_Location_Name__c);
                        formattedRecord.put('checkOutLocationName', att.Check_Out_Location_Name__c);

                        // Status / Work Mode
                        if (att.Work_Location__c == 'Work from Home') {
                            formattedRecord.put('status', 'Work from Home');
                            formattedRecord.put('statusBadgeClass', 'status-badge badge-wfh');
                        } else {
                            if (att.Status__c == 'Late') {
                                formattedRecord.put('status', 'Work from Office (Late)');
                            } else {
                                formattedRecord.put('status', 'Work from Office');
                            }
                            formattedRecord.put('statusBadgeClass', 'status-badge badge-wfo');
                        }

                        Map<String, String> wfhInfo = processWFHApprovalStatus(att);
                        formattedRecord.put('wfhApprovalStatus', wfhInfo.get('status'));
                        formattedRecord.put('wfhApprovalStatusText', wfhInfo.get('displayText'));
                        formattedRecord.put('wfhApprovalStatusClass', wfhInfo.get('cssClass'));
                        formattedRecord.put('wfhReason', att.WFH_Reason__c);
                        formattedRecord.put('isWFHRequest', att.Work_Location__c == 'Work from Home');
                        formattedRecord.put('hasWFHReason', String.isNotBlank(att.WFH_Reason__c));
                        formattedRecord.put('isCompleteDay', att.Check_In_Time__c != null && att.Check_Out_Time__c != null);
                        formattedRecord.put('createdDate', att.CreatedDate);
                        formattedRecord.put('lastModifiedDate', att.LastModifiedDate);

                    } else if (leave != null) {
                        // === ON APPROVED LEAVE ===
                        formattedRecord.put('recordId', 'LEAVE_' + u.Id + '_' + String.valueOf(currDate));
                        formattedRecord.put('recordName', 'Leave');
                        formattedRecord.put('hasAttendanceRecord', false);
                        formattedRecord.put('checkInTime', '--');
                        formattedRecord.put('checkInTimeValue', null);
                        formattedRecord.put('checkOutTime', '--');
                        formattedRecord.put('checkOutTimeValue', null);
                        formattedRecord.put('hoursWorked', '00h 00m');
                        formattedRecord.put('hoursWorkedValue', 0);
                        formattedRecord.put('location', 'On Leave');
                        formattedRecord.put('workLocation', 'On Leave');

                        String leaveTypeName = leave.Leave_Type__r?.Leave_Type_Name__c;
                        if (String.isBlank(leaveTypeName)) {
                            leaveTypeName = leave.Leave_Type__r?.Leave_Code__c;
                        }
                        if (String.isBlank(leaveTypeName)) {
                            leaveTypeName = 'Leave';
                        }
                        formattedRecord.put('status', 'On Leave (' + leaveTypeName + ')');
                        formattedRecord.put('statusBadgeClass', 'status-badge badge-leave');

                        formattedRecord.put('wfhApprovalStatus', '--');
                        formattedRecord.put('wfhApprovalStatusText', '--');
                        formattedRecord.put('wfhApprovalStatusClass', 'wfh-badge wfh-none');
                        formattedRecord.put('wfhReason', '');
                        formattedRecord.put('isWFHRequest', false);
                        formattedRecord.put('hasWFHReason', false);
                        formattedRecord.put('isCompleteDay', false);

                    } else if (isHoliday) {
                        // === HOLIDAY ===
                        formattedRecord.put('recordId', 'HOLIDAY_' + u.Id + '_' + String.valueOf(currDate));
                        formattedRecord.put('recordName', 'Holiday');
                        formattedRecord.put('hasAttendanceRecord', false);
                        formattedRecord.put('checkInTime', '--');
                        formattedRecord.put('checkInTimeValue', null);
                        formattedRecord.put('checkOutTime', '--');
                        formattedRecord.put('checkOutTimeValue', null);
                        formattedRecord.put('hoursWorked', '00h 00m');
                        formattedRecord.put('hoursWorkedValue', 0);
                        formattedRecord.put('location', 'Holiday');
                        formattedRecord.put('workLocation', 'Holiday');

                        formattedRecord.put('status', 'Holiday' + (String.isNotBlank(holidayName) ? ' (' + holidayName + ')' : ''));
                        formattedRecord.put('statusBadgeClass', 'status-badge badge-holiday');

                        formattedRecord.put('wfhApprovalStatus', '--');
                        formattedRecord.put('wfhApprovalStatusText', '--');
                        formattedRecord.put('wfhApprovalStatusClass', 'wfh-badge wfh-none');
                        formattedRecord.put('wfhReason', '');
                        formattedRecord.put('isWFHRequest', false);
                        formattedRecord.put('hasWFHReason', false);
                        formattedRecord.put('isCompleteDay', false);

                    } else if (isWeekend) {
                        // === WEEKEND ===
                        formattedRecord.put('recordId', 'WEEKEND_' + u.Id + '_' + String.valueOf(currDate));
                        formattedRecord.put('recordName', 'Weekend');
                        formattedRecord.put('hasAttendanceRecord', false);
                        formattedRecord.put('checkInTime', '--');
                        formattedRecord.put('checkInTimeValue', null);
                        formattedRecord.put('checkOutTime', '--');
                        formattedRecord.put('checkOutTimeValue', null);
                        formattedRecord.put('hoursWorked', '00h 00m');
                        formattedRecord.put('hoursWorkedValue', 0);
                        formattedRecord.put('location', '--');
                        formattedRecord.put('workLocation', '--');

                        formattedRecord.put('status', 'Weekend');
                        formattedRecord.put('statusBadgeClass', 'status-badge badge-weekend');

                        formattedRecord.put('wfhApprovalStatus', '--');
                        formattedRecord.put('wfhApprovalStatusText', '--');
                        formattedRecord.put('wfhApprovalStatusClass', 'wfh-badge wfh-none');
                        formattedRecord.put('wfhReason', '');
                        formattedRecord.put('isWFHRequest', false);
                        formattedRecord.put('hasWFHReason', false);
                        formattedRecord.put('isCompleteDay', false);

                    } else {
                        // === MISSING CHECK-IN / ABSENT ===
                        formattedRecord.put('recordId', 'ABSENT_' + u.Id + '_' + String.valueOf(currDate));
                        formattedRecord.put('recordName', 'Missing Check-in');
                        formattedRecord.put('hasAttendanceRecord', false);
                        formattedRecord.put('checkInTime', '--');
                        formattedRecord.put('checkInTimeValue', null);
                        formattedRecord.put('checkOutTime', '--');
                        formattedRecord.put('checkOutTimeValue', null);
                        formattedRecord.put('hoursWorked', '00h 00m');
                        formattedRecord.put('hoursWorkedValue', 0);
                        formattedRecord.put('location', '--');
                        formattedRecord.put('workLocation', '--');

                        formattedRecord.put('status', 'Missing Check-in');
                        formattedRecord.put('statusBadgeClass', 'status-badge badge-missing');

                        formattedRecord.put('wfhApprovalStatus', '--');
                        formattedRecord.put('wfhApprovalStatusText', '--');
                        formattedRecord.put('wfhApprovalStatusClass', 'wfh-badge wfh-none');
                        formattedRecord.put('wfhReason', '');
                        formattedRecord.put('isWFHRequest', false);
                        formattedRecord.put('hasWFHReason', false);
                        formattedRecord.put('isCompleteDay', false);
                    }

                    // ✅ WFH approval and reason from the request - applies to ALL row types
                    Work_from_home_Request__c req = wfhRequestMap.get(key);
                    if (req != null && String.isNotBlank(req.Status__c)) {
                        String reqStatus = req.Status__c;
                        String shown = reqStatus.equalsIgnoreCase('Declined') ? 'Rejected' : reqStatus;
                        formattedRecord.put('wfhApprovalStatus', reqStatus);
                        formattedRecord.put('wfhApprovalStatusText', shown);
                        formattedRecord.put('wfhApprovalStatusClass', getWfhBadgeClass(reqStatus));
                        formattedRecord.put('isWFHRequest', true);

                        // Populate WFH reason from request if available
                        if (String.isNotBlank(req.Reason__c)) {
                            formattedRecord.put('wfhReason', req.Reason__c);
                            formattedRecord.put('hasWFHReason', true);
                        }
                    }

                    allRows.add(formattedRecord);
                }
            }

            // 6. Sort rows
            if (String.isNotBlank(sortField)) {
                sortAttendanceRows(allRows, sortField, sortDirection);
            }

            // 7. Pagination
            Integer totalCount = allRows.size();
            List<Map<String, Object>> paginatedRecords = new List<Map<String, Object>>();

            Integer startIndex = Math.min(offset, totalCount);
            Integer endIndex = Math.min(offset + pageSize, totalCount);

            for (Integer i = startIndex; i < endIndex; i++) {
                Map<String, Object> r = allRows[i];
                r.put('recordNumber', i + 1);
                paginatedRecords.add(r);
            }

            // 8. Build success response
            response.put('success', true);
            response.put('records', paginatedRecords);
            response.put('totalRecords', totalCount);
            response.put('pageSize', pageSize);
            response.put('pageNumber', pageNumber);
            response.put('totalPages', Math.ceil(Decimal.valueOf(totalCount) / Decimal.valueOf(pageSize)).intValue());
            response.put('hasRecords', !paginatedRecords.isEmpty());
            response.put('message', 'Successfully retrieved ' + paginatedRecords.size() + ' records');

            Map<String, Object> appliedFilters = new Map<String, Object>();
            appliedFilters.put('employeeId', employeeId);
            appliedFilters.put('employeeName', employeeName);
            appliedFilters.put('department', department);
            appliedFilters.put('startDate', startDate);
            appliedFilters.put('endDate', endDate);
            response.put('appliedFilters', appliedFilters);

            System.debug('✅ SUCCESS: Admin attendance records retrieved: ' + paginatedRecords.size() + ' of ' + totalCount);

        } catch (AuraHandledException ahe) {
            System.debug('❌ AuraHandledException: ' + ahe.getMessage());
            response.put('success', false);
            response.put('error', ahe.getMessage());
            response.put('records', new List<Object>());
            response.put('totalRecords', 0);
            throw ahe;

        } catch (Exception e) {
            System.debug('❌ Exception: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            response.put('success', false);
            response.put('error', 'Unexpected error: ' + e.getMessage());
            response.put('records', new List<Object>());
            response.put('totalRecords', 0);
        }

        return response;
    }

    /**
     * @description Sorts in-memory attendance rows by any column
     */
    private static void sortAttendanceRows(List<Map<String, Object>> rows, String sortField, String sortDirection) {
        if (rows == null || rows.size() <= 1) {
            return;
        }

        String targetKey = 'dateValue';
        if (sortField == 'Date__c' || sortField == 'date') {
            targetKey = 'dateValue';
        } else if (sortField.containsIgnoreCase('Employee_IDs__c') || sortField == 'employeeId') {
            targetKey = 'employeeId';
        } else if (sortField.containsIgnoreCase('Name') || sortField == 'employeeName') {
            targetKey = 'employeeName';
        } else if (sortField.containsIgnoreCase('Department') || sortField == 'department') {
            targetKey = 'department';
        } else if (sortField.containsIgnoreCase('Manager') || sortField == 'managerName') {
            targetKey = 'managerName';
        } else if (sortField.containsIgnoreCase('Status') || sortField == 'status') {
            targetKey = 'status';
        } else if (sortField.containsIgnoreCase('Hours_Worked') || sortField == 'hoursWorked') {
            targetKey = 'hoursWorkedValue';
        } else if (sortField.containsIgnoreCase('Check_In_Time') || sortField == 'checkInTime') {
            targetKey = 'checkInTimeValue';
        } else if (sortField.containsIgnoreCase('Check_Out_Time') || sortField == 'checkOutTime') {
            targetKey = 'checkOutTimeValue';
        } else if (sortField.containsIgnoreCase('Location') || sortField == 'location') {
            targetKey = 'location';
        } else if (sortField.containsIgnoreCase('WFH_Reason') || sortField == 'wfhReason') {
            targetKey = 'wfhReason';
        } else if (sortField.containsIgnoreCase('WFH') || sortField == 'wfhApprovalStatusText') {
            targetKey = 'wfhApprovalStatusText';
        }

        List<AttendanceRowWrapper> wrappers = new List<AttendanceRowWrapper>();
        for (Map<String, Object> r : rows) {
            wrappers.add(new AttendanceRowWrapper(r, targetKey, sortDirection));
        }
        wrappers.sort();

        rows.clear();
        for (AttendanceRowWrapper w : wrappers) {
            rows.add(w.row);
        }
    }

    /**
     * @description Wrapper class implementing Comparable for versatile in-memory sorting
     */
    public class AttendanceRowWrapper implements Comparable {
        public Map<String, Object> row;
        public String sortKey;
        public String sortDir;

        public AttendanceRowWrapper(Map<String, Object> row, String sortKey, String sortDir) {
            this.row = row;
            this.sortKey = sortKey;
            this.sortDir = (sortDir != null && sortDir.equalsIgnoreCase('ASC')) ? 'ASC' : 'DESC';
        }

        public Integer compareTo(Object otherObj) {
            AttendanceRowWrapper other = (AttendanceRowWrapper) otherObj;
            Object v1 = this.row != null ? this.row.get(this.sortKey) : null;
            Object v2 = other.row != null ? other.row.get(this.sortKey) : null;

            Integer result = 0;
            if (v1 == null && v2 == null) {
                result = 0;
            } else if (v1 == null) {
                result = -1;
            } else if (v2 == null) {
                result = 1;
            } else if (v1 instanceof Date && v2 instanceof Date) {
                result = ((Date) v1 < (Date) v2) ? -1 : (((Date) v1 > (Date) v2) ? 1 : 0);
            } else if (v1 instanceof DateTime && v2 instanceof DateTime) {
                result = ((DateTime) v1 < (DateTime) v2) ? -1 : (((DateTime) v1 > (DateTime) v2) ? 1 : 0);
            } else if (v1 instanceof Decimal && v2 instanceof Decimal) {
                result = ((Decimal) v1 < (Decimal) v2) ? -1 : (((Decimal) v1 > (Decimal) v2) ? 1 : 0);
            } else {
                result = String.valueOf(v1).toLowerCase().compareTo(String.valueOf(v2).toLowerCase());
            }

            return (this.sortDir == 'DESC') ? -result : result;
        }
    }

    /**
     * @description Build dynamic SOQL query based on filter parameters
     * (Kept for backward compatibility; not used by the current admin view)
     */
    @TestVisible
    private static String buildAttendanceQuery(
        String employeeId,
        String employeeName,
        String department,
        Date startDate,
        Date endDate,
        String sortField,
        String sortDirection,
        Integer limitRecords,
        Integer offset
    ) {
        String query = 'SELECT Id, Name, ' +
                      'Employee_Name__c, Employee_Name__r.Name, Employee_Name__r.Email, ' +
                      'Employee_Name__r.Employee_IDs__c, Employee_Name__r.Department, ' +
                      'Employee_Name__r.Manager.Name, ' +
                      'Date__c, Check_In_Time__c, Check_Out_Time__c, Hours_Worked__c, ' +
                      'Work_Location__c, Check_In_Location_Name__c, Check_Out_Location_Name__c, ' +
                      'WFH_Reason__c, WFH_Approval_Status__c, ' +
                      'CreatedDate, LastModifiedDate ' +
                      'FROM Employee_Attendance__c ';

        List<String> whereConditions = new List<String>();

        if (String.isNotBlank(employeeId)) {
            String searchTerm = String.escapeSingleQuotes(employeeId);
            whereConditions.add('Employee_Name__r.Employee_IDs__c = \'' + searchTerm + '\'');
        }

        if (String.isNotBlank(employeeName)) {
            String searchTerm = String.escapeSingleQuotes(employeeName);
            whereConditions.add('Employee_Name__r.Name = \'' + searchTerm + '\'');
        }

        if (String.isNotBlank(department)) {
            String deptSearchTerm = String.escapeSingleQuotes(department);
            whereConditions.add('Employee_Name__r.Department = \'' + deptSearchTerm + '\'');
        }

        if (startDate != null) {
            whereConditions.add('Date__c >= ' + String.valueOf(startDate));
        }

        if (endDate != null) {
            whereConditions.add('Date__c <= ' + String.valueOf(endDate));
        }

        if (!whereConditions.isEmpty()) {
            query += 'WHERE ' + String.join(whereConditions, ' AND ') + ' ';
        }

        query += 'ORDER BY ' + sortField + ' ' + sortDirection + ' ';
        query += 'LIMIT ' + limitRecords + ' ';
        query += 'OFFSET ' + offset;

        return query;
    }

    /**
     * @description Get total count of records without pagination
     * (Kept for backward compatibility; not used by the current admin view)
     */
    @TestVisible
    private static Integer getTotalRecordCount(
        String employeeId,
        String employeeName,
        String department,
        Date startDate,
        Date endDate
    ) {
        String countQuery = 'SELECT COUNT() FROM Employee_Attendance__c ';

        List<String> whereConditions = new List<String>();

        if (String.isNotBlank(employeeId)) {
            String searchTerm = String.escapeSingleQuotes(employeeId);
            whereConditions.add('Employee_Name__r.Employee_IDs__c = \'' + searchTerm + '\'');
        }

        if (String.isNotBlank(employeeName)) {
            String searchTerm = String.escapeSingleQuotes(employeeName);
            whereConditions.add('Employee_Name__r.Name = \'' + searchTerm + '\'');
        }

        if (String.isNotBlank(department)) {
            String deptSearchTerm = String.escapeSingleQuotes(department);
            whereConditions.add('Employee_Name__r.Department = \'' + deptSearchTerm + '\'');
        }

        if (startDate != null) {
            whereConditions.add('Date__c >= ' + String.valueOf(startDate));
        }

        if (endDate != null) {
            whereConditions.add('Date__c <= ' + String.valueOf(endDate));
        }

        if (!whereConditions.isEmpty()) {
            countQuery += 'WHERE ' + String.join(whereConditions, ' AND ');
        }

        System.debug('Count Query: ' + countQuery);

        return Database.countQuery(countQuery);
    }

    /**
     * @description Format attendance records for LWC display
     * (Kept for backward compatibility; not used by the current admin view)
     */
    @TestVisible
    private static List<Map<String, Object>> formatAttendanceRecords(List<Employee_Attendance__c> records) {
        List<Map<String, Object>> formattedRecords = new List<Map<String, Object>>();

        Integer recordIndex = 0;
        for (Employee_Attendance__c record : records) {
            recordIndex++;
            Map<String, Object> formattedRecord = new Map<String, Object>();

            formattedRecord.put('recordId', record.Id);
            formattedRecord.put('recordName', record.Name);
            formattedRecord.put('recordNumber', recordIndex);

            formattedRecord.put('employeeId', record.Employee_Name__r?.Employee_IDs__c);
            formattedRecord.put('employeeName', record.Employee_Name__r?.Name);
            formattedRecord.put('employeeEmail', record.Employee_Name__r?.Email);
            formattedRecord.put('department', record.Employee_Name__r?.Department);
            formattedRecord.put('managerName', record.Employee_Name__r?.Manager?.Name);

            if (record.Date__c != null) {
                formattedRecord.put('date', record.Date__c.format());
                formattedRecord.put('dateValue', record.Date__c);
            } else {
                formattedRecord.put('date', '--');
                formattedRecord.put('dateValue', null);
            }

            if (record.Check_In_Time__c != null) {
                formattedRecord.put('checkInTime', formatDateTime(record.Check_In_Time__c));
                formattedRecord.put('checkInTimeValue', record.Check_In_Time__c);
            } else {
                formattedRecord.put('checkInTime', '--');
                formattedRecord.put('checkInTimeValue', null);
            }

            if (record.Check_Out_Time__c != null) {
                formattedRecord.put('checkOutTime', formatDateTime(record.Check_Out_Time__c));
                formattedRecord.put('checkOutTimeValue', record.Check_Out_Time__c);
            } else {
                formattedRecord.put('checkOutTime', '--');
                formattedRecord.put('checkOutTimeValue', null);
            }

            if (record.Hours_Worked__c != null && record.Hours_Worked__c > 0) {
                Decimal hours = record.Hours_Worked__c;
                formattedRecord.put('hoursWorked', formatHoursWorked(hours));
                formattedRecord.put('hoursWorkedValue', hours);
            } else {
                formattedRecord.put('hoursWorked', '00h 00m');
                formattedRecord.put('hoursWorkedValue', 0);
            }

            formattedRecord.put('workLocation', record.Work_Location__c);
            formattedRecord.put('checkInLocationName', record.Check_In_Location_Name__c);
            formattedRecord.put('checkOutLocationName', record.Check_Out_Location_Name__c);

            String displayLocation = record.Check_In_Location_Name__c;
            if (String.isBlank(displayLocation)) {
                displayLocation = record.Work_Location__c;
            }
            if (String.isBlank(displayLocation)) {
                displayLocation = 'Office';
            }
            formattedRecord.put('location', displayLocation);

            formattedRecord.put('wfhReason', record.WFH_Reason__c);

            Map<String, String> wfhStatusInfo = processWFHApprovalStatus(record);
            formattedRecord.put('wfhApprovalStatus', wfhStatusInfo.get('status'));
            formattedRecord.put('wfhApprovalStatusText', wfhStatusInfo.get('displayText'));
            formattedRecord.put('wfhApprovalStatusClass', wfhStatusInfo.get('cssClass'));

            formattedRecord.put('createdDate', record.CreatedDate);
            formattedRecord.put('lastModifiedDate', record.LastModifiedDate);

            formattedRecord.put('isWFHRequest', record.Work_Location__c == 'Work from Home');
            formattedRecord.put('hasWFHReason', String.isNotBlank(record.WFH_Reason__c));
            formattedRecord.put('isCompleteDay', record.Check_In_Time__c != null && record.Check_Out_Time__c != null);

            formattedRecords.add(formattedRecord);
        }

        return formattedRecords;
    }

    /**
     * @description Process WFH approval status from the attendance record (fallback value).
     * The request-based status in getAdminAttendanceRecords overrides this when a WFH request exists.
     */
    private static Map<String, String> processWFHApprovalStatus(Employee_Attendance__c record) {
        Map<String, String> statusInfo = new Map<String, String>();

        String status = record.WFH_Approval_Status__c;
        String displayText = '--';
        String cssClass = 'wfh-badge wfh-none';

        // Only show WFH status if Work Location is "Work from Home"
        if (record.Work_Location__c == 'Work from Home' && String.isNotBlank(record.WFH_Reason__c)) {

            if (String.isBlank(status) || status.equalsIgnoreCase('Pending')) {
                displayText = 'Pending';
                cssClass = 'wfh-badge wfh-pending';

            } else if (status.equalsIgnoreCase('Approved')) {
                displayText = 'Approved';
                cssClass = 'wfh-badge wfh-approved';

            } else if (status.equalsIgnoreCase('Rejected')) {
                displayText = 'Rejected';
                cssClass = 'wfh-badge wfh-rejected';

            } else {
                displayText = status;
                cssClass = 'wfh-badge wfh-unknown';
            }
        }

        statusInfo.put('status', status);
        statusInfo.put('displayText', displayText);
        statusInfo.put('cssClass', cssClass);

        return statusInfo;
    }

    /**
     * @description ✅ NEW: CSS class for WFH approval badge based on request status
     */
    private static String getWfhBadgeClass(String status) {
        if (String.isBlank(status)) {
            return 'wfh-badge wfh-none';
        }
        switch on status.toLowerCase() {
            when 'approved' {
                return 'wfh-badge wfh-approved';
            }
            when 'rejected', 'declined' {
                return 'wfh-badge wfh-rejected';
            }
            when else {
                return 'wfh-badge wfh-pending';
            }
        }
    }

    // ============================================
    // DROPDOWN DATA METHODS
    // ============================================

    /**
     * @description Get all unique Employee IDs for dropdown filter
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getEmployeeIds() {
        List<Map<String, Object>> employeeIdOptions = new List<Map<String, Object>>();

        try {
            System.debug('=== FETCHING EMPLOYEE IDs FOR DROPDOWN ===');

            List<User> users = [
                SELECT Employee_IDs__c, Name
                FROM User
                WHERE Employee_IDs__c != null
                AND IsActive = true
                ORDER BY Employee_IDs__c ASC
                LIMIT 1000
            ];

            System.debug('Users with Employee IDs found: ' + users.size());

            for (User u : users) {
                Map<String, Object> option = new Map<String, Object>();
                option.put('label', String.valueOf(u.Employee_IDs__c) + ' - ' + u.Name);
                option.put('value', String.valueOf(u.Employee_IDs__c));
                employeeIdOptions.add(option);
            }

            System.debug('✅ Employee ID options created: ' + employeeIdOptions.size());

        } catch (Exception e) {
            System.debug('❌ Error fetching Employee IDs: ' + e.getMessage());
        }

        return employeeIdOptions;
    }

    /**
     * @description Get all unique Employee Names for dropdown filter
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getEmployeeNames() {
        List<Map<String, Object>> employeeNameOptions = new List<Map<String, Object>>();

        try {
            System.debug('=== FETCHING EMPLOYEE NAMES FOR DROPDOWN ===');

            List<User> users = [
                SELECT Id, Name, Employee_IDs__c, Department
                FROM User
                WHERE IsActive = true
                ORDER BY Name ASC
                LIMIT 1000
            ];

            System.debug('Active users found: ' + users.size());

            for (User u : users) {
                Map<String, Object> option = new Map<String, Object>();
                String label = u.Name;
                if (u.Employee_IDs__c != null) {
                    label += ' (' + String.valueOf(u.Employee_IDs__c) + ')';
                }
                option.put('label', label);
                option.put('value', u.Name);
                option.put('employeeId', u.Employee_IDs__c);
                option.put('department', u.Department);
                employeeNameOptions.add(option);
            }

            System.debug('✅ Employee Name options created: ' + employeeNameOptions.size());

        } catch (Exception e) {
            System.debug('❌ Error fetching Employee Names: ' + e.getMessage());
        }

        return employeeNameOptions;
    }

    /**
     * @description Get unique departments for filter dropdown
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getDepartments() {
        List<String> departments = new List<String>();

        try {
            System.debug('=== FETCHING DEPARTMENTS FOR DROPDOWN ===');

            List<AggregateResult> results = [
                SELECT Department
                FROM User
                WHERE Department != null
                AND IsActive = true
                GROUP BY Department
                ORDER BY Department ASC
                LIMIT 500
            ];

            for (AggregateResult ar : results) {
                String dept = (String) ar.get('Department');
                if (String.isNotBlank(dept)) {
                    departments.add(dept);
                }
            }

            System.debug('✅ Unique Departments Retrieved: ' + departments.size());

        } catch (Exception e) {
            System.debug('❌ Error retrieving departments: ' + e.getMessage());
        }

        return departments;
    }

    /**
     * @description Get employee search suggestions (for autocomplete)
     */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> searchEmployees(String searchTerm) {
        List<Map<String, Object>> employees = new List<Map<String, Object>>();

        try {
            if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
                return employees;
            }

            String searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';

            List<User> users = [
                SELECT Id, Name, Email, Employee_IDs__c, Department
                FROM User
                WHERE IsActive = true
                AND (Name LIKE :searchPattern OR Email LIKE :searchPattern)
                ORDER BY Name ASC
                LIMIT 10
            ];

            for (User u : users) {
                Map<String, Object> emp = new Map<String, Object>();
                emp.put('userId', u.Id);
                emp.put('name', u.Name);
                emp.put('email', u.Email);
                emp.put('employeeId', u.Employee_IDs__c);
                emp.put('department', u.Department);
                emp.put('label', u.Name + (u.Employee_IDs__c != null ? ' (' + u.Employee_IDs__c + ')' : ''));
                employees.add(emp);
            }

        } catch (Exception e) {
            System.debug('Error searching employees: ' + e.getMessage());
        }

        return employees;
    }

    // ============================================
    // HELPER METHODS
    // ============================================

    /**
     * @description Check if current user has admin permission
     */
    private static Boolean hasAdminPermission() {
        System.debug('✅ Permission Check: Allowing all profiles to access admin view');
        System.debug('Current User Profile: ' + UserInfo.getProfileId());
        System.debug('Current User Name: ' + UserInfo.getName());

        return true;
    }

    private static String getFilterValue(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key)) {
            return '';
        }
        Object value = params.get(key);
        return value != null ? String.valueOf(value).trim() : '';
    }

    private static Date getDateValue(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key)) {
            return null;
        }
        Object value = params.get(key);
        if (value == null) {
            return null;
        }
        try {
            return Date.valueOf(String.valueOf(value));
        } catch (Exception e) {
            System.debug('Error parsing date for key ' + key + ': ' + e.getMessage());
            return null;
        }
    }

    private static Integer getIntegerValue(Map<String, Object> params, String key, Integer defaultValue) {
        if (params == null || !params.containsKey(key)) {
            return defaultValue;
        }
        Object value = params.get(key);
        if (value == null) {
            return defaultValue;
        }
        try {
            return Integer.valueOf(value);
        } catch (Exception e) {
            System.debug('Error parsing integer for key ' + key + ': ' + e.getMessage());
            return defaultValue;
        }
    }

    /**
     * @description Format DateTime to time string (hh:mm a)
     */
    private static String formatDateTime(DateTime dt) {
        if (dt == null) {
            return '--';
        }
        try {
            return dt.format('hh:mm a');
        } catch (Exception e) {
            return dt.format();
        }
    }

    /**
     * @description Format hours worked to "HHh MMm" format
     */
    private static String formatHoursWorked(Decimal hours) {
        if (hours == null || hours <= 0) {
            return '00h 00m';
        }

        Integer totalMinutes = (hours * 60).intValue();
        Integer h = totalMinutes / 60;
        Integer m = Math.mod(totalMinutes, 60);

        return String.format('{0}h {1}m', new List<Object>{
            String.valueOf(h).leftPad(2, '0'),
            String.valueOf(m).leftPad(2, '0')
        });
    }

    // ============================================
    // CSV EXPORT
    // ============================================

    /**
     * @description Export attendance data to CSV format
     * Uses getAdminAttendanceRecords, so the WFH Approval column matches the table.
     */
    @AuraEnabled
    public static String exportAttendanceToCSV(Map<String, Object> filterParams) {
        try {
            System.debug('=== EXPORTING ATTENDANCE DATA TO CSV ===');

            // Get all records without pagination
            filterParams.put('pageSize', 10000);
            filterParams.put('pageNumber', 1);

            Map<String, Object> response = getAdminAttendanceRecords(filterParams);

            if (!(Boolean) response.get('success')) {
                throw new AuraHandledException('Failed to retrieve records for export');
            }

            List<Object> records = (List<Object>) response.get('records');

            String csv = buildCSVContent(records);

            System.debug('✅ CSV export completed: ' + records.size() + ' records');

            return csv;

        } catch (Exception e) {
            System.debug('❌ CSV Export Error: ' + e.getMessage());
            throw new AuraHandledException('CSV Export failed: ' + e.getMessage());
        }
    }

    /**
     * @description Build CSV content from records
     * Column 6 = Status / Work Mode, column 11 = WFH Approval (used by the LWC Excel styling)
     * Note: WFH Reason column has been removed as requested.
     */
    private static String buildCSVContent(List<Object> records) {
        String csv = 'Employee ID,Employee Name,Manager,Department,Date,Status / Work Mode,Check-in Time,Check-out Time,Hours Worked,Location,WFH Approval\n';

        for (Object obj : records) {
            Map<String, Object> record = (Map<String, Object>) obj;

            csv += csvEscape(record.get('employeeId')) + ',';
            csv += csvEscape(record.get('employeeName')) + ',';
            csv += csvEscape(record.get('managerName')) + ',';
            csv += csvEscape(record.get('department')) + ',';
            csv += csvEscape(record.get('date')) + ',';
            csv += csvEscape(record.get('status')) + ',';
            csv += csvEscape(record.get('checkInTime')) + ',';
            csv += csvEscape(record.get('checkOutTime')) + ',';
            csv += csvEscape(record.get('hoursWorked')) + ',';
            csv += csvEscape(record.get('location')) + ',';
            csv += csvEscape(record.get('wfhApprovalStatusText')) + '\n';
        }

        return csv;
    }

    /**
     * @description Escape CSV special characters
     */
    private static String csvEscape(Object value) {
        if (value == null) {
            return '';
        }
        String str = String.valueOf(value);
        if (str.contains(',') || str.contains('"') || str.contains('\n')) {
            str = '"' + str.replace('"', '""') + '"';
        }
        return str;
    }

    // ============================================
    // ADMIN ACCESS (Employee_Category__c based)
    // HR Manager and HR Team have full access; all other categories are restricted
    // ============================================

    /**
     * @description Check if current user has admin access based on Employee_Category__c
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> checkAdminAccess(Id userId) {
        Map<String, Object> accessInfo = new Map<String, Object>();

        try {
            System.debug('=== CHECKING ADMIN ACCESS FOR USER ===');
            System.debug('User ID: ' + userId);

            User currentUser = [
                SELECT Id, Name, Email, Employee_Category__c,
                       Employee_IDs__c, Department, Profile.Name
                FROM User
                WHERE Id = :userId
                LIMIT 1
            ];

            System.debug('User Name: ' + currentUser.Name);
            System.debug('Employee Category: ' + currentUser.Employee_Category__c);
            System.debug('Department: ' + currentUser.Department);
            System.debug('Profile: ' + currentUser.Profile.Name);

            Boolean hasAccess = false;
            String accessLevel = '';
            String categoryType = '';

            if (currentUser.Employee_Category__c == 'HR Manager') {
                hasAccess = true;
                accessLevel = 'Full Admin Access';
                categoryType = 'HR Manager';

            } else if (currentUser.Employee_Category__c == 'HR Team') {
                hasAccess = true;
                accessLevel = 'Full Admin Access';
                categoryType = 'HR Team (Assistant HR)';

            } else {
                hasAccess = false;
                accessLevel = 'No Access';
                categoryType = currentUser.Employee_Category__c != null ?
                              currentUser.Employee_Category__c : 'Not Set';
            }

            accessInfo.put('hasAccess', hasAccess);
            accessInfo.put('userName', currentUser.Name);
            accessInfo.put('userEmail', currentUser.Email);
            accessInfo.put('employeeCategory', currentUser.Employee_Category__c);
            accessInfo.put('categoryType', categoryType);
            accessInfo.put('accessLevel', accessLevel);
            accessInfo.put('department', currentUser.Department);
            accessInfo.put('profileName', currentUser.Profile.Name);
            accessInfo.put('employeeId', currentUser.Employee_IDs__c);

            if (hasAccess) {
                accessInfo.put('message', 'Access granted as ' + categoryType);
            } else {
                accessInfo.put('message', 'Access restricted. Only HR Manager and HR Team members can view this section.');
            }

            System.debug('✅ Access Check Result: ' + (hasAccess ? 'GRANTED' : 'DENIED'));
            System.debug('Access Level: ' + accessLevel);
            System.debug('Category Type: ' + categoryType);

        } catch (Exception e) {
            System.debug('❌ Error checking admin access: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());

            accessInfo.put('hasAccess', false);
            accessInfo.put('message', 'Error checking access permissions');
            accessInfo.put('error', e.getMessage());
        }

        return accessInfo;
    }

    /**
     * @description Uses Employee_Category__c to decide whether the user is an admin
     */
    @AuraEnabled(cacheable=false)
    public static Boolean isCurrentUserAdmin(Id userId) {
        try {
            User u = [
                SELECT Employee_Category__c
                FROM User
                WHERE Id = :userId
                LIMIT 1
            ];

            return (u.Employee_Category__c == 'HR Manager' ||
                    u.Employee_Category__c == 'HR Team');

        } catch (Exception e) {
            System.debug('Error in isCurrentUserAdmin: ' + e.getMessage());
            return false;
        }
    }

    /**
     * @description Get detailed access information for UI display
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getAdminAccessDetails(Id userId) {
        Map<String, Object> details = new Map<String, Object>();

        try {
            User u = [
                SELECT Name, Email, Employee_Category__c, Employee_IDs__c,
                       Department, Profile.Name, ManagerId, Manager.Name
                FROM User
                WHERE Id = :userId
                LIMIT 1
            ];

            Boolean isHRManager = u.Employee_Category__c == 'HR Manager';
            Boolean isHRTeam = u.Employee_Category__c == 'HR Team';
            Boolean hasAdminAccess = isHRManager || isHRTeam;

            details.put('hasAccess', hasAdminAccess);
            details.put('isHRManager', isHRManager);
            details.put('isHRTeam', isHRTeam);
            details.put('userName', u.Name);
            details.put('userEmail', u.Email);
            details.put('employeeCategory', u.Employee_Category__c);
            details.put('employeeId', u.Employee_IDs__c);
            details.put('department', u.Department);
            details.put('profileName', u.Profile.Name);
            details.put('managerName', u.Manager?.Name);

            if (isHRManager) {
                details.put('accessMessage', 'Full Admin Access - HR Manager');
                details.put('accessIcon', 'utility:shield');
                details.put('accessVariant', 'success');
            } else if (isHRTeam) {
                details.put('accessMessage', 'Full Admin Access - HR Team');
                details.put('accessIcon', 'utility:user');
                details.put('accessVariant', 'success');
            } else {
                details.put('accessMessage', 'Access Restricted - Not an HR Admin');
                details.put('accessIcon', 'utility:block_visitor');
                details.put('accessVariant', 'error');
            }

            List<String> allowedCategories = new List<String>{'HR Manager', 'HR Team'};
            details.put('allowedCategories', allowedCategories);

            List<String> restrictedCategories = new List<String>{
                'Management',
                'On-Role(Manager)',
                'On-Role(Team Member)',
                'Intern-Stipend',
                'Unpaid Intern'
            };
            details.put('restrictedCategories', restrictedCategories);

        } catch (Exception e) {
            System.debug('Error getting admin access details: ' + e.getMessage());
            details.put('hasAccess', false);
            details.put('error', e.getMessage());
        }

        return details;
    }

    /**
     * @description Search employees for autocomplete (lightweight version)
     * @param searchType Type of search: 'employeeId' or 'name'
     * @param searchTerm Search term entered by user
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> searchEmployeesLightweight(String searchType, String searchTerm) {
        List<Map<String, Object>> employees = new List<Map<String, Object>>();

        try {
            if (String.isBlank(searchTerm) || searchTerm.length() < 1) {
                return employees;
            }

            String searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            List<User> users = new List<User>();

            if (searchType == 'employeeId') {
                String numericSearch = searchTerm.replaceAll('[^0-9]', '');

                if (String.isNotBlank(numericSearch)) {
                    String empIdNum = String.valueOf(numericSearch);
                    users = [
                        SELECT Id, Name, Employee_IDs__c, Department, Email
                        FROM User
                        WHERE IsActive = true
                        AND (Employee_IDs__c = :empIdNum OR Name LIKE :searchPattern)
                        ORDER BY Employee_IDs__c ASC NULLS LAST
                        LIMIT 10
                    ];
                } else {
                    users = [
                        SELECT Id, Name, Employee_IDs__c, Department, Email
                        FROM User
                        WHERE IsActive = true
                        AND Name LIKE :searchPattern
                        ORDER BY Name ASC
                        LIMIT 10
                    ];
                }
            } else if (searchType == 'name') {
                users = [
                    SELECT Id, Name, Employee_IDs__c, Department, Email
                    FROM User
                    WHERE IsActive = true
                    AND Name LIKE :searchPattern
                    ORDER BY Name ASC
                    LIMIT 10
                ];
            }

            for (User u : users) {
                Map<String, Object> emp = new Map<String, Object>();
                emp.put('Id', u.Id);
                emp.put('Name', u.Name);
                emp.put('Employee_IDs__c', u.Employee_IDs__c);
                emp.put('Department', u.Department);
                emp.put('Email', u.Email);
                employees.add(emp);
            }

            System.debug('Search results: ' + employees.size() + ' employees found');

        } catch (Exception e) {
            System.debug('Error searching employees: ' + e.getMessage());
        }

        return employees;
    }

}