/**
 * Service__c after update: sends the optional email-intake acknowledgement once all files
 * of an email are finished. The handler never throws, so it cannot block intake updates.
 */
trigger ServiceIntakeTrigger on Service__c (after update) {
    parseEmail.onServiceAfterUpdate(Trigger.new, Trigger.oldMap);
}