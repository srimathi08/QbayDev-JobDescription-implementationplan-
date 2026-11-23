@IsTest
public class EmployeeAttendanceTriggerTest {
    
    @IsTest
    static void testAutoStatusCalculation() {
        // Setup internal user for employee
        User u = [SELECT Id FROM User WHERE IsActive = true LIMIT 1];
        
        // 1. Test Present (9:30 AM)
        DateTime presentTime = DateTime.newInstance(Date.today(), Time.newInstance(9, 30, 0, 0));
        Employee_Attendance__c att1 = new Employee_Attendance__c(
            Employee_Name__c = u.Id,
            Date__c = Date.today(),
            Check_In_Time__c = presentTime
        );
        
        // 2. Test Late (10:15 AM)
        DateTime lateTime = DateTime.newInstance(Date.today(), Time.newInstance(10, 15, 0, 0));
        Employee_Attendance__c att2 = new Employee_Attendance__c(
            Employee_Name__c = u.Id,
            Date__c = Date.today(),
            Check_In_Time__c = lateTime
        );
        
        // 3. Test Manual Override (9:30 AM but manually set to 'Late')
        Employee_Attendance__c att3 = new Employee_Attendance__c(
            Employee_Name__c = u.Id,
            Date__c = Date.today(),
            Check_In_Time__c = presentTime,
            Status__c = 'Late'
        );
        
        Test.startTest();
        insert new List<Employee_Attendance__c>{att1, att2, att3};
        Test.stopTest();
        
        // Verify results
        att1 = [SELECT Status__c FROM Employee_Attendance__c WHERE Id = :att1.Id];
        att2 = [SELECT Status__c FROM Employee_Attendance__c WHERE Id = :att2.Id];
        att3 = [SELECT Status__c FROM Employee_Attendance__c WHERE Id = :att3.Id];
        
        System.assertEquals('Present', att1.Status__c, '9:30 AM should be Present');
        System.assertEquals('Late', att2.Status__c, '10:15 AM should be Late');
        System.assertEquals('Late', att3.Status__c, 'Manual status should not be overridden');
    }
}