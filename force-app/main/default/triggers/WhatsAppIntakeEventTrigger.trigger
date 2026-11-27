/**
 * Runs under a licensed internal user via PlatformEventSubscriberConfig so
 * WhatsApp media download, IntakeRouter, and Einstein Prompt Builder execute
 * outside the Site Guest User context (and with 12 MB async heap/callout limits).
 */
trigger WhatsAppIntakeEventTrigger on WhatsApp_Intake_Event__e (after insert) {
    List<Id> routeNowIds = new List<Id>();
    for (WhatsApp_Intake_Event__e ev : Trigger.new) {
        if (String.isBlank(ev.Service_Id__c)) continue;
        Id serviceId;
        try {
            serviceId = (Id) ev.Service_Id__c;
        } catch (Exception e) {
            UtilityClass.createElog(e, 'WhatsAppIntakeEventTrigger', 'afterInsert');
            continue;
        }

        if (String.isNotBlank(ev.Media_Id__c)) {
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new WhatsAppMediaDownloadQueueable(serviceId, ev.Media_Id__c, ev.File_Name__c));
            }
        } else {
            routeNowIds.add(serviceId);
        }
    }
    if (!routeNowIds.isEmpty()) {
        IntakeRouter.start(routeNowIds);
    }
}