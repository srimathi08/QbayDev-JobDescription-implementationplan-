trigger EmployeeAttendanceTrigger on Employee_Attendance__c (before insert, before update, after update) {
    if (Trigger.isBefore) {
        for (Employee_Attendance__c record : Trigger.new) {
            // Only auto-calculate status if it's currently blank or being set for the first time
            if (String.isBlank(record.Status__c) && record.Check_In_Time__c != null) {
                // Get hour and minute in the context user's timezone
                String timeStr = record.Check_In_Time__c.format('HH:mm');
                List<String> parts = timeStr.split(':');
                Integer hour = Integer.valueOf(parts[0]);
                Integer minute = Integer.valueOf(parts[1]);
                
                // Late threshold: 10:00 AM
                if (hour > 10 || (hour == 10 && minute > 0)) {
                    record.Status__c = 'Late';
                } else {
                    record.Status__c = 'Present';
                }
            }
        }
    }
    
    // Auto-create CompOff_Request__c on Check-Out on Weekends/Holidays
    if (Trigger.isAfter && Trigger.isUpdate) {
        List<CompOff_Request__c> compOffsToCreate = new List<CompOff_Request__c>();
        
        Set<Date> checkDates = new Set<Date>();
        for (Employee_Attendance__c record : Trigger.new) {
            if (record.Date__c != null) {
                checkDates.add(record.Date__c);
            }
        }
        
        // Find if any dates are holidays
        Set<Date> holidayDates = new Set<Date>();
        if (!checkDates.isEmpty()) {
            for (Holiday__c h : [SELECT Holiday_Date__c FROM Holiday__c WHERE Holiday_Date__c IN :checkDates]) {
                holidayDates.add(h.Holiday_Date__c);
            }
        }
        
        for (Employee_Attendance__c record : Trigger.new) {
            Employee_Attendance__c oldRecord = Trigger.oldMap.get(record.Id);
            
            // If just checked out
            if (record.Check_Out_Time__c != null && oldRecord.Check_Out_Time__c == null) {
                Boolean isWeekend = false;
                if (record.Date__c != null) {
                    Datetime dt = DateTime.newInstance(record.Date__c.year(), record.Date__c.month(), record.Date__c.day());
                    String dayOfWeek = dt.format('E');
                    if (dayOfWeek == 'Sat' || dayOfWeek == 'Sun') {
                        isWeekend = true;
                    }
                }
                
                Boolean isHoliday = holidayDates.contains(record.Date__c);
                
                if (isWeekend || isHoliday) {
                    // Check hours worked
                    Decimal hoursWorked = record.Hours_Worked__c;
                    if (hoursWorked == null) {
                        Long diff = record.Check_Out_Time__c.getTime() - record.Check_In_Time__c.getTime();
                        hoursWorked = diff / (1000.0 * 60 * 60);
                    }
                    
                    if (hoursWorked >= 4) {
                        CompOff_Request__c co = new CompOff_Request__c();
                        co.Employee__c = record.Employee_Name__c;
                        co.Attendance_Record__c = record.Id;
                        co.Worked_Date__c = record.Date__c;
                        co.Status__c = 'Pending';
                        co.Day_Type__c = isHoliday ? 'Holiday' : 'Weekend';
                        if (hoursWorked >= 8) {
                            co.Comp_Type__c = 'Full Day';
                        } else {
                            co.Comp_Type__c = 'Half Day';
                        }
                        compOffsToCreate.add(co);
                    }
                }
            }
        }
        
        if (!compOffsToCreate.isEmpty()) {
            insert compOffsToCreate;
            
            // Intimation to HR
            List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
            Set<Id> userIds = new Set<Id>();
            for (CompOff_Request__c co : compOffsToCreate) {
                if (co.Employee__c != null) {
                    userIds.add(co.Employee__c);
                }
            }
            
            Map<Id, User> userMap = new Map<Id, User>();
            if (!userIds.isEmpty()) {
                userMap = new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :userIds]);
            }
            
            OrgWideEmailAddress[] owea = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
            
            String hrEmail;
            if (Test.isRunningTest()) {
                hrEmail = 'hr@test.com';
            } else {
                hrEmail = AppSettings.getHrEmail();
            }
            
            for (CompOff_Request__c co : compOffsToCreate) {
                String empName = userMap.containsKey(co.Employee__c) ? userMap.get(co.Employee__c).Name : 'Employee';
                
                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(new String[] { hrEmail });
                if (!owea.isEmpty()) {
                    mail.setOrgWideEmailAddressId(owea[0].Id);
                }
                mail.setSubject('New Comp Off Request Generated: ' + empName);
                
                String body = '<html><body style="font-family: Arial, sans-serif; color:#333;">';
                body += '<div style="max-width:600px; margin:auto; border:1px solid #e0e0e0; border-radius:10px; overflow:hidden;">';
                body += '<div style="background:#0176d3; padding:25px; text-align:center;">';
                body += '<h2 style="color:white; margin:0;">New Comp Off Request</h2>';
                body += '</div>';
                body += '<div style="padding:30px;">';
                body += '<p>Dear HR Team,</p>';
                body += '<p>A new Comp Off request has been auto-generated due to a weekend/holiday checkout.</p>';
                body += '<table border="1" cellpadding="10" cellspacing="0" style="border-collapse:collapse; width:100%;">';
                body += '<tr style="background:#f3f4f6;"><td><strong>Employee Name</strong></td><td>' + empName + '</td></tr>';
                
                String workedDateStr = '';
                if (co.Worked_Date__c != null) {
                    Datetime dt = Datetime.newInstance(co.Worked_Date__c.year(), co.Worked_Date__c.month(), co.Worked_Date__c.day());
                    workedDateStr = dt.format('MM/dd/yyyy');
                }
                
                body += '<tr><td><strong>Worked Date</strong></td><td>' + workedDateStr + '</td></tr>';
                body += '<tr style="background:#f3f4f6;"><td><strong>Day Type</strong></td><td>' + co.Day_Type__c + '</td></tr>';
                body += '<tr><td><strong>Comp Type</strong></td><td>' + co.Comp_Type__c + '</td></tr>';
                body += '<tr style="background:#f3f4f6;"><td><strong>Status</strong></td><td>' + co.Status__c + '</td></tr>';
                body += '</table>';
                body += '<p style="margin-top:20px;">Please log in to Salesforce to review and approve this request.</p>';
                body += '<p>Thank you,<br/><strong>HR Management System</strong></p>';
                body += '</div></div></body></html>';
                
                mail.setHtmlBody(body);
                emailsToSend.add(mail);
            }
            
            if (!emailsToSend.isEmpty()) {
                try {
                    Messaging.sendEmail(emailsToSend, false);
                } catch (Exception e) {
                    System.debug('Error sending Comp Off HR email: ' + e.getMessage());
                }
            }
        }
    }
}