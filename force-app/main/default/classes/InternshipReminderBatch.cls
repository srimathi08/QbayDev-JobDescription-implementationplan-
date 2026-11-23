public with sharing class InternshipReminderBatch implements Database.Batchable<SObject>, Database.Stateful {
    
    public Database.QueryLocator start(Database.BatchableContext bc) {
        Date today = Date.today();
        Date date30 = today.addDays(30);
        Date date15 = today.addDays(15);
        Date date7  = today.addDays(7);
        Date date1  = today.addDays(1);
        
        // Query active Interns whose end date is in 30, 15, 7, or 1 day
        return Database.getQueryLocator([
            SELECT Id, Name, Email, ManagerId, Manager.Email, Manager.Name,
                   Internship_Start_Date__c, Internship_End_Date__c, Employee_Category__c
            FROM User
            WHERE IsActive = true
            AND (Employee_Category__c = 'Intern-Stipend' OR Employee_Category__c = 'Unpaid Intern')
            AND (Internship_End_Date__c = :date30
                 OR Internship_End_Date__c = :date15 
                 OR Internship_End_Date__c = :date7 
                 OR Internship_End_Date__c = :date1)
        ]);
    }
    
    public void execute(Database.BatchableContext bc, List<User> scope) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        String hrEmail = AppSettings.getHrEmail();
        
        for (User intern : scope) {
            Integer daysRemaining = Date.today().daysBetween(intern.Internship_End_Date__c);
            
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            
            List<String> toAddresses = new List<String>();
            if (String.isNotBlank(intern.Manager.Email)) {
                toAddresses.add(intern.Manager.Email);
            }
            toAddresses.add(hrEmail);
            mail.setToAddresses(toAddresses);
            
            mail.setSubject('Action Required: Internship Ending in ' + daysRemaining + ' Days - ' + intern.Name);
            
            String body = '<html><body style="font-family: Arial, sans-serif;">';
            body += '<h2 style="color: #c2410c;">Internship Completion Reminder</h2>';
            body += '<p>Dear ' + (String.isNotBlank(intern.Manager.Name) ? intern.Manager.Name : 'Manager') + ' & HR Team,</p>';
            body += '<p>This is a reminder that the internship for <strong>' + intern.Name + '</strong> is scheduled to end on ';
            body += '<strong>' + intern.Internship_End_Date__c.format() + '</strong> (' + daysRemaining + ' day(s) remaining).</p>';
            body += '<p>No decision has been registered in the system yet. Please update the employee record to either:</p>';
            body += '<ul>';
            body += '<li><strong>Convert to On-Role</strong>: Update category to <i>On-Role(Team Member)</i> or <i>On-Role(Manager)</i>.</li>';
            body += '<li><strong>Complete Internship (Not Retained)</strong>: Update category to <i>Internship Completed (Not Retained)</i>.</li>';
            body += '</ul>';
            body += '<p><em>Note: If the decision has already been finalized, please update their Category in Salesforce immediately to stop these reminders.</em></p>';
            body += '<p>Thank you,<br/><strong>HR Management System</strong></p>';
            body += '</body></html>';
            
            mail.setHtmlBody(body);
            emails.add(mail);
        }
        
        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }
    
    public void finish(Database.BatchableContext bc) {
        System.debug('Internship reminder daily batch finished.');
    }
}