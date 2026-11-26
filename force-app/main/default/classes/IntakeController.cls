/**
 * Entry point for the Qbay Home uploaders and the intake inbox.
 * New upload path (25-11-2026): the standard file upload stores the files, then submitUploadedFiles()
 * creates one intake per file and starts the first; the rest run one after another (IntakeProcessor finalizer).
 * Inbox actions for Qbay Home uploads: completeReview (Needs Review), attachToExisting (Duplicate), retryIntake,
 * resolveJdDuplicate (Needs Review for a possible duplicate JD, T-071).
 * Email and WhatsApp intakes are shown read-only; their processing is owned by their own classes.
 * 26-11-2026: the old one-call upload (submitFile, 3 MB, no review step) was removed; nothing called it.
 * Idempotency: submitUploadedFiles returns the existing intakes when the same upload key is sent again.
 */
public with sharing class IntakeController {

    public static final String TYPE_RESUME = 'Resume';
    public static final String TYPE_JD = 'Job Description';
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
        /** Possible duplicate JD: the recruiter picks "Use existing" or "Create new". */
        @AuraEnabled public Boolean canChooseJd;
        /** Queued file of a multi-file upload: "Waiting, file 3 of 5". Null otherwise. */
        @AuraEnabled public Integer batchPosition;
        @AuraEnabled public Integer batchTotal;
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
        + 'Source_Channel__c, CreatedBy.Name, CreatedById, Account__c, Account__r.Name, Account__r.RecordType.DeveloperName, '
        + 'Opportunity__c, Opportunity__r.Name, '
        + 'Job_Description__c, Job_Description__r.Name, Retry_Count__c, Upload_Batch__c';

    /** Current status of the given intakes, for the LWC to refresh. Not cacheable on purpose. */
    @AuraEnabled
    public static List<IntakeStatus> getStatus(List<Id> serviceIds) {
        List<IntakeStatus> out = new List<IntakeStatus>();
        if (serviceIds == null || serviceIds.isEmpty()) return out;
        Map<Id, Service__c> byId = new Map<Id, Service__c>(
            (List<Service__c>) Database.query('SELECT ' + STATUS_FIELDS + ' FROM Service__c WHERE Id IN :serviceIds')
        );
        List<Service__c> rows = new List<Service__c>();
        for (Id i : serviceIds) {
            Service__c s = byId.get(i);
            if (s != null) rows.add(s);
        }
        return statusesOf(rows);
    }

    /** Statuses in the given order, with the queue position of waiting files ("file 3 of 5"). */
    private static List<IntakeStatus> statusesOf(List<Service__c> rows) {
        List<IntakeStatus> out = new List<IntakeStatus>();
        Set<String> batches = new Set<String>();
        for (Service__c s : rows) {
            out.add(toStatus(s));
            if (s.Status__c == 'Queued' && String.isNotBlank(s.Upload_Batch__c)) batches.add(s.Upload_Batch__c);
        }
        if (batches.isEmpty()) return out;
        Map<Id, Integer> position = new Map<Id, Integer>();
        Map<String, Integer> total = new Map<String, Integer>();
        for (Service__c b : [
            SELECT Id, Upload_Batch__c FROM Service__c
            WHERE Upload_Batch__c IN :batches
            ORDER BY CreatedDate ASC, Name ASC
            LIMIT 2000
        ]) {
            Integer n = total.containsKey(b.Upload_Batch__c) ? total.get(b.Upload_Batch__c) + 1 : 1;
            total.put(b.Upload_Batch__c, n);
            position.put(b.Id, n);
        }
        for (Integer k = 0; k < rows.size(); k++) {
            Service__c s = rows[k];
            if (s.Status__c != 'Queued' || String.isBlank(s.Upload_Batch__c)) continue;
            Integer t = total.get(s.Upload_Batch__c);
            if (t == null || t < 2) continue;
            out[k].batchPosition = position.get(s.Id);
            out[k].batchTotal = t;
        }
        return out;
    }

    /** Uploads the current user made today (replaces "View Today Uploads"). */
    @AuraEnabled
    public static List<IntakeStatus> getMyUploadsToday(String requestedType) {
        return statusesOf([
            SELECT Id, Name, Status__c, Status_Message__c, Requested_Type__c, CreatedDate, LastModifiedDate,
                   Source_Channel__c, CreatedBy.Name, CreatedById, Account__c, Account__r.Name, Account__r.RecordType.DeveloperName,
                   Opportunity__c, Opportunity__r.Name, Job_Description__c, Job_Description__r.Name, Retry_Count__c, Upload_Batch__c
            FROM Service__c
            WHERE CreatedById = :UserInfo.getUserId()
              AND CreatedDate = TODAY
              AND Source_Channel__c = 'UI Upload'
              AND Requested_Type__c = :requestedType
            ORDER BY CreatedDate DESC
            LIMIT 200
        ]);
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
        List<String> types = new List<String>();
        if (contentDocumentIds != null) {
            for (Integer k = 0; k < contentDocumentIds.size(); k++) types.add(requestedType);
        }
        return submitUploadedFilesWithTypes(contentDocumentIds, types, batchKey);
    }

    // =====================================================================
    // Review step (25-11-2026): the recruiter sees each uploaded file, can remove it or set its type,
    // and then starts processing. Nothing is created and no AI call is made before "Start processing".
    // =====================================================================

    public class UploadedFile {
        @AuraEnabled public Id documentId;
        @AuraEnabled public String fileName;
        @AuraEnabled public String extension;
        @AuraEnabled public Integer sizeBytes;
        @AuraEnabled public String problem; // null = OK
        /** Same file already waiting in Needs Review / being read: the full sentence for the recruiter. */
        @AuraEnabled public String pendingMessage;
    }

    /**
     * Qbay Home uploads of the same file (same checksum) that are not finished: waiting in Needs Review
     * or still being read. A second copy is refused so the recruiter finishes the first one (26-11-2026).
     */
    private static Map<String, Service__c> pendingSameFiles(Set<String> checksums, Set<Id> exclude) {
        Map<String, Service__c> out = new Map<String, Service__c>();
        checksums.remove(null);
        if (checksums.isEmpty()) return out;
        for (Service__c s : [
            SELECT Id, Status__c, CreatedDate, File_Checksum__c FROM Service__c
            WHERE File_Checksum__c IN :checksums AND Source_Channel__c = :CHANNEL_UI
              AND Status__c IN ('Needs Review', 'Queued') AND Id NOT IN :exclude
            ORDER BY CreatedDate ASC
        ]) {
            if (!out.containsKey(s.File_Checksum__c)) out.put(s.File_Checksum__c, s);
        }
        return out;
    }

    /** "is already waiting in Needs Review (uploaded 26 Nov 2026 13:20). Please finish it in the Intake inbox." */
    public static String pendingText(Service__c earlier) {
        String uploadedOn = ' (uploaded ' + earlier.CreatedDate.format('dd MMM yyyy HH:mm') + ')';
        return earlier.Status__c == 'Needs Review'
            ? 'This file is already waiting in Needs Review' + uploadedOn + '. Please finish it in the Intake inbox instead of uploading it again.'
            : 'This file is already being processed' + uploadedOn + '. Please wait for its result in the Intake inbox.';
    }

    /** Name, type, size and the upload checks of files the current user just uploaded. */
    @AuraEnabled
    public static List<UploadedFile> getUploadedFileDetails(List<Id> contentDocumentIds) {
        List<UploadedFile> out = new List<UploadedFile>();
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) return out;
        UploadSettings cfg = getUploadSettings();
        Map<Id, ContentVersion> byDoc = new Map<Id, ContentVersion>();
        for (ContentVersion cv : [
            SELECT ContentDocumentId, Title, FileExtension, ContentSize, OwnerId, Checksum
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds AND IsLatest = true AND OwnerId = :UserInfo.getUserId()
        ]) {
            byDoc.put(cv.ContentDocumentId, cv);
        }
        Set<String> sums = new Set<String>();
        for (ContentVersion cv : byDoc.values()) sums.add(cv.Checksum);
        Map<String, Service__c> pending = pendingSameFiles(sums, new Set<Id>());
        for (Id docId : contentDocumentIds) {
            ContentVersion cv = byDoc.get(docId);
            if (cv == null) continue;
            UploadedFile f = new UploadedFile();
            f.documentId = docId;
            f.extension = cv.FileExtension == null ? '' : cv.FileExtension.toLowerCase();
            f.fileName = cv.FileExtension == null ? cv.Title : cv.Title + '.' + cv.FileExtension;
            f.sizeBytes = cv.ContentSize;
            if (!ALLOWED_EXTENSIONS.contains(f.extension)) {
                f.problem = 'Not supported (PDF or DOCX only)';
            } else if (cv.ContentSize == null || cv.ContentSize == 0) {
                f.problem = 'Empty file';
            } else if (cv.ContentSize > cfg.maxFileMb * 1024 * 1024) {
                f.problem = 'Larger than ' + cfg.maxFileMb + ' MB';
            } else if (pending.containsKey(cv.Checksum)) {
                Service__c earlier = pending.get(cv.Checksum);
                f.problem = earlier.Status__c == 'Needs Review' ? 'Already waiting in Needs Review' : 'Already being processed';
                f.pendingMessage = pendingText(earlier);
            }
            out.add(f);
        }
        return out;
    }

    /** Removes a file the current user uploaded but has not started processing yet. */
    @AuraEnabled
    public static void removeUploadedFile(Id contentDocumentId) {
        if (contentDocumentId == null) return;
        List<ContentDocument> docs = [SELECT Id, OwnerId FROM ContentDocument WHERE Id = :contentDocumentId];
        if (docs.isEmpty()) return; // already gone
        if (docs[0].OwnerId != UserInfo.getUserId()) throw error('You can only remove files you uploaded yourself.');
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId FROM ContentDocumentLink WHERE ContentDocumentId = :contentDocumentId
        ]) {
            if (l.LinkedEntityId.getSObjectType() == Service__c.SObjectType) {
                throw error('This file is already being processed and cannot be removed here.');
            }
        }
        delete docs;
    }

    /**
     * Same as submitUploadedFiles, with a type per file ('Auto', 'Resume' or 'Job Description').
     * All files stay in one upload, so they are still read one after another.
     */
    @AuraEnabled
    public static List<IntakeStatus> submitUploadedFilesWithTypes(List<Id> contentDocumentIds, List<String> requestedTypes, String batchKey) {
        return submitUploadedFilesWithClient(contentDocumentIds, requestedTypes, batchKey, null);
    }

    /**
     * Same as submitUploadedFilesWithTypes, plus the optional client name typed on screen (26-11-2026).
     * It is kept on Job Description and Auto-detect files (Service__c.Client_Name__c) and used only when
     * the JD itself names no company.
     */
    @AuraEnabled
    public static List<IntakeStatus> submitUploadedFilesWithClient(List<Id> contentDocumentIds, List<String> requestedTypes,
            String batchKey, String clientName) {
        String client = String.isBlank(clientName) ? null : clientName.normalizeSpace().left(255);
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) throw error('No files were uploaded.');
        if (String.isBlank(batchKey)) throw error('Missing upload key. Please refresh the page and try again.');
        if (requestedTypes == null || requestedTypes.size() != contentDocumentIds.size()) throw error('Unknown upload type.');
        for (String t : requestedTypes) {
            if (t != TYPE_AUTO && t != TYPE_RESUME && t != TYPE_JD) throw error('Unknown upload type.');
        }
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
        Set<String> sums = new Set<String>();
        for (ContentVersion cv : versionByDoc.values()) sums.add(cv.Checksum);
        Map<String, Service__c> pending = pendingSameFiles(sums, new Set<Id>());
        Set<String> seenInUpload = new Set<String>();

        List<Service__c> services = new List<Service__c>();
        List<ContentVersion> fileOf = new List<ContentVersion>();
        Set<Id> removeDocs = new Set<Id>();
        Integer accepted = 0;
        Integer i = 0;
        Integer pos = -1;
        for (Id docId : contentDocumentIds) {
            pos++;
            String requestedType = requestedTypes[pos];
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
            } else if (pending.containsKey(cv.Checksum)) {
                reason = pendingText(pending.get(cv.Checksum)) + ' Nothing was created.';
            } else if (cv.Checksum != null && seenInUpload.contains(cv.Checksum)) {
                reason = '"' + fileName + '" is the same file as another file in this upload, so it was read only once. Nothing was created.';
            } else if (accepted >= cfg.maxFiles) {
                reason = 'Only ' + cfg.maxFiles + ' files can be uploaded at a time. Please upload "' + fileName + '" again in a new upload. Nothing was created.';
            } else {
                accepted++;
                if (cv.Checksum != null) seenInUpload.add(cv.Checksum);
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
                File_Checksum__c = reason == null ? cv.Checksum : null,
                Client_Name__c = requestedType == TYPE_RESUME ? null : client
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
        return statusesOf((List<Service__c>) Database.query(q));
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
        if ([SELECT COUNT() FROM Account WHERE Id = :svc.Account__c AND RecordType.DeveloperName = 'Candidates'] == 0) {
            throw error('This upload is linked to a client, not a candidate. A resume cannot be attached to it.');
        }
        ContentVersion file = IntakeProcessor.latestFile(svc.Id);
        if (file == null) throw error('The file of this upload was not found.');
        CandidateCreationController.linkFile(file.ContentDocumentId, new Set<Id>{ svc.Account__c });
        svc.Status__c = 'Completed';
        svc.Status_Message__c = ('Resume attached to the existing candidate by ' + UserInfo.getName() + '. No new candidate was created.').left(32000);
        update svc;
        return getStatus(new List<Id>{ svc.Id })[0];
    }

    /**
     * Possible duplicate JD (Needs Review, T-071): the recruiter keeps the existing Opportunity (only its empty
     * fields are filled, the file is linked) or creates a new one. The saved AI result is reused: no new AI call.
     */
    @AuraEnabled
    public static IntakeStatus resolveJdDuplicate(Id serviceId, Boolean useExisting) {
        Service__c svc = loadForAction(serviceId);
        if (svc.Status__c != 'Needs Review' || svc.Requested_Type__c != TYPE_JD) {
            throw error('This upload is not waiting for a duplicate Job Description decision.');
        }
        if (String.isBlank(svc.AI_Response__c)) throw error('The saved AI result for this file is missing. Please upload the file again.');
        String decision = useExisting == true
            ? JobDescriptionCreationController.DECISION_EXISTING
            : JobDescriptionCreationController.DECISION_NEW;
        Savepoint sp = Database.setSavepoint();
        try {
            JobDescriptionCreationController.Result r =
                JobDescriptionCreationController.process(svc.AI_Response__c, svc.Id, true, decision);
            svc.Account__c = r.accountId;
            svc.Opportunity__c = r.opportunityId;
            svc.Job_Description__c = r.jobDescriptionId;
            svc.Detected_Type__c = TYPE_JD;
            svc.Status__c = 'Completed';
            svc.Status_Message__c = ((useExisting == true
                    ? 'Kept the existing Opportunity (chosen by ' + UserInfo.getName() + '). '
                    : 'New Opportunity created (chosen by ' + UserInfo.getName() + '). ')
                + (r.summary == null ? '' : r.summary)).left(32000);
            update svc;
        } catch (IntakeProcessor.RejectException rej) {
            Database.rollback(sp);
            throw error(rej.getMessage());
        } catch (Exception e) {
            Database.rollback(sp);
            UtilityClass.createElog(e, 'IntakeController', 'resolveJdDuplicate');
            throw error('Could not save the Job Description: ' + e.getMessage());
        }
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
        // Auto upload answered from an earlier same file: no type stored, but a linked JD means it is a JD
        if (String.isBlank(st.requestedType) && s.Job_Description__c != null) st.requestedType = TYPE_JD;
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
        Boolean jd = st.requestedType == TYPE_JD;
        st.canReview = ui && !jd && (s.Status__c == 'Needs Review' || nameDuplicate);
        st.canChooseJd = ui && jd && s.Status__c == 'Needs Review' && s.Opportunity__c != null;
        // Attach a resume only to a candidate Account, never to a client Account of a JD
        st.canAttach = ui && s.Status__c == 'Duplicate' && s.Account__c != null && st.requestedType != TYPE_JD
            && s.Account__r?.RecordType?.DeveloperName == 'Candidates';
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
