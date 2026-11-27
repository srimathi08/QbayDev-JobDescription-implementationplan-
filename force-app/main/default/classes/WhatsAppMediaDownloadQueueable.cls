/**
 * Downloads one WhatsApp document asynchronously (12 MB async heap/callout limit)
 * so files up to Intake_Setting__mdt.Default.Max_Upload_File_MB__c (10 MB) are
 * validated and attached before handing off to IntakeRouter.
 */
public without sharing class WhatsAppMediaDownloadQueueable implements Queueable, Database.AllowsCallouts {

    private Id serviceId;
    private String mediaId;
    private String fileName;

    public WhatsAppMediaDownloadQueueable(Id serviceId, String mediaId, String fileName) {
        this.serviceId = serviceId;
        this.mediaId = mediaId;
        this.fileName = fileName;
    }

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DownloadFinalizer(serviceId));

        List<Service__c> svcs = [
            SELECT Id, Name, Status__c, File_Checksum__c
            FROM Service__c
            WHERE Id = :serviceId
            LIMIT 1
        ];
        if (svcs.isEmpty() || svcs[0].Status__c != IntakeRouter.STATUS_NEW) return;
        Service__c svc = svcs[0];

        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        Integer maxMb = (cfg.maxUploadFileMb != null && cfg.maxUploadFileMb > 0) ? cfg.maxUploadFileMb : 10;
        Long maxBytes = (Long) maxMb * 1024 * 1024;
        String displayName = String.isNotBlank(fileName) ? fileName : svc.Name;

        WhatsAppUtils.MediaInfo info;
        try {
            info = WhatsAppUtils.fetchMediaInfo(mediaId);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'WhatsAppMediaDownloadQueueable', 'fetchMediaInfo');
            markFailed(svc, 'Could not fetch WhatsApp file metadata: ' + e.getMessage());
            return;
        }

        if (info.fileSize != null) {
            if (info.fileSize <= 0) {
                markRejected(svc, '"' + displayName + '" is empty. Nothing was created.');
                return;
            }
            if (info.fileSize > maxBytes) {
                markRejected(svc, '"' + displayName + '" is larger than ' + maxMb
                    + ' MB. Please send a smaller PDF or DOCX file. Nothing was created.');
                return;
            }
        }

        Blob data;
        try {
            data = WhatsAppUtils.downloadMediaUrl(info.url);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'WhatsAppMediaDownloadQueueable', 'downloadMediaUrl');
            markFailed(svc, 'Could not download WhatsApp file: ' + e.getMessage());
            return;
        }

        if (data == null || data.size() == 0) {
            markRejected(svc, '"' + displayName + '" is empty. Nothing was created.');
            return;
        }
        if (data.size() > maxBytes) {
            data = null;
            markRejected(svc, '"' + displayName + '" is larger than ' + maxMb
                + ' MB. Please send a smaller PDF or DOCX file. Nothing was created.');
            return;
        }

        String title = displayName.contains('.')
            ? displayName.substringBeforeLast('.').left(255)
            : displayName.left(255);
        ContentVersion cv = new ContentVersion(
            Title                  = title,
            PathOnClient           = displayName,
            VersionData            = data,
            FirstPublishLocationId = svc.Id
        );
        data = null; // free heap immediately before DML/query
        insert cv;

        cv = [SELECT Id, Checksum FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        svc.File_Checksum__c = cv.Checksum;
        update svc;

        if (!Test.isRunningTest() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new IntakeRouter(svc.Id));
        }
    }

    private static void markRejected(Service__c svc, String message) {
        svc.Status__c = 'Rejected';
        svc.Detected_Type__c = 'Other';
        svc.Status_Message__c = message == null ? null : message.left(32000);
        update svc;
    }

    private static void markFailed(Service__c svc, String message) {
        svc.Status__c = 'Failed';
        svc.Status_Message__c = message == null ? null : message.left(32000);
        update svc;
    }

    public class DownloadFinalizer implements Finalizer {
        private Id serviceId;
        public DownloadFinalizer(Id serviceId) { this.serviceId = serviceId; }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() == ParentJobResult.SUCCESS) return;
            markUnexpectedFailure(serviceId, ctx.getException());
        }
    }

    @TestVisible
    private static void markUnexpectedFailure(Id serviceId, Exception ex) {
        UtilityClass.createElog(ex, 'WhatsAppMediaDownloadQueueable', 'finalizer');
        List<Service__c> svcs = [SELECT Id, Status__c FROM Service__c WHERE Id = :serviceId LIMIT 1];
        if (svcs.isEmpty() || svcs[0].Status__c != IntakeRouter.STATUS_NEW) return;
        svcs[0].Status__c = 'Failed';
        svcs[0].Status_Message__c = ('Downloading file from WhatsApp stopped unexpectedly'
            + (ex != null ? ': ' + ex.getMessage() : '.') + ' Please send a file within the size limit.').left(32000);
        update svcs[0];
    }
}