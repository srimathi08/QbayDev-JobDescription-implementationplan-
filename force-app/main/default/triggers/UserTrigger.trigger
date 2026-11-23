trigger UserTrigger on User (after insert, after update) {
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            UserTriggerHandler.handleAfterInsert(Trigger.newMap);
        } else if (Trigger.isUpdate) {
            UserTriggerHandler.handleAfterUpdate(Trigger.newMap, Trigger.oldMap);
        }
    }
}