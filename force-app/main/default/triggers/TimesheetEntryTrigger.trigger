trigger TimesheetEntryTrigger on TimesheetEntry__c (before insert, before update, after insert, after update, after delete, after undelete) {
    if (Trigger.isBefore) {
        for (TimesheetEntry__c te : Trigger.new) {
            if (te.Project__c != null) {
                // Fetch the Project configuration
                List<Project__c> projList = [
                    SELECT Name, Estimated_Hours__c, Total_Logged_Billable_Hours__c 
                    FROM Project__c 
                    WHERE Id = :te.Project__c 
                    LIMIT 1
                ];
                if (!projList.isEmpty()) {
                    Project__c proj = projList[0];
                    Decimal currentBillable = proj.Total_Logged_Billable_Hours__c != null ? proj.Total_Logged_Billable_Hours__c : 0.0;
                    
                    // On update, we need to subtract the old hours from our projection check
                    Decimal oldHours = 0.0;
                    if (Trigger.isUpdate) {
                        TimesheetEntry__c oldTe = Trigger.oldMap.get(te.Id);
                        if (oldTe.Billing_Status__c == 'Billable') {
                            oldHours = oldTe.Total_Hours__c != null ? oldTe.Total_Hours__c : 0.0;
                        }
                    }
                    
                    Decimal newHours = 0.0;
                    if (te.Billing_Status__c == 'Billable') {
                        newHours = te.Total_Hours__c != null ? te.Total_Hours__c : 0.0;
                    }
                    
                    Decimal projectedBillable = currentBillable - oldHours + newHours;
                    if (proj.Estimated_Hours__c != null && proj.Estimated_Hours__c > 0 &&
                        projectedBillable > proj.Estimated_Hours__c) {
                        te.addError('Timesheet logging is blocked for Project "' + proj.Name + 
                            '" because it exceeds 100% of its estimated hours (' + proj.Estimated_Hours__c + ' Hours).');
                    }
                }
            }
        }
    }
    
    if (Trigger.isAfter) {
        ProjectBillableHoursRollupHandler.updateProjectBillableHours(Trigger.new, Trigger.old);
    }
}