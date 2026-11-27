/**
 * Shared intake step for channels where the document type is not known up front
 * (email today, WhatsApp later). One class, four parts:
 *
 * 1. Router (Queueable)   - for ONE Service__c (one file): identifies the file as Resume / Job Description /
 *                           Other from its content, then hands resumes and JDs to IntakeProcessor
 *                           (the same engine the Qbay Home uploaders use).
 * 2. Classifier           - classify(): calls the Intake_Document_Classifier prompt template with the file.
 * 3. Retry job (inner class RetryJob, Schedulable, hourly) - retries Failed records and restarts stuck ones, only for the
 *                           channels listed in Intake_Setting__mdt.Default.Retry_Channels__c (default Email).
 * 4. Settings             - getSettings(): reads Intake_Setting__mdt (record "Default") with safe defaults.
 *
 * Status flow: New -> Queued (IntakeProcessor -> Completed / Duplicate / Rejected / Failed)
 *              New -> Rejected (not a resume or JD)
 *              New -> Failed   (AI error; retried by the hourly job)
 *
 * Email only: the files of one email run as one chain (startEmailChain): each file is identified in turn,
 * then IntakeProcessor creates the records one file after another (Upload_Batch__c), so two files of the
 * same email can never create the same candidate twice. WhatsApp keeps using start() unchanged.
 */
public without sharing class IntakeRouter implements Queueable, Database.AllowsCallouts {

    public static final String STATUS_NEW = 'New';
    public static final Set<String> FINAL_STATUSES = new Set<String>{ 'Completed', 'Duplicate', 'Rejected', 'Failed' };
    public static final String TEMPLATE = 'Intake_Document_Classifier';
    public static final String JOB_NAME = 'Intake Retry (hourly)';
    public static final String EMAIL_CHANNEL = 'Email';

    @TestVisible private static String mockResponse;
    @TestVisible private static Integer stuckMinutes = 60;
    public static final Integer LOOKBACK_DAYS = 3;
    private static final Integer BATCH_LIMIT = 40;

    private Id serviceId;
    private Boolean emailChain = false;

    /** Used to route one intake record. */
    public IntakeRouter(Id serviceId) {
        this.serviceId = serviceId;
    }

    /** Email: route one record, then continue with the next file of the same email (see startEmailChain). */
    public IntakeRouter(Id serviceId, Boolean emailChain) {
        this.serviceId = serviceId;
        this.emailChain = emailChain == true;
    }

    @TestVisible private static Id lastChainedRouterId;
    @TestVisible private static Id lastChainedProcessorId;

    /** Email: starts the chain for the files of one email (one job at a time). */
    public static void startEmailChain(Id firstServiceId) {
        if (firstServiceId == null) return;
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return; // the hourly job picks it up
        System.enqueueJob(new IntakeRouter(firstServiceId, true));
    }

    /**
     * Email: after one file was identified, identify the next file of the same email; when all are identified,
     * start creating records for the first queued file (IntakeProcessor then does the rest one after another).
     */
    @TestVisible
    private static void continueEmailChain(Id currentId) {
        List<Service__c> cur = [SELECT Upload_Batch__c FROM Service__c WHERE Id = :currentId];
        if (cur.isEmpty() || String.isBlank(cur[0].Upload_Batch__c)) return;
        String batch = cur[0].Upload_Batch__c;
        List<Service__c> nextNew = [
            SELECT Id FROM Service__c
            WHERE Upload_Batch__c = :batch AND Status__c = :STATUS_NEW AND Id != :currentId
            ORDER BY CreatedDate ASC, Name ASC LIMIT 1
        ];
        if (!nextNew.isEmpty()) {
            lastChainedRouterId = nextNew[0].Id;
            if (!Test.isRunningTest()) System.enqueueJob(new IntakeRouter(nextNew[0].Id, true));
            return;
        }
        List<Service__c> firstQueued = [
            SELECT Id FROM Service__c
            WHERE Upload_Batch__c = :batch AND Status__c = 'Queued'
            ORDER BY CreatedDate ASC, Name ASC LIMIT 1
        ];
        if (!firstQueued.isEmpty()) {
            lastChainedProcessorId = firstQueued[0].Id;
            if (!Test.isRunningTest()) System.enqueueJob(new IntakeProcessor(firstQueued[0].Id));
        }
    }

    // =====================================================================
    // 1. Router
    // =====================================================================

    /** Enqueues one router job per record while queueable room remains; the hourly job picks up any that did not fit. */
    public static void start(List<Id> serviceIds) {
        for (Id sid : serviceIds) {
            if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) break;
            System.enqueueJob(new IntakeRouter(sid));
        }
    }

    /** Word files up to this size get a text copy when the AI cannot read them (larger ones: heap safety). */
    @TestVisible private static Integer textCopyMaxBytes = 8 * 1024 * 1024;
    @TestVisible private static Id lastTextCopyFor;

    public void execute(QueueableContext ctx) {
        RouterFinalizer fin = new RouterFinalizer(serviceId, emailChain);
        System.attachFinalizer(fin);

        List<Service__c> svcs = [
            SELECT Id, Name, Status__c, Requested_Type__c, Detected_Type__c, Source_Channel__c
            FROM Service__c WHERE Id = :serviceId
        ];
        // Only one run per record: anything not New was already handled
        if (svcs.isEmpty() || svcs[0].Status__c != STATUS_NEW) return;
        Service__c svc = svcs[0];
        Boolean email = svc.Source_Channel__c == EMAIL_CHANNEL;
        // Email text of an email that also has files: it is only used when it is a job description
        Boolean jdOnly = email && svc.Requested_Type__c == IntakeController.TYPE_JD && svc.Detected_Type__c == null;

        ContentVersion file = IntakeProcessor.latestFile(serviceId);
        if (file == null) {
            finish(svc, 'Failed', 'No file was found on this intake record.');
            return;
        }

        // AI call first, before any DML in this transaction
        Classification c;
        try {
            c = classify(file.ContentDocumentId);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'IntakeRouter', 'classify');
            finish(svc, 'Failed', 'The AI service could not identify the file: ' + e.getMessage() + ' It will be retried automatically.');
            return;
        }

        // Email: a Word file the AI could not read (empty, or read too early) gets a PDF text copy and is read again.
        // Same text copy as IntakeProcessor (Srimathi, 27-11-2026), which then reads the copy and links the original file.
        Boolean understood = c.documentType == IntakeController.TYPE_RESUME || c.documentType == IntakeController.TYPE_JD;
        if (email && !jdOnly && !understood && needsTextCopy(file) && addTextCopyAndRetry(svc, file, fin)) return;

        String why = String.isBlank(c.reason) ? '' : ' (' + c.reason + ')';
        if (jdOnly && c.documentType != IntakeController.TYPE_JD) {
            svc.Detected_Type__c = 'Other';
            finish(svc, 'Rejected', 'The email text is not a job description' + why
                + '. The attached files are processed separately. Nothing was created from the email text.');
        } else if (c.documentType == IntakeController.TYPE_RESUME || c.documentType == IntakeController.TYPE_JD) {
            svc.Requested_Type__c = c.documentType;
            svc.Detected_Type__c = c.documentType;
            svc.Status__c = 'Queued';
            svc.Status_Message__c = 'Identified as ' + c.documentType + why + '. Creating records...';
            update svc;
            // Email chain: records are created after all files of the email are identified (finalizer).
            // Email retry of one file: process only this file, without starting a second chain.
            if (!Test.isRunningTest() && !emailChain) {
                System.enqueueJob(email ? new IntakeProcessor(svc.Id, false) : new IntakeProcessor(svc.Id));
            }
        } else {
            svc.Detected_Type__c = 'Other';
            finish(svc, 'Rejected', 'This file is not a resume or a job description' + why + '.'
                + (email ? ' If it is a resume or job description that was scanned or is password-protected, '
                    + 'please send it as a text-based PDF or DOCX.' : '')
                + ' Nothing was created.');
        }
    }

    /** A Word file (not already a text copy) small enough to read in Apex. */
    @TestVisible
    private static Boolean needsTextCopy(ContentVersion f) {
        return f != null && f.FileExtension != null && f.FileExtension.equalsIgnoreCase('docx')
            && !IntakeProcessor.isTextCopy(f) && f.ContentSize != null && f.ContentSize <= textCopyMaxBytes;
    }

    /**
     * Reads the Word file's text in Apex (DocxText), saves it as a PDF text copy on the intake and identifies the
     * intake again in a new job (the AI then reads the copy). False when no text could be read: normal result follows.
     */
    private Boolean addTextCopyAndRetry(Service__c svc, ContentVersion file, RouterFinalizer fin) {
        try {
            // never a second copy for the same intake (loop guard)
            String copyPattern = '%' + IntakeProcessor.TEXT_COPY_SUFFIX;
            if ([SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :svc.Id
                 AND ContentDocument.Title LIKE :copyPattern] > 0) return false;
            List<ContentVersion> data = [SELECT VersionData FROM ContentVersion WHERE Id = :file.Id];
            String text = data.isEmpty() ? null : DocxText.extract(data[0].VersionData);
            data = null;
            if (String.isBlank(text) || text.length() < 50) return false;
            String title = (file.Title == null ? 'Document' : file.Title).left(200) + IntakeProcessor.TEXT_COPY_SUFFIX;
            Blob pdf = parseEmail.bodyAsPdf(null, text);
            insert new ContentVersion(
                Title = title,
                PathOnClient = title + (pdf != null ? '.pdf' : '.txt'),
                VersionData = pdf != null ? pdf : Blob.valueOf(text),
                FirstPublishLocationId = svc.Id
            );
            svc.Status_Message__c = 'The AI could not read this Word file directly, so a text copy of it is being read. Please wait.';
            update svc;
        } catch (Exception e) {
            UtilityClass.createElog(e, 'IntakeRouter', 'addTextCopy');
            return false;
        }
        // this file is not finished yet: the new job identifies it, then continues with the email's next file
        fin.skipChain = true;
        lastTextCopyFor = svc.Id;
        if (!Test.isRunningTest()) System.enqueueJob(new IntakeRouter(svc.Id, emailChain));
        return true;
    }

    private static void finish(Service__c svc, String status, String message) {
        svc.Status__c = status;
        svc.Status_Message__c = message == null ? null : message.left(32000);
        update svc;
    }

    /**
     * Marks the record Failed if the job died with an uncatchable error (limits, timeouts).
     * Email chain: then moves on to the next file of the same email, whatever happened to this one.
     */
    public class RouterFinalizer implements Finalizer {
        private Id serviceId;
        private Boolean emailChain = false;
        /** Set when the same record is identified again in a new job (text copy): do not move on yet. */
        public Boolean skipChain = false;
        public RouterFinalizer(Id serviceId) { this.serviceId = serviceId; }
        public RouterFinalizer(Id serviceId, Boolean emailChain) {
            this.serviceId = serviceId;
            this.emailChain = emailChain == true;
        }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() != ParentJobResult.SUCCESS) markFailed(serviceId, ctx.getException());
            if (!emailChain || (skipChain && ctx.getResult() == ParentJobResult.SUCCESS)) return;
            try {
                continueEmailChain(serviceId);
            } catch (Exception e) {
                UtilityClass.createElog(e, 'IntakeRouter', 'continueEmailChain');
            }
        }
    }

    @TestVisible
    private static void markFailed(Id serviceId, Exception ex) {
        UtilityClass.createElog(ex, 'IntakeRouter', 'finalizer');
        List<Service__c> svcs = [SELECT Id, Status__c FROM Service__c WHERE Id = :serviceId];
        if (svcs.isEmpty() || svcs[0].Status__c != STATUS_NEW) return;
        svcs[0].Status__c = 'Failed';
        svcs[0].Status_Message__c = ('Processing stopped unexpectedly' + (ex != null ? ': ' + ex.getMessage() : '.')
            + ' It will be retried automatically.').left(32000);
        update svcs[0];
    }

    // =====================================================================
    // 2. Classifier
    // =====================================================================

    public class Classification {
        public String documentType;   // 'Resume', 'Job Description' or 'Other'
        public String reason;
        public Decimal confidence;
        public String raw;
    }

    /**
     * Sends the file itself to the Intake_Document_Classifier prompt. The decision is based on the
     * file content, not on its name. Throws when the AI call fails or its answer cannot be read,
     * so the caller can mark the record Failed (retryable).
     */
    public static Classification classify(Id contentDocumentId) {
        if (contentDocumentId == null) throw new IllegalArgumentException('No file was given to the classifier.');

        ConnectApi.WrappedValue fileValue = new ConnectApi.WrappedValue();
        fileValue.value = new Map<String, String>{ 'id' => contentDocumentId, 'type' => 'ContentDocument' };
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:File' => fileValue };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.isPreview = false;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output = Test.isRunningTest()
            ? CandidateCreationPrompt.fakeOutput(mockResponse)
            : ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, input);
        String text = CandidateCreationPrompt.textOf(output, 'The file classifier returned an empty response.');

        Map<String, Object> parsed = AiJson.parse(text);
        if (parsed == null) throw new CalloutException('The file classifier response could not be read.');

        Classification r = new Classification();
        r.raw = text;
        String t = AiJson.documentType(text);
        r.documentType = (t == 'Resume' || t == 'Job Description') ? t : 'Other';
        r.reason = AiJson.str(parsed, 'reason');
        if (r.reason != null) r.reason = r.reason.left(200);
        r.confidence = AiJson.toNumber(parsed.get('confidence'));
        return r;
    }

    // =====================================================================
    // 3. Hourly retry job
    // =====================================================================

    /** Hourly schedule entry point. (A Queueable class cannot also be Schedulable, so it is an inner class.) */
    public class RetryJob implements Schedulable {
        public void execute(SchedulableContext sc) {
            runRetry();
        }
    }

    /** Returns how many records were restarted. Rejected and Duplicate records are final and never retried. */
    public static Integer runRetry() {
        Settings cfg = getSettings();
        if (!cfg.enabled) return 0;

        Datetime since = Datetime.now().addDays(-LOOKBACK_DAYS);
        Datetime stuckBefore = Datetime.now().addMinutes(-stuckMinutes);
        Decimal maxRetries = cfg.maxRetries;
        Set<String> channels = cfg.retryChannels;

        List<Service__c> candidates = [
            SELECT Id, Status__c, Requested_Type__c, Retry_Count__c, Status_Message__c, Source_Channel__c, Detected_Type__c
            FROM Service__c
            WHERE Source_Channel__c IN :channels
              AND CreatedDate >= :since
              AND (
                    (Status__c = 'Failed' AND (Retry_Count__c = null OR Retry_Count__c < :maxRetries))
                 OR (Status__c IN ('New', 'Queued') AND LastModifiedDate < :stuckBefore)
              )
            ORDER BY CreatedDate ASC
            LIMIT :BATCH_LIMIT
        ];

        List<Service__c> toUpdate = new List<Service__c>();
        List<Id> toRoute = new List<Id>();
        List<Id> toProcess = new List<Id>();
        Set<Id> emailIds = new Set<Id>();
        Integer room = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();

        for (Service__c s : candidates) {
            Decimal tries = s.Retry_Count__c == null ? 0 : s.Retry_Count__c;
            if (tries >= maxRetries) {
                // stuck again after the last allowed retry: give up visibly
                s.Status__c = 'Failed';
                s.Status_Message__c = ('Gave up after ' + tries.intValue() + ' automatic retries. Last message: '
                    + (s.Status_Message__c == null ? '' : s.Status_Message__c)).left(32000);
                toUpdate.add(s);
                continue;
            }
            if (room <= 0) break;
            room--;
            Boolean email = s.Source_Channel__c == EMAIL_CHANNEL;
            if (email) emailIds.add(s.Id);
            // Email: the text of an email with files has a type before it is identified; it must be identified first
            Boolean identified = String.isNotBlank(s.Requested_Type__c)
                && (!email || s.Status__c == 'Queued' || s.Detected_Type__c != null);
            s.Retry_Count__c = tries + 1;
            String prev = s.Status_Message__c == null ? '' : ' Previous message: ' + s.Status_Message__c;
            s.Status_Message__c = ('Automatic retry ' + s.Retry_Count__c.intValue() + ' of ' + maxRetries.intValue() + '.' + prev).left(32000);
            if (identified) {
                s.Status__c = 'Queued';
                toProcess.add(s.Id);
            } else {
                s.Status__c = STATUS_NEW;
                toRoute.add(s.Id);
            }
            toUpdate.add(s);
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        if (!Test.isRunningTest()) {
            // Email: a retried file is processed on its own (no second chain next to a running one)
            for (Id i : toProcess) System.enqueueJob(emailIds.contains(i) ? new IntakeProcessor(i, false) : new IntakeProcessor(i));
            for (Id i : toRoute) System.enqueueJob(new IntakeRouter(i));
        }

        try {
            parseEmail.sendPendingAcknowledgements(since);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'IntakeRouter', 'sendPendingAcknowledgements');
        }
        return toProcess.size() + toRoute.size();
    }

    /** Schedules the job hourly (minute 17). Safe to call twice: an existing schedule is kept. */
    public static Id scheduleHourly() {
        List<CronTrigger> existing = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME LIMIT 1];
        if (!existing.isEmpty()) return existing[0].Id;
        return System.schedule(JOB_NAME, '0 17 * * * ?', new RetryJob());
    }

    // =====================================================================
    // 4. Settings
    // =====================================================================

    /** Intake_Setting__mdt (record "Default"). Every value has a safe default. */
    public class Settings {
        public Boolean enabled = true;
        public Set<String> retryChannels = new Set<String>{ 'Email' };
        public Set<String> allowedExtensions = new Set<String>{ 'pdf', 'docx' };
        public Integer maxFilesPerEmail = 10;
        public Integer maxFilesPerUpload = 10;
        public Integer maxUploadFileMb = 10;
        public Integer minBodyLength = 300;
        public Integer maxRetries = 2;
        public Boolean sendAcknowledgement = false;
        public Boolean restrictWhatsAppToInternal = true;
        public Set<String> acknowledgementDomains = new Set<String>();
        // Email only
        public Integer minBodyLengthWithFiles = 800;      // 0 = never read the text of an email that has files
        public Integer maxEmailFileMb = 10;               // 0 = no size limit
        public String acknowledgementFromAddress;         // Org-Wide Email Address used as sender (blank = running user)
        public List<String> failureAlertEmails = new List<String>(); // blank = no failure alert
        public Boolean restrictEmailToInternal = false;   // only active Salesforce users may send by email

        /** True when the address belongs to one of the acknowledgement domains. */
        public Boolean canAcknowledge(String address) {
            if (!sendAcknowledgement || String.isBlank(address) || !address.contains('@')) return false;
            return acknowledgementDomains.contains(address.substringAfterLast('@').trim().toLowerCase());
        }
    }

    @TestVisible private static Settings cachedSettings;

    public static Settings getSettings() {
        if (cachedSettings != null) return cachedSettings;
        Settings s = new Settings();
        Intake_Setting__mdt rec = Intake_Setting__mdt.getInstance('Default');
        if (rec != null) {
            s.enabled = rec.Enabled__c;
            s.sendAcknowledgement = rec.Send_Acknowledgement__c;
            if (rec.Restrict_WhatsApp_To_Internal__c != null) s.restrictWhatsAppToInternal = rec.Restrict_WhatsApp_To_Internal__c;
            Set<String> channels = splitList(rec.Retry_Channels__c, false);
            if (!channels.isEmpty()) s.retryChannels = channels;
            Set<String> domains = splitList(rec.Acknowledgement_Domains__c, true);
            if (!domains.isEmpty()) s.acknowledgementDomains = domains;
            Set<String> exts = splitList(rec.Allowed_Extensions__c, true);
            if (!exts.isEmpty()) s.allowedExtensions = exts;
            if (rec.Max_Files_Per_Email__c != null && rec.Max_Files_Per_Email__c > 0) s.maxFilesPerEmail = rec.Max_Files_Per_Email__c.intValue();
            if (rec.Max_Files_Per_Upload__c != null && rec.Max_Files_Per_Upload__c > 0) s.maxFilesPerUpload = rec.Max_Files_Per_Upload__c.intValue();
            if (rec.Max_Upload_File_MB__c != null && rec.Max_Upload_File_MB__c > 0) s.maxUploadFileMb = rec.Max_Upload_File_MB__c.intValue();
            if (rec.Min_Body_Length__c != null && rec.Min_Body_Length__c >= 0) s.minBodyLength = rec.Min_Body_Length__c.intValue();
            if (rec.Max_Retries__c != null && rec.Max_Retries__c >= 0) s.maxRetries = rec.Max_Retries__c.intValue();
            if (rec.Min_Body_Length_With_Files__c != null && rec.Min_Body_Length_With_Files__c >= 0) {
                s.minBodyLengthWithFiles = rec.Min_Body_Length_With_Files__c.intValue();
            }
            if (rec.Max_Email_File_MB__c != null && rec.Max_Email_File_MB__c >= 0) s.maxEmailFileMb = rec.Max_Email_File_MB__c.intValue();
            if (String.isNotBlank(rec.Acknowledgement_From_Address__c)) s.acknowledgementFromAddress = rec.Acknowledgement_From_Address__c.trim();
            s.failureAlertEmails = new List<String>(splitList(rec.Failure_Alert_Emails__c, false));
            if (rec.Restrict_Email_To_Internal__c != null) s.restrictEmailToInternal = rec.Restrict_Email_To_Internal__c;
        }
        cachedSettings = s;
        return s;
    }

    private static Set<String> splitList(String raw, Boolean lower) {
        Set<String> out = new Set<String>();
        if (String.isBlank(raw)) return out;
        for (String p : raw.split('[,;]+')) {
            String v = p.trim();
            if (lower) v = v.toLowerCase().removeStart('.').removeStart('@');
            if (v != '') out.add(v);
        }
        return out;
    }
}