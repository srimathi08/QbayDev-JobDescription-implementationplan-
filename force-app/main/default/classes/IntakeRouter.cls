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
 */
public without sharing class IntakeRouter implements Queueable, Database.AllowsCallouts {

    public static final String STATUS_NEW = 'New';
    public static final Set<String> FINAL_STATUSES = new Set<String>{ 'Completed', 'Duplicate', 'Rejected', 'Failed' };
    public static final String TEMPLATE = 'Intake_Document_Classifier';
    public static final String JOB_NAME = 'Intake Retry (hourly)';

    @TestVisible private static String mockResponse;
    @TestVisible private static Integer stuckMinutes = 60;
    @TestVisible private static final Integer LOOKBACK_DAYS = 3;
    private static final Integer BATCH_LIMIT = 40;

    private Id serviceId;

    /** Used to route one intake record. */
    public IntakeRouter(Id serviceId) {
        this.serviceId = serviceId;
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

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new RouterFinalizer(serviceId));

        List<Service__c> svcs = [
            SELECT Id, Name, Status__c, Requested_Type__c
            FROM Service__c WHERE Id = :serviceId
        ];
        // Only one run per record: anything not New was already handled
        if (svcs.isEmpty() || svcs[0].Status__c != STATUS_NEW) return;
        Service__c svc = svcs[0];

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

        String why = String.isBlank(c.reason) ? '' : ' (' + c.reason + ')';
        if (c.documentType == IntakeController.TYPE_RESUME || c.documentType == IntakeController.TYPE_JD) {
            svc.Requested_Type__c = c.documentType;
            svc.Detected_Type__c = c.documentType;
            svc.Status__c = 'Queued';
            svc.Status_Message__c = 'Identified as ' + c.documentType + why + '. Creating records...';
            update svc;
            if (!Test.isRunningTest()) System.enqueueJob(new IntakeProcessor(svc.Id));
        } else {
            svc.Detected_Type__c = 'Other';
            finish(svc, 'Rejected', 'This file is not a resume or a job description' + why + '. Nothing was created.');
        }
    }

    private static void finish(Service__c svc, String status, String message) {
        svc.Status__c = status;
        svc.Status_Message__c = message == null ? null : message.left(32000);
        update svc;
    }

    /** Marks the record Failed if the job died with an uncatchable error (limits, timeouts). */
    public class RouterFinalizer implements Finalizer {
        private Id serviceId;
        public RouterFinalizer(Id serviceId) { this.serviceId = serviceId; }
        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() == ParentJobResult.SUCCESS) return;
            Exception ex = ctx.getException();
            UtilityClass.createElog(ex, 'IntakeRouter', 'finalizer');
            List<Service__c> svcs = [SELECT Id, Status__c FROM Service__c WHERE Id = :serviceId];
            if (svcs.isEmpty() || svcs[0].Status__c != STATUS_NEW) return;
            svcs[0].Status__c = 'Failed';
            svcs[0].Status_Message__c = ('Processing stopped unexpectedly' + (ex != null ? ': ' + ex.getMessage() : '.')
                + ' It will be retried automatically.').left(32000);
            update svcs[0];
        }
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
            SELECT Id, Status__c, Requested_Type__c, Retry_Count__c, Status_Message__c
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
            s.Retry_Count__c = tries + 1;
            String prev = s.Status_Message__c == null ? '' : ' Previous message: ' + s.Status_Message__c;
            s.Status_Message__c = ('Automatic retry ' + s.Retry_Count__c.intValue() + ' of ' + maxRetries.intValue() + '.' + prev).left(32000);
            if (String.isNotBlank(s.Requested_Type__c)) {
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
            for (Id i : toProcess) System.enqueueJob(new IntakeProcessor(i));
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
        public Integer minBodyLength = 300;
        public Integer maxRetries = 2;
        public Boolean sendAcknowledgement = false;
        public Set<String> acknowledgementDomains = new Set<String>();

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
            Set<String> channels = splitList(rec.Retry_Channels__c, false);
            if (!channels.isEmpty()) s.retryChannels = channels;
            Set<String> domains = splitList(rec.Acknowledgement_Domains__c, true);
            if (!domains.isEmpty()) s.acknowledgementDomains = domains;
            Set<String> exts = splitList(rec.Allowed_Extensions__c, true);
            if (!exts.isEmpty()) s.allowedExtensions = exts;
            if (rec.Max_Files_Per_Email__c != null && rec.Max_Files_Per_Email__c > 0) s.maxFilesPerEmail = rec.Max_Files_Per_Email__c.intValue();
            if (rec.Min_Body_Length__c != null && rec.Min_Body_Length__c >= 0) s.minBodyLength = rec.Min_Body_Length__c.intValue();
            if (rec.Max_Retries__c != null && rec.Max_Retries__c >= 0) s.maxRetries = rec.Max_Retries__c.intValue();
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