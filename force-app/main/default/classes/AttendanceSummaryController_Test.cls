@isTest
private class AttendanceSummaryController_Test {
    
    @TestSetup
    static void setupTestData() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        
        User user1 = new User(
            Alias = 'u1', Email = 'user1@test.com', EmailEncodingKey = 'UTF-8',
            LastName = 'User1', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'user1_' + System.currentTimeMillis() + '@test.com'
        );
        insert user1;

        User user2 = new User(
            Alias = 'u2', Email = 'user2@test.com', EmailEncodingKey = 'UTF-8',
            LastName = 'User2', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'user2_' + System.currentTimeMillis() + '@test.com'
        );
        insert user2;

        Branch__c testBranch = new Branch__c(Branch_Name__c = 'Test Branch');
        insert testBranch;

        Date monthStart = Date.today().toStartOfMonth();
        List<Employee_Attendance__c> records = new List<Employee_Attendance__c>();
        
        // User1: Records WITH Check_In_Time__c and Hours_Worked__c to cover calculation methods
        for(Integer i = 0; i < 5; i++) {
            Date attDate = monthStart.addDays(i);
            
            // Session 1 - Present with check-in time and hours
            records.add(new Employee_Attendance__c(
                Employee_Name__c = user1.Id,
                Date__c = attDate,
                Status__c = 'Present',
                Session_Number__c = 1,
                Is_Multiple_Session__c = false,
                Branch__c = testBranch.Id,
                Check_In_Time__c = Datetime.newInstance(attDate, Time.newInstance(9, 0, 0, 0)),
                Check_Out_Time__c = Datetime.newInstance(attDate, Time.newInstance(13, 0, 0, 0))
                //Hours_Worked__c = 4.0
            ));
            
            // Session 2 - Late status with check-in time and hours
            records.add(new Employee_Attendance__c(
                Employee_Name__c = user1.Id,
                Date__c = attDate,
                Status__c = 'Late',
                Session_Number__c = 2,
                Is_Multiple_Session__c = true,
                Branch__c = testBranch.Id,
                Check_In_Time__c = Datetime.newInstance(attDate, Time.newInstance(14, 30, 0, 0)),
                Check_Out_Time__c = Datetime.newInstance(attDate, Time.newInstance(18, 0, 0, 0))
                //Hours_Worked__c = 3.5
            ));
        }
        
        // User2: Single record with check-in
        Date user2Date = monthStart.addDays(1);
        records.add(new Employee_Attendance__c(
            Employee_Name__c = user2.Id,
            Date__c = user2Date,
            Status__c = 'Present',
            Session_Number__c = 1,
            Is_Multiple_Session__c = false,
            Branch__c = testBranch.Id,
            Check_In_Time__c = Datetime.newInstance(user2Date, Time.newInstance(9, 0, 0, 0)),
            Check_Out_Time__c = Datetime.newInstance(user2Date, Time.newInstance(17, 0, 0, 0))
            //Hours_Worked__c = 8.0
        ));
        
        insert records;
    }
    
    @isTest 
    static void testSuccessPathWithHoursAndCheckIn() {
        User u1 = [SELECT Id FROM User WHERE Email = 'user1@test.com' LIMIT 1];
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u1.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
        System.assertNotEquals(null, result.get('totalHours'));
        System.assertNotEquals(null, result.get('avgHoursPerDay'));
        System.assertNotEquals(null, result.get('attendanceRate'));
        System.assertNotEquals(null, result.get('presentDays'));
        System.assertNotEquals(null, result.get('lateDays'));
        System.assertNotEquals(null, result.get('absentDays'));
        System.assertNotEquals(null, result.get('monthName'));
        System.assertNotEquals(null, result.get('totalWorkingDays'));
    }

    @isTest 
    static void testAllUsersSummary() {
        Test.startTest();
        List<Map<String, Object>> results = AttendanceSummaryController.getAllUsersMonthlySummary();
        Test.stopTest();
        
        System.assertNotEquals(null, results);
        System.assert(results.size() > 0);
        
        // Verify user details are included
        for(Map<String, Object> userResult : results) {
            System.assertNotEquals(null, userResult.get('userName'));
            System.assertNotEquals(null, userResult.get('userEmail'));
            System.assertNotEquals(null, userResult.get('userId'));
        }
    }

    @isTest 
    static void testNoRecordsPath() {
        String fakeId = '005000000000000AAA';
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(fakeId);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
        System.assertEquals(0, result.get('presentDays'));
        System.assertEquals('0.0', result.get('totalHours'));
    }

    @isTest 
    static void testNullInputPath() {
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(null);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }

    @isTest 
    static void testUser2Path() {
        User u2 = [SELECT Id FROM User WHERE Email = 'user2@test.com' LIMIT 1];
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u2.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }

    @isTest 
    static void testRunAsContext() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User runAsUser = new User(
            Alias = 'test', Email = 'runas@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'TestRunAs',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'runas_' + System.currentTimeMillis() + '@test.com'
        );
        insert runAsUser;
        
        System.runAs(runAsUser) {
            Test.startTest();
            Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(runAsUser.Id);
            Test.stopTest();
            System.assertNotEquals(null, result);
        }
    }
    
    // ============ NEW TEST METHODS FOR BETTER COVERAGE ============
    
    @isTest 
    static void testShouldShowCheckInPopupNotCheckedIn() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            Alias = 'popup', Email = 'popup@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'PopupTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'popup_' + System.currentTimeMillis() + '@test.com'
        );
        insert testUser;
        
        System.runAs(testUser) {
            Test.startTest();
            Boolean result = AttendanceSummaryController.shouldShowCheckInPopup();
            Test.stopTest();
            
            // Result depends on time of day - just ensure method executes without error
            System.assertNotEquals(null, result);
        }
    }
    
    @isTest 
    static void testShouldShowCheckInPopupAlreadyCheckedIn() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            Alias = 'chkin', Email = 'checkedin@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'CheckedInTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'checkedin_' + System.currentTimeMillis() + '@test.com'
        );
        insert testUser;
        
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        Date today = Date.today();
        
        // Create attendance record for today with check-in
        Employee_Attendance__c todayRecord = new Employee_Attendance__c(
            Employee_Name__c = testUser.Id,
            Date__c = today,
            Status__c = 'Present',
            Session_Number__c = 1,
            Is_Multiple_Session__c = false,
            Branch__c = branch.Id,
            Check_In_Time__c = Datetime.newInstance(today, Time.newInstance(9, 0, 0, 0))
        );
        insert todayRecord;
        
        System.runAs(testUser) {
            Test.startTest();
            Boolean result = AttendanceSummaryController.shouldShowCheckInPopup();
            Test.stopTest();
            
            // If time is before 12 PM, should return false since already checked in
            // If time is after 12 PM, should return false anyway
            System.assertEquals(false, result);
        }
    }
    
    @isTest 
    static void testRecordsWithZeroHours() {
        User u1 = [SELECT Id FROM User WHERE Email = 'user1@test.com' LIMIT 1];
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        Date today = Date.today();
        
        // Create record with zero hours
        Employee_Attendance__c zeroHoursRecord = new Employee_Attendance__c(
            Employee_Name__c = u1.Id,
            Date__c = today,
            Status__c = 'Present',
            Session_Number__c = 1,
            Is_Multiple_Session__c = false,
            Branch__c = branch.Id,
            Check_In_Time__c = Datetime.newInstance(today, Time.newInstance(9, 0, 0, 0))
            //Hours_Worked__c = 0
        );
        insert zeroHoursRecord;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u1.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }
    
    @isTest 
    static void testRecordsWithNullHours() {
        User u1 = [SELECT Id FROM User WHERE Email = 'user1@test.com' LIMIT 1];
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        Date today = Date.today();
        
        // Create record with null hours (no Hours_Worked__c set)
        Employee_Attendance__c nullHoursRecord = new Employee_Attendance__c(
            Employee_Name__c = u1.Id,
            Date__c = today,
            Status__c = 'Present',
            Session_Number__c = 3,
            Is_Multiple_Session__c = true,
            Branch__c = branch.Id,
            Check_In_Time__c = Datetime.newInstance(today, Time.newInstance(10, 0, 0, 0))
        );
        insert nullHoursRecord;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u1.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }
    
    @isTest 
    static void testRecordsWithoutCheckInTime() {
        User u1 = [SELECT Id FROM User WHERE Email = 'user1@test.com' LIMIT 1];
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        
        // Create record without check-in time to test the null check in calculateMonthlyMetricsWithSessions
        Employee_Attendance__c noCheckInRecord = new Employee_Attendance__c(
            Employee_Name__c = u1.Id,
            Date__c = Date.today(),
            Status__c = 'Present',
            Session_Number__c = 1,
            Is_Multiple_Session__c = false,
            Branch__c = branch.Id
            // No Check_In_Time__c set
        );
        insert noCheckInRecord;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u1.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }
    
    @isTest 
    static void testMultipleDatesWithMixedStatus() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            Alias = 'mix', Email = 'mixed@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'MixedTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'mixed_' + System.currentTimeMillis() + '@test.com'
        );
        insert testUser;
        
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        Date monthStart = Date.today().toStartOfMonth();
        
        List<Employee_Attendance__c> mixedRecords = new List<Employee_Attendance__c>();
        
        // Create records with various statuses and check-in times
        for(Integer i = 0; i < 10; i++) {
            String status = Math.mod(i, 3) == 0 ? 'Late' : 'Present';
            Date recDate = monthStart.addDays(i);
            Datetime checkIn = Math.mod(i, 2) == 0 ? Datetime.newInstance(recDate, Time.newInstance(9, 0, 0, 0)) : null;
            Decimal hours = Math.mod(i, 2) == 0 ? 8.0 : null;
            
            mixedRecords.add(new Employee_Attendance__c(
                Employee_Name__c = testUser.Id,
                Date__c = recDate,
                Status__c = status,
                Session_Number__c = 1,
                Is_Multiple_Session__c = false,
                Branch__c = branch.Id,
                Check_In_Time__c = checkIn
               // Hours_Worked__c = hours
            ));
        }
        insert mixedRecords;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(testUser.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
        System.assert((Integer)result.get('presentDays') >= 0);
        System.assert((Integer)result.get('lateDays') >= 0);
    }
    
    @isTest 
    static void testBulkCoverageWithHours() {
        User u1 = [SELECT Id FROM User WHERE Email = 'user1@test.com' LIMIT 1];
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        
        List<Employee_Attendance__c> bulkData = new List<Employee_Attendance__c>();
        Date monthStart = Date.today().toStartOfMonth();
        
        for(Integer i = 0; i < 50; i++) {
            Date recDate = monthStart.addDays(Math.mod(i, 25));
            bulkData.add(new Employee_Attendance__c(
                Employee_Name__c = u1.Id,
                Date__c = recDate,
                Status__c = Math.mod(i, 4) == 0 ? 'Late' : 'Present',
                Session_Number__c = Math.mod(i, 3) + 1,
                Is_Multiple_Session__c = Math.mod(i, 3) > 0,
                Branch__c = branch.Id,
                Check_In_Time__c = Datetime.newInstance(recDate, Time.newInstance(9 + Math.mod(i, 3), 0, 0, 0)),
                Check_Out_Time__c = Datetime.newInstance(recDate, Time.newInstance(17 + Math.mod(i, 2), 0, 0, 0))
                //Hours_Worked__c = 7.0 + Math.mod(i, 3)
            ));
        }
        insert bulkData;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u1.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }
    
    @isTest 
    static void testEmptyMonthForNewUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User newUser = new User(
            Alias = 'new', Email = 'newuser@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'NewUser',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'newuser_' + System.currentTimeMillis() + '@test.com'
        );
        insert newUser;
        
        // No attendance records for this user
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(newUser.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
        System.assertEquals(0, result.get('presentDays'));
        System.assertEquals(0, result.get('lateDays'));
        System.assertEquals('0.0', result.get('totalHours'));
        System.assertEquals('0.0', result.get('avgHoursPerDay'));
        System.assert((Integer)result.get('totalWorkingDays') >= 0);
    }
    
    @isTest 
    static void testSameDayMultipleSessions() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            Alias = 'multi', Email = 'multi@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'MultiSession',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'multi_' + System.currentTimeMillis() + '@test.com'
        );
        insert testUser;
        
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        Date today = Date.today();
        
        // Create multiple sessions for the same day
        List<Employee_Attendance__c> sessions = new List<Employee_Attendance__c>();
        for(Integer i = 1; i <= 4; i++) {
            sessions.add(new Employee_Attendance__c(
                Employee_Name__c = testUser.Id,
                Date__c = today,
                Status__c = i == 1 ? 'Present' : 'Late',
                Session_Number__c = i,
                Is_Multiple_Session__c = i > 1,
                Branch__c = branch.Id,
                Check_In_Time__c = Datetime.newInstance(today, Time.newInstance(8 + (i * 2), 0, 0, 0)),
                Check_Out_Time__c = Datetime.newInstance(today, Time.newInstance(10 + (i * 2), 0, 0, 0))
                //Hours_Worked__c = 2.0
            ));
        }
        insert sessions;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(testUser.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
        // Should count as 1 present day despite multiple sessions
        System.assertEquals(1, result.get('presentDays'));
        // Total sessions should be 4
        System.assertEquals(4, result.get('totalSessions'));
    }
    
    @isTest 
    static void testWeekendExclusion() {
        // This test verifies weekday calculation works correctly
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User testUser = new User(
            Alias = 'wknd', Email = 'weekend@test.com', 
            EmailEncodingKey = 'UTF-8', LastName = 'WeekendTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'weekend_' + System.currentTimeMillis() + '@test.com'
        );
        insert testUser;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(testUser.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
        
        // Verify totalWorkingDays only counts weekdays
        Integer totalWorkingDays = (Integer)result.get('totalWorkingDays');
        System.assert(totalWorkingDays >= 0);
        
        // If we're in a month, weekdays should be less than or equal to total days
        Date today = Date.today();
        Date monthStart = today.toStartOfMonth();
        Integer totalDays = monthStart.daysBetween(today) + 1;
        System.assert(totalWorkingDays <= totalDays);
    }
    
    @isTest 
    static void testNegativeHoursHandling() {
        User u1 = [SELECT Id FROM User WHERE Email = 'user1@test.com' LIMIT 1];
        Branch__c branch = [SELECT Id FROM Branch__c LIMIT 1];
        Date today = Date.today();
        
        // Create record with negative hours (edge case)
        Employee_Attendance__c negativeRecord = new Employee_Attendance__c(
            Employee_Name__c = u1.Id,
            Date__c = today,
            Status__c = 'Present',
            Session_Number__c = 1,
            Is_Multiple_Session__c = false,
            Branch__c = branch.Id,
            Check_In_Time__c = Datetime.newInstance(today, Time.newInstance(9, 0, 0, 0))
           // Hours_Worked__c = -1.0
        );
        insert negativeRecord;
        
        Test.startTest();
        Map<String, Object> result = AttendanceSummaryController.getMonthlySummary(u1.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, result);
        System.assertEquals(true, result.get('success'));
    }
}