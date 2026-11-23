public with sharing class TaskTabsController {
    @AuraEnabled
    public static List<Task> getTasks(String viewName) {
        Date today = Date.today();

        // No trailing comma, correct spacing
        String soql = 
            'SELECT Id, Subject, Status, Priority, ActivityDate ' +
            'FROM Task WHERE IsDeleted = false';

        String key = (viewName == null) ? 'OPEN' : viewName.trim().toUpperCase();

        switch on key {
            when 'OPEN' {
                soql += ' AND Status = \'Open\'';
            }
            when 'OPEN_HIGH' {
                soql += ' AND Status = \'Open\' AND Priority = \'High\'';
            }
            when 'OPEN_NORMAL' {
                soql += ' AND Status = \'Open\' AND Priority = \'Normal\'';
            }
            when 'OVERDUE' {
                soql += ' AND Status = \'Open\' AND ActivityDate < :today';
            }
            when else {
                soql += ' AND Status = \'Open\'';
            }
        }

        // Keep ORDER BY simple; some orgs don’t support NULLS LAST consistently
        soql += ' ORDER BY ActivityDate DESC, CreatedDate DESC LIMIT 500';

        // Optional: uncomment to verify the final SOQL string in logs
        // System.debug('SOQL: ' + soql);

        return Database.query(soql);
    }
}