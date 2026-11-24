@IsTest
private class UtilityClassLogTest {
    @IsTest
    static void logSurvivesAndIsSaved() {
        Test.startTest();
        try {
            Integer x = 1 / 0;
        } catch (Exception e) {
            UtilityClass.createElog(e, 'UtilityClassLogTest', 'logSurvivesAndIsSaved');
            UtilityClass.createElog(e);
        }
        Test.stopTest();
        Test.getEventBus().deliver();
        List<Error_Log__c> logs = [SELECT Class_Name__c, Error_Message__c FROM Error_Log__c];
        Assert.areEqual(2, logs.size());
    }
}
