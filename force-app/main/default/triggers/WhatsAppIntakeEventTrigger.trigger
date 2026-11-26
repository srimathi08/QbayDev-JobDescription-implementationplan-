/**
 * Runs under a licensed internal user via PlatformEventSubscriberConfig so
 * IntakeRouter and Einstein Prompt Builder execute outside the Site Guest User context.
 */
trigger WhatsAppIntakeEventTrigger on WhatsApp_Intake_Event__e (after insert) {
    List<Id> serviceIds = new List<Id>();
    for (WhatsApp_Intake_Event__e ev : Trigger.new) {
        if (String.isBlank(ev.Service_Id__c)) continue;
        try {
            serviceIds.add((Id) ev.Service_Id__c);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'WhatsAppIntakeEventTrigger', 'afterInsert');
        }
    }
    if (!serviceIds.isEmpty()) {
        IntakeRouter.start(serviceIds);
    }
}