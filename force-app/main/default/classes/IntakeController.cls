/**
 * Entry point for the Qbay Home uploaders and the intake inbox.
 * New upload path (25-11-2026): the standard file upload stores the files, then submitUploadedFiles()
 * creates one intake per file and starts the first; the rest run one after another (IntakeProcessor finalizer).
 * Inbox actions for Qbay Home uploads: completeReview (Needs Review), attachToExisting (Duplicate), retryIntake.
 * Email and WhatsApp intakes are shown read-only; their processing is owned by their own classes.
 *
 * Original description:
 * One call = one file = one Service__c intake record, created atomically with its file.
 * Idempotent on Request_Key__c: repeating the same request (double click, network retry)
 * returns the existing intake instead of creating a second one.
 */
public with sharing class IntakeController {

    public static final String TYPE_RESUME = 'Resume';
    public static final String TYPE_JD = 'Job Description';
    public static final Integer MAX_FILE_BYTES = 3 * 1024 * 1024; // Aura request limit is ~4 MB after base64
    public static final Set<String> ALLOWED_EXTENSIONS = new Set<String>{ 'pdf', 'docx' };

    public class IntakeStatus {
        @AuraEnabled public Id serviceId;
        @AuraEnabled public String fileName;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public String requestedType;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public Id jobDescriptionId;
        @AuraEnabled public String jobDescriptionName;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Boolean isFinal;
        @AuraEnabled public String channel;
        @AuraEnabled public String createdByName;
        @AuraEnabled public Boolean canReview;
        @AuraEnabled public Boolean canAttach;
        @AuraEnabled public Boolean canRetry;
    }

    public class UploadSettings {
        @AuraEnabled public Integer maxFiles;
        @AuraEnabled public Integer maxFileMb;
        @AuraEnabled public Id userId;
    }

    public static final String TYPE_AUTO = 'Auto';
    public static final String CHANNEL_UI = 'UI Upload';
    public static final Integer DEFAULT_MAX_FILES = 10;
    public static final Integer DEFAULT_MAX_FILE_MB = 10;
    public static final Integer STUCK_MINUTES = 15;
    private static final Set<String> FINAL_STATUSES = new Set<String>{ 'Completed', 'Duplicate', 'Rejected', 'Failed', 'Needs Review' };
    private static final String STATUS_FIELDS = 'Id, Name, Status__c, Status_Message__c, Requested_Type__c, CreatedDate, LastModifiedDate, '
        + 'Source_Channel__c, CreatedBy.Name, CreatedById, Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name, '
        + 'Job_Description__c, Job_Description__r.Name, Retry_Count__c';

    /**
     * Creates (or returns) the intake for one file and queues processing.
     * @param requestKey  unique per file per Submit, generated in the browser
     * @param requestedType 'Resume' or 'Job Description' (the tab the user used)
     * @param fileName original file name with extension
     * @param base64 file content
     */
    @AuraEnabled
    public static IntakeStatus submitFile(String requestKey, String requestedType, String fileName, String base64) {
        if (String.isBlank(requestKey)) throw error('Missing request key. Please refresh the page and try again.');
        if (requestedType != TYPE_RESUME && requestedType != TYPE_JD) throw error('Unknown upload type.');
        if (String.isBlank(fileName)) throw error('File name is missing.');
        if (String.isBlank(base64)) throw error('The file "' + fileName + '" is empty.');

        String ext = extensionOf(fileName);
        if (!ALLOWED_EXTENSIONS.contains(ext)) {
            throw error('"' + fileName + '" is not supported. Please upload a PDF or DOCX file.');
        }

        // Idempotency: same key -> same intake, no second run
        List<Service__c> existing = [SELECT Id FROM Service__c WHERE Request_Key__c = :requestKey LIMIT 1];
        if (!existing.isEmpty()) {
            return getStatus(new List<Id>{ existing[0].Id })[0];
        }

        Blob data;
        try {
            data = EncodingUtil.base64Decode(base64);
        } catch (Exception e) {
            throw error('The file "' + fileName + '" could not be read.');
        }
        if (data.size() == 0) throw error('The file "' + fileName + '" is empty.');
        if (data.size() > MAX_FILE_BYTES) throw error('"' + fileName + '" is larger than 3 MB. Please upload a smaller file.');

        Savepoint sp = Database.setSavepoint();
        Service__c svc = new Service__c(
            Name = fileName.left(80),
            Source_Channel__c = 'UI Upload',
            Requested_Type__c = requestedType,
            Status__c = 'Queued',
            Request_Key__c = requestKey
        );
        try {
            insert svc;
        } catch (DmlException e) {
            // Two identical requests at the same moment: the unique key wins, return the first one
            if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {
                Database.rollback(sp);
                Service__c first = [SELECT Id FROM Service__c WHERE Request_Key__c = :requestKey LIMIT 1];
                return getStatus(new List<Id>{ first.Id })[0];
            }
            throw error('Could not create the upload record: ' + e.getDmlMessage(0));
        }

        try {
            ContentVersion cv = new ContentVersion(
                Title = titleOf(fileName),
                PathOnClient = fileName,
                VersionData = data,
                FirstPublishLocationId = svc.Id
            );
            insert cv;
            cv = [SELECT Id, Checksum, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
            svc.File_Checksum__c = cv.Checksum;
            update svc;

            System.enqueueJob(new IntakeProcessor(svc.Id));
        } catch (Exception e) {
            Database.rollback(sp);
            UtilityClass.createElog(e, 'IntakeController', 'submitFile');
            throw error('Upload failed for "' + fileName + '": ' + e.getMessage());
        }
        return getStatus(new List<Id>{ svc.Id })[0];
    }

    /** Current status of the given intakes, for the LWC to refresh. Not cacheable on purpose. */
    @AuraEnabled
    public static List<IntakeStatus> getStatus(List<Id> serviceIds) {
        List<IntakeStatus> out = new List<IntakeStatus>();
        if (serviceIds == null || serviceIds.isEmpty()) return out;
        Map<Id, Service__c> byId = new Map<Id, Service__c>(
            (List<Service__c>) Database.query('SELECT ' + STATUS_FIELDS + ' FROM Service__c WHERE Id IN :serviceIds')
        );
        for (Id i : serviceIds) {
            Service__c s = byId.get(i);
            if (s != null) out.add(toStatus(s));
        }
        return out;
    }

    /** Uploads the current user made today (replaces "View Today Uploads"). */
    @AuraEnabled
    public static List<IntakeStatus> getMyUploadsToday(String requestedType) {
        List<IntakeStatus> out = new List<IntakeStatus>();
        for (Service__c s : [
            SELECT Id, Name, Status__c, Status_Message__c, Requested_Type__c, CreatedDate, LastModifiedDate,
                   Source_Channel__c, CreatedBy.Name, CreatedById, Account__c, Account__r.Name,
                   Opportunity__c, Opportunity__r.Name, Job_Description__c, Job_Description__r.Name, Retry_Count__c
            FROM Service__c
            WHERE CreatedById = :UserInfo.getUserId()
              AND CreatedDate = TODAY
              AND Source_Channel__c = 'UI Upload'
              AND Requested_Type__c = :requestedType
            ORDER BY CreatedDate DESC
            LIMIT 200
        ]) {
            out.add(toStatus(s));
        }
        return out;
    }

    // =====================================================================
    // New upload path: standard file upload + one intake per file
    // =====================================================================

    /** Limits for the uploader, from Intake_Setting__mdt.Default (safe defaults when blank). */
    @AuraEnabled(cacheable=true)
    public static UploadSettings getUploadSettings() {
        UploadSettings st = new UploadSettings();
        st.maxFiles = DEFAULT_MAX_FILES;
        st.maxFileMb = DEFAULT_MAX_FILE_MB;
        st.userId = UserInfo.getUserId();
        Intake_Setting__mdt rec = Intake_Setting__mdt.getInstance('Default');
        if (rec != null) {
            if (rec.Max_Files_Per_Upload__c != null && rec.Max_Files_Per_Upload__c > 0) st.maxFiles = rec.Max_Files_Per_Upload__c.intValue();
            if (rec.Max_Upload_File_MB__c != null && rec.Max_Upload_File_MB__c > 0) st.maxFileMb = rec.Max_Upload_File_MB__c.intValue();
        }
        return st;
    }

    /**
     * Called after the standard file upload finished. One intake per file; files over the limits get a
     * Rejected intake that says why (and their uploaded copy is removed). Only the first queued file is
     * started; the others follow one by one.
     * @param requestedType 'Auto', 'Resume' or 'Job Description'
     * @param batchKey unique per upload, generated in the browser
     */
    @AuraEnabled
    public static List<IntakeStatus> submitUploadedFiles(List<Id> contentDocumentIds, String requestedType, String batchKey) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) throw error('No files were uploaded.');
        if (String.isBlank(batchKey)) throw error('Missing upload key. Please refresh the page and try again.');
        if (requestedType != TYPE_AUTO && requestedType != TYPE_RESUME && requestedType != TYPE_JD) throw error('Unknown upload type.');
        UploadSettings cfg = getUploadSettings();
        String batch = batchKey.left(64);

        // Same upload sent twice (network retry): return what exists
        List<Service__c> existing = [SELECT Id FROM Service__c WHERE Upload_Batch__c = :batch ORDER BY CreatedDate ASC, Name ASC];
        if (!existing.isEmpty()) {
            List<Id> ids = new List<Id>();
            for (Service__c e : existing) ids.add(e.Id);
            return getStatus(ids);
        }

        Map<Id, ContentVersion> versionByDoc = new Map<Id, ContentVersion>();
        for (ContentVersion cv : [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize, Checksum, OwnerId
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds AND IsLatest = true
        ]) {
            versionByDoc.put(cv.ContentDocumentId, cv);
        }

        List<Service__c> services = new List<Service__c>();
        List<ContentVersion> fileOf = new List<ContentVersion>();
        Set<Id> removeDocs = new Set<Id>();
        Integer accepted = 0;
        Integer i = 0;
        for (Id docId : contentDocumentIds) {
            ContentVersion cv = versionByDoc.get(docId);
            if (cv == null) continue;
            if (cv.OwnerId != UserInfo.getUserId()) throw error('You can only submit files you uploaded yourself.');
            String fileName = cv.FileExtension == null ? cv.Title : cv.Title + '.' + cv.FileExtension;
            String reason = null;
            String ext = cv.FileExtension == null ? '' : cv.FileExtension.toLowerCase();
            if (!ALLOWED_EXTENSIONS.contains(ext)) {
                reason = '"' + fileName + '" is not supported. Please upload a PDF or DOCX file. Nothing was created.';
            } else if (cv.ContentSize == null || cv.ContentSize == 0) {
                reason = '"' + fileName + '" is empty. Nothing was created.';
            } else if (cv.ContentSize > cfg.maxFileMb * 1024 * 1024) {
                reason = '"' + fileName + '" is larger than ' + cfg.maxFileMb + ' MB. Please upload a smaller file. Nothing was created.';
            } else if (accepted >= cfg.maxFiles) {
                reason = 'Only ' + cfg.maxFiles + ' files can be uploaded at a time. Please upload "' + fileName + '" again in a new upload. Nothing was created.';
            } else {
                accepted++;
            }
            if (reason != null) removeDocs.add(docId);
            services.add(new Service__c(
                Name = fileName.left(80),
                Source_Channel__c = CHANNEL_UI,
                Requested_Type__c = requestedType == TYPE_AUTO ? null : requestedType,
                Status__c = reason == null ? 'Queued' : 'Rejected',
                Status_Message__c = reason,
                Request_Key__c = (batch + '-' + i).left(255),
                Upload_Batch__c = reason == null ? batch : null,
                File_Checksum__c = reason == null ? cv.Checksum : null
            ));
            fileOf.add(cv);
            i++;
        }
        if (services.isEmpty()) throw error('The uploaded files could not be found. Please try again.');

        Savepoint sp = Database.setSavepoint();
        try {
            insert services;
            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (Integer k = 0; k < services.size(); k++) {
                if (services[k].Status__c != 'Queued') continue;
                links.add(new ContentDocumentLink(
                    ContentDocumentId = fileOf[k].ContentDocumentId,
                    LinkedEntityId = services[k].Id,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                ));
            }
            if (!links.isEmpty()) insert links;
            if (!removeDocs.isEmpty()) {
                delete [SELECT Id FROM ContentDocument WHERE Id IN :removeDocs];
            }
            for (Service__c s : services) {
                if (s.Status__c == 'Queued') {
                    System.enqueueJob(new IntakeProcessor(s.Id));
                    break;
                }
            }
        } catch (Exception e) {
            Database.rollback(sp);
            UtilityClass.createElog(e, 'IntakeController', 'submitUploadedFiles');
            throw error('Upload failed: ' + e.getMessage());
        }
        List<Id> ids = new List<Id>();
        for (Service__c s : services) ids.add(s.Id);
        return getStatus(ids);
    }

    // =====================================================================
    // Intake inbox
    // =====================================================================

    /**
     * Intakes for the inbox, newest first, at most 200.
     * @param channel 'All', 'UI Upload', 'Email' or 'WhatsApp'
     * @param status 'All', 'Action needed' (Needs Review, Duplicate, Failed) or one status
     * @param days 1 = today, 7, 30
     * @param mineOnly only intakes the current user created
     */
    @AuraEnabled
    public static List<IntakeStatus> getInbox(String channel, String status, Integer days, Boolean mineOnly) {
        Integer d = (days == null || days < 1) ? 1 : Math.min(days, 90);
        Datetime since = d == 1 ? Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0)) : Datetime.now().addDays(-d);
        Id me = UserInfo.getUserId();
        List<String> conds = new List<String>{ 'CreatedDate >= :since' };
        String ch = channel;
        if (String.isNotBlank(ch) && ch != 'All') conds.add('Source_Channel__c = :ch');
        Set<String> statuses = new Set<String>();
        if (status == 'Action needed') {
            statuses = new Set<String>{ 'Needs Review', 'Duplicate', 'Failed' };
        } else if (String.isNotBlank(status) && status != 'All') {
            statuses.add(status);
        }
        if (!statuses.isEmpty()) conds.add('Status__c IN :statuses');
        if (mineOnly == true) conds.add('CreatedById = :me');
        String q = 'SELECT ' + STATUS_FIELDS + ' FROM Service__c WHERE ' + String.join(conds, ' AND ')
            + ' ORDER BY CreatedDate DESC LIMIT 200';
        List<IntakeStatus> out = new List<IntakeStatus>();
        for (Service__c s : (List<Service__c>) Database.query(q)) out.add(toStatus(s));
        return out;
    }

    /** Needs Review / Duplicate by name: the recruiter adds the missing contact details, the saved AI result is reused. */
    @AuraEnabled
    public static IntakeStatus completeReview(Id serviceId, String email, String phone, String linkedIn) {
        Service__c svc = loadForAction(serviceId);
        if (svc.Status__c != 'Needs Review' && svc.Status__c != 'Duplicate') throw error('This upload does not need contact details.');
        if (String.isBlank(email) && String.isBlank(phone) && String.isBlank(linkedIn)) {
            throw error('Please enter an email, a phone number or a LinkedIn profile.');
        }
        if (String.isNotBlank(email) && AiJson.normalizeEmail(email) == null) throw error('"' + email + '" is not a valid email address.');
        if (String.isNotBlank(phone) && AiJson.digitsOnly(phone) == null) throw error('"' + phone + '" is not a valid phone number.');
        if (String.isBlank(svc.AI_Response__c)) throw error('The saved AI result for this file is missing. Please upload the file again.');
        ContentVersion file = IntakeProcessor.latestFile(svc.Id);
        if (file == null) throw error('The file of this upload was not found. Please upload it again.');

        String patched = CandidateCreationController.withContact(svc.AI_Response__c, email, phone, linkedIn);
        Savepoint sp = Database.setSavepoint();
        try {
            CandidateCreationController.Result r = CandidateCreationController.process(patched, file.ContentDocumentId, svc.Id, true);
            svc.Account__c = r.primaryAccountId;
            svc.Status__c = 'Completed';
            svc.Status_Message__c = ('Contact details added by ' + UserInfo.getName() + '. ' + (r.summary == null ? '' : r.summary)).left(32000);
        } catch (IntakeProcessor.DuplicateException dup) {
            Database.rollback(sp);
            svc.Account__c = dup.accountId;
            svc.Status__c = 'Duplicate';
            svc.Status_Message__c = dup.getMessage();
        } catch (IntakeProcessor.RejectException rej) {
            Database.rollback(sp);
            throw error(rej.getMessage());
        } catch (IntakeProcessor.NeedsReviewException nr) {
            Database.rollback(sp);
            throw error('Please enter a valid email, phone number or LinkedIn profile.');
        } catch (Exception e) {
            Database.rollback(sp);
            UtilityClass.createElog(e, 'IntakeController', 'completeReview');
            throw error('Could not save the candidate: ' + e.getMessage());
        }
        svc.AI_Response__c = patched.left(131000);
        update svc;
        return getStatus(new List<Id>{ svc.Id })[0];
    }

    /** Duplicate: keeps the existing candidate and attaches this resume file to it. */
    @AuraEnabled
    public static IntakeStatus attachToExisting(Id serviceId) {
        Service__c svc = loadForAction(serviceId);
        if (svc.Status__c != 'Duplicate' || svc.Account__c == null) throw error('This upload is not linked to an existing candidate.');
        ContentVersion file = IntakeProcessor.latestFile(svc.Id);
        if (file == null) throw error('The file of this upload was not found.');
        CandidateCreationController.linkFile(file.ContentDocumentId, new Set<Id>{ svc.Account__c });
        svc.Status__c = 'Completed';
        svc.Status_Message__c = ('Resume attached to the existing candidate by ' + UserInfo.getName() + '. No new candidate was created.').left(32000);
        update svc;
        return getStatus(new List<Id>{ svc.Id })[0];
    }

    /** Failed (or stuck in Queued for 15+ minutes): runs the file again. */
    @AuraEnabled
    public static IntakeStatus retryIntake(Id serviceId) {
        Service__c svc = loadForAction(serviceId);
        if (!canRetry(svc)) throw error('Only failed uploads, or uploads waiting for more than ' + STUCK_MINUTES + ' minutes, can be retried.');
        svc.Status__c = 'Queued';
        svc.Retry_Count__c = (svc.Retry_Count__c == null ? 0 : svc.Retry_Count__c) + 1;
        svc.Status_Message__c = 'Retry requested by ' + UserInfo.getName() + '.';
        update svc;
        // Only this file: a retry never starts the rest of its upload, so at most one file per upload runs at a time
        System.enqueueJob(new IntakeProcessor(svc.Id, false));
        return getStatus(new List<Id>{ svc.Id })[0];
    }

    // ---------------- helpers ----------------

    private static IntakeStatus toStatus(Service__c s) {
        IntakeStatus st = new IntakeStatus();
        st.serviceId = s.Id;
        st.fileName = s.Name;
        st.status = s.Status__c;
        st.message = s.Status_Message__c;
        st.requestedType = s.Requested_Type__c;
        st.createdDate = s.CreatedDate;
        st.accountId = s.Account__c;
        st.accountName = s.Account__r?.Name;
        st.opportunityId = s.Opportunity__c;
        st.opportunityName = s.Opportunity__r?.Name;
        st.jobDescriptionId = s.Job_Description__c;
        st.jobDescriptionName = s.Job_Description__r?.Name;
        st.isFinal = FINAL_STATUSES.contains(s.Status__c);
        st.channel = s.Source_Channel__c;
        st.createdByName = s.CreatedBy?.Name;
        Boolean ui = s.Source_Channel__c == CHANNEL_UI;
        // Duplicate found by name only (no contact details in the file): the recruiter may add details for a different person
        Boolean nameDuplicate = s.Status__c == 'Duplicate' && s.Status_Message__c != null
            && s.Status_Message__c.startsWith('Duplicate: ');
        st.canReview = ui && (s.Status__c == 'Needs Review' || nameDuplicate);
        st.canAttach = ui && s.Status__c == 'Duplicate' && s.Account__c != null && s.Requested_Type__c != TYPE_JD;
        st.canRetry = canRetry(s);
        return st;
    }

    private static Boolean canRetry(Service__c s) {
        if (s.Source_Channel__c != CHANNEL_UI) return false;
        if (s.Status__c == 'Failed') return true;
        return s.Status__c == 'Queued' && s.LastModifiedDate != null
            && s.LastModifiedDate < Datetime.now().addMinutes(-STUCK_MINUTES);
    }

    private static Service__c loadForAction(Id serviceId) {
        List<Service__c> rows = [
            SELECT Id, Name, Status__c, Status_Message__c, Requested_Type__c, Source_Channel__c, Account__c,
                   AI_Response__c, Retry_Count__c, LastModifiedDate, CreatedDate
            FROM Service__c WHERE Id = :serviceId
        ];
        if (rows.isEmpty()) throw error('This upload was not found.');
        if (rows[0].Source_Channel__c != CHANNEL_UI) throw error('Only Qbay Home uploads can be changed here.');
        return rows[0];
    }

    public static String extensionOf(String fileName) {
        if (String.isBlank(fileName) || !fileName.contains('.')) return '';
        return fileName.substringAfterLast('.').toLowerCase().trim();
    }

    public static String titleOf(String fileName) {
        String t = fileName.contains('.') ? fileName.substringBeforeLast('.') : fileName;
        return t.left(255);
    }

    private static AuraHandledException error(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}