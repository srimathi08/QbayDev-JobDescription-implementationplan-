trigger ProjectTrigger on Project__c (before update) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        for (Project__c newProj : Trigger.new) {
            Project__c oldProj = Trigger.oldMap.get(newProj.Id);
            
            // Reset alert flag if Estimated Hours has been increased
            if (newProj.Estimated_Hours__c != null && 
                (oldProj.Estimated_Hours__c == null || newProj.Estimated_Hours__c > oldProj.Estimated_Hours__c)) {
                
                Decimal currentLogged = newProj.Total_Logged_Billable_Hours__c != null ? newProj.Total_Logged_Billable_Hours__c : 0.0;
                Decimal thresholdPercent = (currentLogged / newProj.Estimated_Hours__c) * 100;
                
                if (thresholdPercent < 75) {
                    newProj.Alert_75_Percent_Sent__c = false;
                }
            }
        }
    }
}