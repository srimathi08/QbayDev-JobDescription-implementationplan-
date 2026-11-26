/**
 * Legacy resume upload controller. The Qbay Home "Add Candidate" tab now uses IntakeController.
 * Kept because the email (parseEmail) and WhatsApp (WhatsAppWebhook) paths still call it.
 */
public class AttachmentController {

    @AuraEnabled
    public static List<String> getPrompt(String recordId) {
        if (String.isBlank(recordId)) {
            throw new AuraHandledException('Service Id is required');
        }
        try {
            Database.executeBatch(new AsynCandidateCreationBatch((Id) recordId), 1);
            return new List<String>{ 'Batch Started Successfully' };
        } catch (Exception e) {
            UtilityClass.createElog(e, 'AttachmentController', 'getPrompt');
            AuraHandledException ae = new AuraHandledException('Error while generating prompt: ' + e.getMessage());
            ae.setMessage('Error while generating prompt: ' + e.getMessage());
            throw ae;
        }
    }

    @AuraEnabled
    public static String createparent(String fileName) {
        Service__c sr = new Service__c();
        if (String.isNotBlank(fileName)) {
            sr.Name = fileName.left(80);
            sr.Email_Subject__c = fileName;
        } else {
            sr.Name = 'No File Name';
        }
        insert sr;
        return sr.Id;
    }

    /** Creates a file on the record. Throws a readable error instead of returning null. */
    @AuraEnabled
    public static String uploadFile(String base64, String filename, String recordId) {
        ContentVersion cv = createContentVersion(base64, filename);
        ContentDocumentLink cdl = createContentLink(cv == null ? null : cv.Id, recordId);
        if (cv == null || cdl == null) {
            AuraHandledException ae = new AuraHandledException('Could not save the file ' + filename);
            ae.setMessage('Could not save the file ' + filename);
            throw ae;
        }
        return cdl.Id;
    }

    private static ContentVersion createContentVersion(String base64, String filename) {
        if (String.isBlank(base64) || String.isBlank(filename)) return null;
        ContentVersion cv = new ContentVersion();
        cv.VersionData = EncodingUtil.base64Decode(base64);
        cv.Title = filename.contains('.') ? filename.substringBeforeLast('.') : filename;
        cv.PathOnClient = filename;
        try {
            insert cv;
            return cv;
        } catch (DmlException e) {
            UtilityClass.createElog(e, 'AttachmentController', 'createContentVersion');
            return null;
        }
    }

    public static ContentDocumentLink createContentLink(String contentVersionId, String recordId) {
        if (contentVersionId == null || recordId == null) return null;
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :contentVersionId].ContentDocumentId;
        cdl.LinkedEntityId = recordId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        try {
            insert cdl;
            return cdl;
        } catch (DmlException e) {
            UtilityClass.createElog(e, 'AttachmentController', 'createContentLink');
            return null;
        }
    }

    public static ContentDocumentLink createContentLinkwhatsapp(String contentVersionId, String recordId) {
        if (contentVersionId == null || recordId == null) return null;
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :contentVersionId].ContentDocumentId;
        cdl.LinkedEntityId = recordId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        insert cdl;
        return cdl;
    }

    /** Legacy "today uploads": candidate Accounts created today with their files. */
    @AuraEnabled
    public static List<Map<String, Object>> getTodayUploadedFiles() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        Map<Id, String> accNameMap = new Map<Id, String>();
        for (Account a : [
            SELECT Id, Name FROM Account
            WHERE CreatedDate = TODAY AND RecordType.DeveloperName = 'Candidates'
        ]) {
            accNameMap.put(a.Id, a.Name);
        }
        if (accNameMap.isEmpty()) return result;
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.CreatedDate
            FROM ContentDocumentLink WHERE LinkedEntityId IN :accNameMap.keySet()
        ]) {
            result.add(new Map<String, Object>{
                'id' => cdl.ContentDocumentId,
                'accountName' => accNameMap.get(cdl.LinkedEntityId),
                'accountUrl' => '/' + cdl.LinkedEntityId,
                'fileName' => cdl.ContentDocument.Title,
                'createdDate' => cdl.ContentDocument.CreatedDate
            });
        }
        return result;
    }
}