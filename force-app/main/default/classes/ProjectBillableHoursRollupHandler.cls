public class ProjectBillableHoursRollupHandler {

    public static void updateProjectBillableHours(
        List<TimesheetEntry__c> newList,
        List<TimesheetEntry__c> oldList
    ) {
        if (!TriggerExecutionGuard.canExecute('ProjectBillableHoursRollup')) {
            return;
        }

        Set<Id> projectIds = new Set<Id>();

        if (newList != null) {
            for (TimesheetEntry__c te : newList) {
                if (te.Project__c != null) {
                    projectIds.add(te.Project__c);
                }
            }
        }

        if (oldList != null) {
            for (TimesheetEntry__c te : oldList) {
                if (te.Project__c != null) {
                    projectIds.add(te.Project__c);
                }
            }
        }

        if (projectIds.isEmpty()) {
            return;
        }

        // Aggregate total billable hours per project
        Map<Id, Decimal> billableHoursMap = new Map<Id, Decimal>();
        for (Id projId : projectIds) {
            billableHoursMap.put(projId, 0.0);
        }

        List<AggregateResult> aggResults = [
            SELECT Project__c, SUM(Total_Hours__c) totalHours
            FROM TimesheetEntry__c
            WHERE Project__c IN :projectIds
              AND Billing_Status__c = 'Billable'
            GROUP BY Project__c
        ];

        for (AggregateResult ar : aggResults) {
            Id projId = (Id)ar.get('Project__c');
            Decimal totalHours = (Decimal)ar.get('totalHours');
            if (totalHours != null) {
                billableHoursMap.put(projId, totalHours);
            }
        }

        // Retrieve Project details to calculate percentages and send alerts
        List<Project__c> projectsToUpdate = new List<Project__c>();
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();

        for (Project__c proj : [
            SELECT Id, Name, Estimated_Hours__c, Total_Logged_Billable_Hours__c, Alert_75_Percent_Sent__c
            FROM Project__c
            WHERE Id IN :projectIds
        ]) {
            Decimal newBillableHours = billableHoursMap.get(proj.Id);
            proj.Total_Logged_Billable_Hours__c = newBillableHours;

            // Check for 75% estimation threshold
            if (proj.Estimated_Hours__c != null && proj.Estimated_Hours__c > 0) {
                Decimal thresholdPercent = (newBillableHours / proj.Estimated_Hours__c) * 100;
                if (thresholdPercent >= 75 && !proj.Alert_75_Percent_Sent__c) {
                    proj.Alert_75_Percent_Sent__c = true;
                    
                    // Retrieve email addresses of all assigned employees on this project
                    List<String> assigneeEmails = new List<String>();
                    for (Project_Assignment__c pa : [
                        SELECT Employee__r.Email 
                        FROM Project_Assignment__c 
                        WHERE Project__c = :proj.Id 
                          AND Employee__r.Email != null
                    ]) {
                        assigneeEmails.add(pa.Employee__r.Email);
                    }
                    
                    Messaging.SingleEmailMessage email = buildAlertEmail(proj, newBillableHours, assigneeEmails);
                    if (email != null) {
                        emailsToSend.add(email);
                    }
                }
            }

            projectsToUpdate.add(proj);
        }

        if (!projectsToUpdate.isEmpty()) {
            update projectsToUpdate;
        }

        if (!emailsToSend.isEmpty()) {
            try {
                Messaging.sendEmail(emailsToSend);
            } catch (Exception e) {
                System.debug('Failed to send 75% Estimation Hours alert emails: ' + e.getMessage());
            }
        }
    }

    private static Id getOrgWideEmailId() {
        List<OrgWideEmailAddress> oweaList = [
            SELECT Id
            FROM OrgWideEmailAddress
            WHERE IsAllowAllProfiles = true
            LIMIT 1
        ];
        if (!oweaList.isEmpty()) {
            return oweaList[0].Id;
        }
        return null;
    }

    private static Messaging.SingleEmailMessage buildAlertEmail(Project__c proj, Decimal loggedHours, List<String> assigneeEmails) {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        
        // Define management alert recipients dynamically via Custom Label
        String labelEmails = System.Label.Project_Management_Alert_Emails;
        Set<String> toAddresses = new Set<String>();
        
        if (String.isNotBlank(labelEmails)) {
            for (String email : labelEmails.split(',')) {
                toAddresses.add(email.trim());
            }
        }
        
        // Add assignee emails to the recipient list
        if (assigneeEmails != null && !assigneeEmails.isEmpty()) {
            for (String email : assigneeEmails) {
                toAddresses.add(email.trim());
            }
        }
        
        if (toAddresses.isEmpty()) {
            return null; // Don't send if no emails configured
        }
        
        mail.setToAddresses(new List<String>(toAddresses));
        
        // Dynamic Org Wide Email Address Assignment (Sender email configuration)
        Id oweaId = getOrgWideEmailId();
        if (oweaId != null) {
            mail.setOrgWideEmailAddressId(oweaId);
        }
        
        mail.setSubject('⚠️ Alert: Project "' + proj.Name + '" has reached 75% of Estimated Hours');
        
        String htmlBody = '<html><body style="font-family: Arial, sans-serif; color: #333;">' +
            '<div style="max-width: 600px; margin: 0 auto; border: 1px solid #e0e0e0; border-radius: 8px; overflow: hidden;">' +
            '<div style="background: linear-gradient(135deg, #e67e22, #d35400); padding: 20px; color: white;">' +
            '<h2 style="margin: 0;">⚠️ Estimation Limit Alert</h2>' +
            '</div>' +
            '<div style="padding: 24px;">' +
            '<p>Hello Team,</p>' +
            '<p>This is to inform you that the project <strong>' + proj.Name + '</strong> has reached 75% of its estimated hours capacity.</p>' +
            '<table style="width: 100%; border-collapse: collapse; margin: 16px 0;">' +
            '<tr><td style="padding: 10px; border-bottom: 1px solid #eee; font-weight: bold; color: #555;">Estimated Hours</td>' +
            '<td style="padding: 10px; border-bottom: 1px solid #eee;">' + proj.Estimated_Hours__c + ' Hours</td></tr>' +
            '<tr><td style="padding: 10px; border-bottom: 1px solid #eee; font-weight: bold; color: #555;">Total Logged Billable Hours</td>' +
            '<td style="padding: 10px; border-bottom: 1px solid #eee; font-weight: bold; color: #27ae60;">' + loggedHours + ' Hours</td></tr>' +
            '</table>' +
            '<p style="color: #c0392b; font-weight: bold;">Note: Employees will be blocked from logging timesheets for this project once it reaches 100% of the estimated hours.</p>' +
            '<p style="color: #888; font-size: 12px; margin-top: 24px;">This is an automated notification from iBrave HRMS.</p>' +
            '</div>' +
            '</div>' +
            '</body></html>';
            
        mail.setHtmlBody(htmlBody);
        mail.setSaveAsActivity(false);
        return mail;
    }
}