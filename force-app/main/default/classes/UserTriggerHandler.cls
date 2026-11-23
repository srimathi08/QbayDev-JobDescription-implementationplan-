public without sharing class UserTriggerHandler {
    
    private static final List<String> COMMON_PROJECTS = new List<String>{
        'Qbay - Meeting',
        'Learning & Training',
        'Qbay - Presales'
    };

    public static void handleAfterInsert(Map<Id, User> newUsers) {
        Set<Id> activeUserIds = new Set<Id>();
        
        for (User u : newUsers.values()) {
            if (u.IsActive) {
                activeUserIds.add(u.Id);
            }
        }
        
        if (!activeUserIds.isEmpty()) {
            assignCommonProjects(activeUserIds);
        }
    }
    
    public static void handleAfterUpdate(Map<Id, User> newUsers, Map<Id, User> oldUsers) {
        Set<Id> newlyActivatedUserIds = new Set<Id>();
        
        for (User u : newUsers.values()) {
            User oldU = oldUsers.get(u.Id);
            // If user became active
            if (u.IsActive && !oldU.IsActive) {
                newlyActivatedUserIds.add(u.Id);
            }
        }
        
        if (!newlyActivatedUserIds.isEmpty()) {
            assignCommonProjects(newlyActivatedUserIds);
        }
    }
    
    @future
    private static void assignCommonProjects(Set<Id> userIds) {
        // Query the common projects
        List<Project__c> projects = [
            SELECT Id, Name 
            FROM Project__c 
            WHERE Name IN :COMMON_PROJECTS
        ];
        
        if (projects.isEmpty()) {
            return;
        }
        
        // Query existing assignments to avoid duplicates
        List<Project_Assignment__c> existingAssignments = [
            SELECT Employee__c, Project__c 
            FROM Project_Assignment__c 
            WHERE Employee__c IN :userIds AND Project__c IN :projects
        ];
        
        // Build a set of EmployeeId-ProjectId to check existence
        Set<String> existingKeys = new Set<String>();
        for (Project_Assignment__c pa : existingAssignments) {
            existingKeys.add(pa.Employee__c + '-' + pa.Project__c);
        }
        
        List<Project_Assignment__c> newAssignments = new List<Project_Assignment__c>();
        
        for (Id userId : userIds) {
            for (Project__c proj : projects) {
                String key = userId + '-' + proj.Id;
                if (!existingKeys.contains(key)) {
                    Project_Assignment__c newPa = new Project_Assignment__c();
                    newPa.Employee__c = userId;
                    newPa.Project__c = proj.Id;
                    newPa.Employment_Status__c = 'Non-Billable';
                    // Role__c is left blank intentionally
                    newAssignments.add(newPa);
                }
            }
        }
        
        if (!newAssignments.isEmpty()) {
            insert newAssignments;
        }
    }
}