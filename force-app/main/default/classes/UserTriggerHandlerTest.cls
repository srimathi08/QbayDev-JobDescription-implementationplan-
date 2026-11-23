@isTest
public class UserTriggerHandlerTest {
    
    @testSetup
    static void setupData() {
        // Create the 3 common projects
        List<Project__c> projs = new List<Project__c>{
            new Project__c(Name = 'Qbay - Meeting', Status__c = 'Active'),
            new Project__c(Name = 'Learning & Training', Status__c = 'Active'),
            new Project__c(Name = 'Qbay - Presales', Status__c = 'Active')
        };
        insert projs;
    }
    
    @isTest
    static void testNewActiveUserAssignment() {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        
        Test.startTest();
        User u = new User(
            Alias = 'standt', 
            Email='standarduser12345@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Testing', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='standarduser1234567890@testorg.com',
            IsActive = true
        );
        insert u;
        Test.stopTest(); // Forces @future to run
        
        // Verify assignments
        List<Project_Assignment__c> assignments = [
            SELECT Id, Project__r.Name 
            FROM Project_Assignment__c 
            WHERE Employee__c = :u.Id
        ];
        
        System.assertEquals(3, assignments.size(), 'Should have 3 projects assigned');
    }
    
    @isTest
    static void testExistingUserActivationAssignment() {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        
        // Insert as inactive to avoid trigger doing it immediately
        User u = new User(
            Alias = 'standt2', 
            Email='standarduser98765@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Testing2', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='standarduser0987654321@testorg.com',
            IsActive = false
        );
        insert u;
        
        // Ensure no assignments
        List<Project_Assignment__c> beforeAssignments = [
            SELECT Id FROM Project_Assignment__c WHERE Employee__c = :u.Id
        ];
        System.assertEquals(0, beforeAssignments.size());
        
        Test.startTest();
        // Activate user
        u.IsActive = true;
        update u;
        Test.stopTest(); // Forces @future to run
        
        // Verify assignments
        List<Project_Assignment__c> afterAssignments = [
            SELECT Id FROM Project_Assignment__c WHERE Employee__c = :u.Id
        ];
        System.assertEquals(3, afterAssignments.size(), 'Should have 3 projects assigned after activation');
    }
}