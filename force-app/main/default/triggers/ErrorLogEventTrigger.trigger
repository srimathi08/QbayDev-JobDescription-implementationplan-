trigger ErrorLogEventTrigger on Error_Log_Event__e (after insert) {
    UtilityClass.saveLogs(Trigger.new);
}