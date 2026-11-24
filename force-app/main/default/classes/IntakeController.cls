/**
 * Entry point for the Qbay Home uploaders (Add Candidate / Add Job Description).
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
    }

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
        Map<Id, Service__c> byId = new Map<Id, Service__c>([
            SELECT Id, Name, Status__c, Status_Message__c, Requested_Type__c, CreatedDate,
                   Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name,
                   Job_Description__c, Job_Description__r.Name
            FROM Service__c WHERE Id IN :serviceIds
        ]);
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
            SELECT Id, Name, Status__c, Status_Message__c, Requested_Type__c, CreatedDate,
                   Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name,
                   Job_Description__c, Job_Description__r.Name
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
        st.isFinal = new Set<String>{ 'Completed', 'Duplicate', 'Rejected', 'Failed' }.contains(s.Status__c);
        return st;
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
