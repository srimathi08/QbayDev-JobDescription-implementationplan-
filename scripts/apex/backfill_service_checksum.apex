// Back-fill File_Checksum__c on Service__c rows that have none (uploads made before v1, 24-11-2026).
// Only File_Checksum__c is written: no status, type or link fields change, so no acknowledgement
// emails or intake jobs are triggered (ServiceIntakeTrigger only reacts to a Status__c change).
//
// Run:   sf apex run --target-org QbayDevJobdes --file scripts/apex/backfill_service_checksum.apex
// First run with DRY_RUN = true and read the debug log; then set DRY_RUN = false and run again.
// Handles up to 2000 rows per run; rows with no file keep a blank checksum.

Boolean DRY_RUN = true;

List<Service__c> rows = [
    SELECT Id, Name, CreatedDate, Requested_Type__c, Status__c, Account__c, Job_Description__c
    FROM Service__c
    WHERE File_Checksum__c = null
    ORDER BY CreatedDate ASC
    LIMIT 2000
];
Integer remaining = [SELECT COUNT() FROM Service__c WHERE File_Checksum__c = null];
Set<Id> ids = new Map<Id, Service__c>(rows).keySet();

// Latest file per Service__c, same rule as IntakeProcessor.latestFile
Map<Id, Id> docBySvc = new Map<Id, Id>();
if (!ids.isEmpty()) {
    for (ContentDocumentLink l : [
        SELECT LinkedEntityId, ContentDocumentId FROM ContentDocumentLink
        WHERE LinkedEntityId IN :ids ORDER BY SystemModstamp DESC
    ]) {
        if (!docBySvc.containsKey(l.LinkedEntityId)) docBySvc.put(l.LinkedEntityId, l.ContentDocumentId);
    }
}
Map<Id, String> checksumByDoc = new Map<Id, String>();
if (!docBySvc.isEmpty()) {
    for (ContentVersion cv : [
        SELECT ContentDocumentId, Checksum FROM ContentVersion
        WHERE ContentDocumentId IN :docBySvc.values() AND IsLatest = true
    ]) {
        checksumByDoc.put(cv.ContentDocumentId, cv.Checksum);
    }
}

List<Service__c> toUpdate = new List<Service__c>();
Integer noFile = 0;
Integer legacyResume = 0;
Integer legacyJd = 0;
for (Service__c s : rows) {
    Id doc = docBySvc.get(s.Id);
    String cs = doc == null ? null : checksumByDoc.get(doc);
    if (cs == null) { noFile++; continue; }
    if (s.Requested_Type__c == null && s.Account__c != null) legacyResume++;
    if (s.Requested_Type__c == null && s.Job_Description__c != null) legacyJd++;
    toUpdate.add(new Service__c(Id = s.Id, File_Checksum__c = cs));
}

System.debug(LoggingLevel.ERROR, 'BACKFILL dryRun=' + DRY_RUN + ' remaining=' + remaining + ' batch=' + rows.size()
    + ' withFile=' + toUpdate.size() + ' noFile=' + noFile
    + ' legacyLinkedToAccount=' + legacyResume + ' legacyLinkedToJD=' + legacyJd);

if (!DRY_RUN && !toUpdate.isEmpty()) {
    Database.SaveResult[] res = Database.update(toUpdate, false);
    Integer ok = 0;
    for (Database.SaveResult r : res) {
        if (r.isSuccess()) ok++;
        else System.debug(LoggingLevel.ERROR, 'BACKFILL failed ' + r.getId() + ': ' + r.getErrors()[0].getMessage());
    }
    System.debug(LoggingLevel.ERROR, 'BACKFILL updated=' + ok);
}
