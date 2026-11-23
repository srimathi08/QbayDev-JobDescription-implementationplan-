trigger CompOffRequestTrigger on CompOff_Request__c (before update, after update) {
    if (Trigger.isBefore) {
        for (CompOff_Request__c request : Trigger.new) {
            CompOff_Request__c oldRequest = Trigger.oldMap.get(request.Id);
            
            if ((request.Status__c == 'Approved' || request.Status__c == 'Approved by HR') && 
                (oldRequest.Status__c != 'Approved' && oldRequest.Status__c != 'Approved by HR')) {
                // Set Expiry Date to 30 days from allocation
                request.Expiry_Date__c = Date.today().addDays(30);
            }
        }
    }
    
    if (Trigger.isAfter) {
        List<Employee_Leave_Balance__c> leaveBalancesToUpsert = new List<Employee_Leave_Balance__c>();
        
        // We only process records where status changed to 'Approved'
        Set<Id> approvedCompOffs = new Set<Id>();
        Set<Id> employeeIds = new Set<Id>();
        
        for (CompOff_Request__c request : Trigger.new) {
            CompOff_Request__c oldRequest = Trigger.oldMap.get(request.Id);
            
            if ((request.Status__c == 'Approved' || request.Status__c == 'Approved by HR') && 
                (oldRequest.Status__c != 'Approved' && oldRequest.Status__c != 'Approved by HR')) {
                approvedCompOffs.add(request.Id);
                if (request.Employee__c != null) {
                    employeeIds.add(request.Employee__c);
                }
            }
        }
        
        if (approvedCompOffs.isEmpty() || employeeIds.isEmpty()) return;
        
        // Get the Leave Type for 'CO' (Comp Off)
        List<Leave_Type__c> coLeaveTypes = [
            SELECT Id FROM Leave_Type__c WHERE Leave_Code__c = 'CO' OR Leave_Type_Name__c = 'Comp Off' LIMIT 1
        ];
        
        if (coLeaveTypes.isEmpty()) {
            System.debug('Error: Comp Off Leave Type (CO) not found in the system.');
            return; // We cannot credit without a valid leave type
        }
        
        Id coLeaveTypeId = coLeaveTypes[0].Id;
        
        // Check for existing leave balances for these employees for this year
        String currentYear = String.valueOf(Date.today().year());
        
        Map<Id, Employee_Leave_Balance__c> existingBalances = new Map<Id, Employee_Leave_Balance__c>();
        
        for (Employee_Leave_Balance__c balance : [
            SELECT Id, Employee__c, Leave_Type__c, Total_Allocated__c, Used__c, Available__c, Expiry_Date__c
            FROM Employee_Leave_Balance__c
            WHERE Employee__c IN :employeeIds
            AND Leave_Type__c = :coLeaveTypeId
            AND Year__c = :currentYear
        ]) {
            existingBalances.put(balance.Employee__c, balance);
        }
        
        for (CompOff_Request__c request : Trigger.new) {
            if (approvedCompOffs.contains(request.Id)) {
                Decimal creditAmount = request.Comp_Type__c == 'Half Day' ? 0.5 : 1.0;
                
                if (existingBalances.containsKey(request.Employee__c)) {
                    // Update existing balance
                    Employee_Leave_Balance__c balance = existingBalances.get(request.Employee__c);
                    if (balance.Total_Allocated__c == null) balance.Total_Allocated__c = 0;
                    balance.Total_Allocated__c += creditAmount;
                    balance.Is_Eligible__c = true; // Ensure it's visible
                    // Set or extend expiry date to 30 days from now
                    balance.Expiry_Date__c = Date.today().addDays(30);
                    leaveBalancesToUpsert.add(balance);
                } else {
                    // Create new balance
                    Employee_Leave_Balance__c newBalance = new Employee_Leave_Balance__c(
                        Employee__c = request.Employee__c,
                        Leave_Type__c = coLeaveTypeId,
                        Year__c = currentYear,
                        Total_Allocated__c = creditAmount,
                        Used__c = 0,
                        Is_Eligible__c = true, // Ensure it's visible
                        Expiry_Date__c = Date.today().addDays(30)
                    );
                    leaveBalancesToUpsert.add(newBalance);
                    existingBalances.put(request.Employee__c, newBalance); // Prevent duplicates in loop
                }
            }
        }
        
        if (!leaveBalancesToUpsert.isEmpty()) {
            upsert leaveBalancesToUpsert;
        }
    }
}