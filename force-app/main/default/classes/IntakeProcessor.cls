/**
 * Processes one Service__c intake (one file): same-file check, AI extraction,
 * resume/JD validation, minimum-data check, matching and save.
 * Ends every intake in exactly one final status: Completed, Duplicate, Rejected or Failed.
 */
public without sharing class IntakeProcessor implements Queueable, Database.AllowsCallouts {

    private Id serviceId;

    public IntakeProcessor(Id serviceId) {
        this.serviceId = serviceId;
    }

    /** Thrown for business rejections (wrong file type, not enough data). Not logged as errors. */
    public class RejectException extends Exception {}

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new IntakeFinalizer(serviceId));

        Service__c svc = [
            SELECT Id, Name, Status__c, Requested_Type__c, File_Checksum__c
            FROM Service__c WHERE Id = :serviceId
        ];
        // Only one run per intake: anything not Queued was already handled
        if (svc.Status__c != 'Queued') return;

        ContentVersion file = latestFile(serviceId);
        if (file == null) {
            finish(svc, 'Failed', 'No file was found on this upload.', null);
            return;
        }

        // 1. Same file already processed successfully for the same purpose
        Service__c earlier = findEarlierSameFile(svc);
        if (earlier != null) {
            svc.Account__c = earlier.Account__c;
            svc.Opportunity__c = earlier.Opportunity__c;
            svc.Job_Description__c = earlier.Job_Description__c;
            finish(svc, 'Duplicate', 'This exact file was already uploaded on '
                + earlier.CreatedDate.format('dd MMM yyyy HH:mm') + '. No new records were created.', null);
            return;
        }

        // 2. AI extraction (callout happens before any DML in this transaction)
        String aiJson;
        try {
            aiJson = svc.Requested_Type__c == IntakeController.TYPE_JD
                ? JobDescriptionCreationPrompt.generate(svc.Id)
                : CandidateCreationPrompt.generate(file.ContentDocumentId);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'IntakeProcessor', 'generate');
            finish(svc, 'Failed', 'The AI service could not read the file: ' + e.getMessage(), null);
            return;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // 3. Resume vs JD validation, minimum data, matching and save
            if (svc.Requested_Type__c == IntakeController.TYPE_JD) {
                JobDescriptionCreationController.Result r =
                    JobDescriptionCreationController.process(aiJson, svc.Id, true);
                svc.Detected_Type__c = 'Job Description';
                svc.Account__c = r.accountId;
                svc.Opportunity__c = r.opportunityId;
                svc.Job_Description__c = r.jobDescriptionId;
                finish(svc, 'Completed', r.summary, aiJson);
            } else {
                CandidateCreationController.Result r =
                    CandidateCreationController.process(aiJson, file.ContentDocumentId, svc.Id, true);
                svc.Detected_Type__c = 'Resume';
                svc.Account__c = r.primaryAccountId;
                finish(svc, 'Completed', r.summary, aiJson);
            }
        } catch (RejectException rej) {
            Database.rollback(sp);
            svc.Detected_Type__c = detectedTypeFrom(aiJson);
            finish(svc, 'Rejected', rej.getMessage(), aiJson);
        } catch (Exception e) {
            Database.rollback(sp);
            UtilityClass.createElog(e, 'IntakeProcessor', 'execute');
            finish(svc, 'Failed', 'Could not save the records: ' + e.getMessage(), aiJson);
        }
    }

    // ---------------- helpers ----------------

    private static void finish(Service__c svc, String status, String message, String aiJson) {
        svc.Status__c = status;
        svc.Status_Message__c = message == null ? null : message.left(32000);
        if (aiJson != null) svc.AI_Response__c = aiJson.left(131000);
        update svc;
    }

    public static ContentVersion latestFile(Id serviceId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :serviceId ORDER BY SystemModstamp DESC LIMIT 1
        ];
        if (links.isEmpty()) return null;
        List<ContentVersion> cvs = [
            SELECT Id, ContentDocumentId, Title, FileExtension, Checksum, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId = :links[0].ContentDocumentId AND IsLatest = true LIMIT 1
        ];
        return cvs.isEmpty() ? null : cvs[0];
    }

    private static Service__c findEarlierSameFile(Service__c svc) {
        if (String.isBlank(svc.File_Checksum__c)) return null;
        List<Service__c> prev = [
            SELECT Id, CreatedDate, Account__c, Opportunity__c, Job_Description__c
            FROM Service__c
            WHERE File_Checksum__c = :svc.File_Checksum__c
              AND Requested_Type__c = :svc.Requested_Type__c
              AND Status__c IN ('Completed', 'Duplicate')
              AND Id != :svc.Id
            ORDER BY CreatedDate ASC LIMIT 1
        ];
        return prev.isEmpty() ? null : prev[0];
    }

    public static String detectedTypeFrom(String aiJson) {
        String t = AiJson.documentType(aiJson);
        if (t == 'Resume' || t == 'Job Description') return t;
        return 'Other';
    }

    /** Marks the intake Failed if the job died with an uncatchable error (limits, timeouts). */
    public class IntakeFinalizer implements Finalizer {
        private Id serviceId;
        public IntakeFinalizer(Id serviceId) { this.serviceId = serviceId; }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() == ParentJobResult.SUCCESS) return;
            List<Service__c> svcs = [SELECT Id, Status__c FROM Service__c WHERE Id = :serviceId];
            if (svcs.isEmpty()) return;
            Exception ex = ctx.getException();
            UtilityClass.createElog(ex, 'IntakeProcessor', 'finalizer');
            if (svcs[0].Status__c == 'Queued' || svcs[0].Status__c == 'Processing') {
                svcs[0].Status__c = 'Failed';
                svcs[0].Status_Message__c = 'Processing stopped unexpectedly'
                    + (ex != null ? ': ' + ex.getMessage() : '.') + ' Please try again.';
                update svcs[0];
            }
        }
    }
}
