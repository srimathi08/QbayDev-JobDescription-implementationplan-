public class UtilityClass {

    /** Kept for existing callers. */
    public static void createElog(Exception e) {
        createElog(e, null, null);
    }

    /**
     * Logs an error to Error_Log__c through a platform event that is published immediately,
     * so the log is kept even when the caller then throws and its transaction rolls back.
     */
    public static void createElog(Exception e, String className, String methodName) {
        try {
            Error_Log_Event__e ev = new Error_Log_Event__e(
                Class_Name__c = className == null ? null : className.left(255),
                Method_Name__c = methodName == null ? null : methodName.left(255),
                Error_Message__c = e == null ? 'Unknown error' : (e.getTypeName() + ': ' + e.getMessage()).left(32000),
                Stack_Trace__c = e == null ? null : e.getStackTraceString().left(32000)
            );
            EventBus.publish(ev);
        } catch (Exception ignore) {
            System.debug(LoggingLevel.ERROR, 'Could not log error: ' + ignore.getMessage());
        }
    }

    /** Called by ErrorLogEventTrigger. */
    public static void saveLogs(List<Error_Log_Event__e> events) {
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Error_Log__c.fields.getMap();
        List<Error_Log__c> logs = new List<Error_Log__c>();
        for (Error_Log_Event__e ev : events) {
            Error_Log__c l = new Error_Log__c();
            l.Error_Message__c = fit(ev.Error_Message__c, fields.get('Error_Message__c'));
            l.Stack_Trace__c = fit(ev.Stack_Trace__c, fields.get('Stack_Trace__c'));
            l.Class_Name__c = fit(ev.Class_Name__c, fields.get('Class_Name__c'));
            l.Method_Name__c = fit(ev.Method_Name__c, fields.get('Method_Name__c'));
            logs.add(l);
        }
        insert logs;
    }

    private static String fit(String v, Schema.SObjectField f) {
        if (v == null || f == null) return v;
        Integer len = f.getDescribe().getLength();
        return len > 0 ? v.left(len) : v;
    }
}
