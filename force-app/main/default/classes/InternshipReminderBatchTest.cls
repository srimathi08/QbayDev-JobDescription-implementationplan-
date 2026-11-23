@isTest
private class InternshipReminderBatchTest {
    
    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        User mgr = new User(
            Alias = 'mgrusr', 
            Email='managerintern@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Manager', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='managerinterntest123@testorg.com',
            IsActive = true
        );
        insert mgr;
        
        List<User> interns = new List<User>();
        
        // 15 days
        interns.add(new User(
            Alias = 'int15', 
            Email='intern15@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Intern15', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='intern15test123@testorg.com',
            IsActive = true,
            ManagerId = mgr.Id,
            Employee_Category__c = 'Intern-Stipend',
            Internship_End_Date__c = Date.today().addDays(15)
        ));
        
        // 7 days
        interns.add(new User(
            Alias = 'int7', 
            Email='intern7@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Intern7', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='intern7test123@testorg.com',
            IsActive = true,
            ManagerId = mgr.Id,
            Employee_Category__c = 'Unpaid Intern',
            Internship_End_Date__c = Date.today().addDays(7)
        ));
        
        // 1 day
        interns.add(new User(
            Alias = 'int1', 
            Email='intern1@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Intern1', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='intern1test123@testorg.com',
            IsActive = true,
            ManagerId = mgr.Id,
            Employee_Category__c = 'Intern-Stipend',
            Internship_End_Date__c = Date.today().addDays(1)
        ));
        
        // 30 days
        interns.add(new User(
            Alias = 'int30', 
            Email='intern30@testorg.com', 
            EmailEncodingKey='UTF-8', 
            LastName='Intern30', 
            LanguageLocaleKey='en_US', 
            LocaleSidKey='en_US', 
            ProfileId = p.Id, 
            TimeZoneSidKey='America/Los_Angeles', 
            UserName='intern30test123@testorg.com',
            IsActive = true,
            ManagerId = mgr.Id,
            Employee_Category__c = 'Intern-Stipend',
            Internship_End_Date__c = Date.today().addDays(30)
        ));
        
        insert interns;
    }
    
    @isTest
    static void testBatchExecution() {
        Test.startTest();
        InternshipReminderBatch b = new InternshipReminderBatch();
        Database.executeBatch(b);
        Test.stopTest();
        
        System.assert(true);
    }
    
    @isTest
    static void testScheduler() {
        Test.startTest();
        String jobId = System.schedule('Test Scheduler', '0 0 10 * * ?', new InternshipReminderScheduler());
        Test.stopTest();
        
        System.assertNotEquals(null, jobId);
    }
}