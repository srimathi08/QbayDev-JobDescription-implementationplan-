/**
 * Service__c after update: sends optional email-intake and WhatsApp-intake acknowledgements
 * once processing finishes. Handlers never throw, so they cannot block intake updates.
 */
trigger ServiceIntakeTrigger on Service__c (after update) {
    parseEmail.onServiceAfterUpdate(Trigger.new, Trigger.oldMap);
    WhatsAppWebhook.onServiceAfterUpdate(Trigger.new, Trigger.oldMap);
}