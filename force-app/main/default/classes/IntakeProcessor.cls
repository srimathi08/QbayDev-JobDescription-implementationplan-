/**
 * Processes one Service__c intake (one file): same-file check, AI extraction,
 * resume/JD validation, minimum-data check, matching and save.
 * Ends every intake in exactly one status: Completed, Duplicate, Rejected, Failed,
 * or (Qbay Home uploads only) Needs Review.
 *
 * Requested_Type__c blank = "Auto" upload: the resume prompt runs first; when it says the file is a
 * Job Description, the JD prompt runs instead.
 * Upload_Batch__c set = files of one upload are processed one after another (the finalizer starts
 * the next one), so two resumes of the same person in one upload cannot both create a candidate.
 */
public without sharing class IntakeProcessor implements Queueable, Database.AllowsCallouts {

    private Id serviceId;
    private Boolean startNext = true;

    public IntakeProcessor(Id serviceId) {
        this.serviceId = serviceId;
    }

    /** startNext = false: a single retried file, which must not start a second chain next to a running one. */
    public IntakeProcessor(Id serviceId, Boolean startNext) {
        this.serviceId = serviceId;
        this.startNext = startNext != false;
    }

    /** Thrown for business rejections (wrong file type, not enough data). Not logged as errors. */
    public class RejectException extends Exception {}

    /** The candidate already exists: nothing is created and the upload is linked to that Account. */
    public class DuplicateException extends Exception {
        public Id accountId;
    }

    /** A name was found but no email, phone or LinkedIn. Qbay Home uploads wait for the recruiter. */
    public class NeedsReviewException extends Exception {
        public String candidateName;
    }

    /** A JD with the same role as an open Opportunity of the client but other text (T-071). Qbay Home uploads only. */
    public class PossibleDuplicateJdException extends Exception {
        public Id opportunityId;
        public Id accountId;
    }

    public static final String CHANNEL_UI = 'UI Upload';
    public static final String STATUS_NEEDS_REVIEW = 'Needs Review';

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new IntakeFinalizer(serviceId, startNext));

        Service__c svc = [
            SELECT Id, Name, Status__c, Requested_Type__c, File_Checksum__c, Source_Channel__c
            FROM Service__c WHERE Id = :serviceId
        ];
        Boolean auto = String.isBlank(svc.Requested_Type__c);
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
            if (auto) {
                // keep what the earlier upload was, so a JD duplicate is shown as a JD (never "attach resume")
                svc.Requested_Type__c = earlier.Requested_Type__c;
                svc.Detected_Type__c = earlier.Detected_Type__c;
            }
            finish(svc, 'Duplicate', 'This exact file was already uploaded on '
                + earlier.CreatedDate.format('dd MMM yyyy HH:mm') + '. No new records were created.', null);
            return;
        }

        // 1b. Same file already waiting in Needs Review (Qbay Home upload): finish that one, do not ask twice
        if (svc.Source_Channel__c == CHANNEL_UI && String.isNotBlank(svc.File_Checksum__c)) {
            List<Service__c> waiting = [
                SELECT Id, Status__c, CreatedDate, Account__c, Opportunity__c FROM Service__c
                WHERE File_Checksum__c = :svc.File_Checksum__c AND Source_Channel__c = :CHANNEL_UI
                  AND Status__c = :STATUS_NEEDS_REVIEW AND Id != :svc.Id
                ORDER BY CreatedDate ASC LIMIT 1
            ];
            if (!waiting.isEmpty()) {
                svc.Opportunity__c = waiting[0].Opportunity__c;
                finish(svc, 'Duplicate', IntakeController.pendingText(waiting[0]) + ' No new records were created.', null);
                return;
            }
        }

        // 2. AI extraction (callout happens before any DML in this transaction)
        String rawJson;
        String type = svc.Requested_Type__c;
        try {
            if (type == IntakeController.TYPE_JD) {
                rawJson = JobDescriptionCreationPrompt.generate(svc.Id);
            } else {
                rawJson = CandidateCreationPrompt.generate(file.ContentDocumentId);
                if (auto) {
                    String dt = AiJson.documentType(rawJson);
                    if (dt == IntakeController.TYPE_JD) {
                        type = IntakeController.TYPE_JD;
                        rawJson = JobDescriptionCreationPrompt.generate(svc.Id);
                    } else if (dt == 'Other' || !hasAnyCandidateData(rawJson)) {
                        // "Resume" with no name and no contact at all (e.g. a project document): not a resume
                        type = null;
                    } else {
                        type = IntakeController.TYPE_RESUME;
                    }
                }
            }
        } catch (Exception e) {
            UtilityClass.createElog(e, 'IntakeProcessor', 'generate');
            finish(svc, 'Failed', 'The AI service could not read the file: ' + e.getMessage(), null);
            return;
        }
        if (auto) {
            if (type == null) {
                svc.Detected_Type__c = 'Other';
                finish(svc, 'Rejected', 'This file does not look like a resume or a job description. Nothing was created.', rawJson);
                return;
            }
            svc.Requested_Type__c = type;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // 3. Resume vs JD validation, minimum data, matching and save
            if (svc.Requested_Type__c == IntakeController.TYPE_JD) {
                JobDescriptionCreationController.Result r =
                    JobDescriptionCreationController.process(rawJson, svc.Id, true);
                svc.Detected_Type__c = 'Job Description';
                svc.Account__c = r.accountId;
                svc.Opportunity__c = r.opportunityId;
                svc.Job_Description__c = r.jobDescriptionId;
                finish(svc, 'Completed', r.summary, rawJson);
            } else {
                CandidateCreationController.Result r =
                    CandidateCreationController.process(rawJson, file.ContentDocumentId, svc.Id, true);
                svc.Detected_Type__c = 'Resume';
                svc.Account__c = r.primaryAccountId;
                finish(svc, 'Completed', r.summary, rawJson);
            }
        } catch (PossibleDuplicateJdException pd) {
            Database.rollback(sp);
            // The recruiter decides in the inbox: Use existing Opportunity / Create new Opportunity
            svc.Detected_Type__c = 'Job Description';
            svc.Requested_Type__c = IntakeController.TYPE_JD;
            svc.Account__c = pd.accountId;
            svc.Opportunity__c = pd.opportunityId;
            finish(svc, STATUS_NEEDS_REVIEW, pd.getMessage(), rawJson);
        } catch (NeedsReviewException nr) {
            Database.rollback(sp);
            svc.Detected_Type__c = 'Resume';
            if (svc.Source_Channel__c == CHANNEL_UI) {
                finish(svc, STATUS_NEEDS_REVIEW, reviewMessage(nr.candidateName), rawJson);
            } else {
                finish(svc, 'Rejected', nr.getMessage(), rawJson);
            }
        } catch (DuplicateException dup) {
            Database.rollback(sp);
            svc.Detected_Type__c = detectedTypeFrom(rawJson);
            svc.Account__c = dup.accountId;
            finish(svc, 'Duplicate', dup.getMessage(), rawJson);
        } catch (RejectException rej) {
            Database.rollback(sp);
            svc.Detected_Type__c = rej.getMessage() == JobDescriptionCreationController.NOT_A_JD_MESSAGE
                ? 'Other' : detectedTypeFrom(rawJson);
            finish(svc, 'Rejected', rej.getMessage(), rawJson);
        } catch (Exception e) {
            Database.rollback(sp);
            UtilityClass.createElog(e, 'IntakeProcessor', 'execute');
            finish(svc, 'Failed', 'Could not save the records: ' + e.getMessage(), rawJson);
        }
    }

    // ---------------- helpers ----------------

    public static String reviewMessage(String name) {
        return 'Found the name "' + name + '" but no email, phone number or LinkedIn profile in this file '
            + '(they may be inside an image). Type at least one of them and click Continue to create the candidate.';
    }

    @TestVisible private static Id lastChainedId;

    /** Starts the next queued file of the same upload, if any. Called by the finalizer after every run. */
    public static void startNextInBatch(Id serviceId) {
        List<Service__c> cur = [SELECT Upload_Batch__c FROM Service__c WHERE Id = :serviceId];
        if (cur.isEmpty() || String.isBlank(cur[0].Upload_Batch__c)) return;
        List<Service__c> next = [
            SELECT Id FROM Service__c
            WHERE Upload_Batch__c = :cur[0].Upload_Batch__c AND Status__c = 'Queued' AND Id != :serviceId
            ORDER BY CreatedDate ASC, Name ASC LIMIT 1
        ];
        if (next.isEmpty()) return;
        lastChainedId = next[0].Id;
        if (!Test.isRunningTest()) System.enqueueJob(new IntakeProcessor(next[0].Id));
    }

    private static void finish(Service__c svc, String status, String message, String rawJson) {
        svc.Status__c = status;
        svc.Status_Message__c = message == null ? null : message.left(32000);
        if (rawJson != null) svc.AI_Response__c = rawJson.left(131000);
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

    /** True when at least one resume in the AI JSON has a name, email, phone or LinkedIn. */
    @TestVisible
    private static Boolean hasAnyCandidateData(String rawJson) {
        Map<String, Object> parsed = AiJson.parse(rawJson);
        if (parsed == null) return false;
        List<Map<String, Object>> resumes = AiJson.objList(parsed, 'resumes');
        if (resumes.isEmpty() && parsed.containsKey('account')) resumes.add(parsed);
        for (Map<String, Object> r : resumes) {
            Map<String, Object> acc = AiJson.obj(r, 'account');
            if (acc == null) continue;
            for (String k : new List<String>{ 'name', 'firstName', 'lastName', 'email', 'phone', 'linkedin' }) {
                if (AiJson.str(acc, k) != null) return true;
            }
        }
        return false;
    }

    private static Service__c findEarlierSameFile(Service__c svc) {
        if (String.isBlank(svc.File_Checksum__c)) return null;
        List<Service__c> prev = String.isBlank(svc.Requested_Type__c)
            ? [
                SELECT Id, CreatedDate, Account__c, Opportunity__c, Job_Description__c, Requested_Type__c, Detected_Type__c
                FROM Service__c
                WHERE File_Checksum__c = :svc.File_Checksum__c
                  AND Requested_Type__c != null
                  AND Status__c IN ('Completed', 'Duplicate')
                  AND Id != :svc.Id
                ORDER BY CreatedDate ASC LIMIT 1
            ]
            : [
                SELECT Id, CreatedDate, Account__c, Opportunity__c, Job_Description__c, Requested_Type__c, Detected_Type__c
                FROM Service__c
                WHERE File_Checksum__c = :svc.File_Checksum__c
                  AND Requested_Type__c = :svc.Requested_Type__c
                  AND Status__c IN ('Completed', 'Duplicate')
                  AND Id != :svc.Id
                ORDER BY CreatedDate ASC LIMIT 1
            ];
        if (!prev.isEmpty()) return prev[0];
        return findLegacySameFile(svc);
    }

    /**
     * Uploads made before the v1 intake (24-11-2026) have no Requested_Type__c or Status__c.
     * They count as the same upload when they created a record of the same kind.
     */
    private static Service__c findLegacySameFile(Service__c svc) {
        List<Service__c> prev;
        if (svc.Requested_Type__c == IntakeController.TYPE_JD) {
            prev = [
                SELECT Id, CreatedDate, Account__c, Opportunity__c, Job_Description__c, Requested_Type__c, Detected_Type__c
                FROM Service__c
                WHERE File_Checksum__c = :svc.File_Checksum__c
                  AND Requested_Type__c = null AND Job_Description__c != null
                  AND Id != :svc.Id
                ORDER BY CreatedDate ASC LIMIT 1
            ];
        } else {
            Id candidateRt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
            prev = [
                SELECT Id, CreatedDate, Account__c, Opportunity__c, Job_Description__c, Requested_Type__c, Detected_Type__c
                FROM Service__c
                WHERE File_Checksum__c = :svc.File_Checksum__c
                  AND Requested_Type__c = null AND Account__c != null
                  AND Account__r.RecordTypeId = :candidateRt
                  AND Id != :svc.Id
                ORDER BY CreatedDate ASC LIMIT 1
            ];
        }
        return prev.isEmpty() ? null : prev[0];
    }

    public static String detectedTypeFrom(String rawJson) {
        String t = AiJson.documentType(rawJson);
        if (t == 'Resume' || t == 'Job Description') return t;
        return 'Other';
    }

    /**
     * Marks the intake Failed if the job died with an uncatchable error (limits, timeouts),
     * then starts the next file of the same upload (one file at a time per upload).
     */
    public class IntakeFinalizer implements Finalizer {
        private Id serviceId;
        private Boolean startNext = true;
        public IntakeFinalizer(Id serviceId) { this.serviceId = serviceId; }
        public IntakeFinalizer(Id serviceId, Boolean startNext) {
            this.serviceId = serviceId;
            this.startNext = startNext != false;
        }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() != ParentJobResult.SUCCESS) {
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
            if (!startNext) return;
            try {
                startNextInBatch(serviceId);
            } catch (Exception e) {
                UtilityClass.createElog(e, 'IntakeProcessor', 'startNextInBatch');
            }
        }
    }
}