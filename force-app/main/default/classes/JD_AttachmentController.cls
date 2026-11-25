/**
 * Legacy JD upload controller. The Qbay Home "Add Job Description" tab now uses IntakeController.
 * Kept for compatibility with existing callers and tests.
 */
public class JD_AttachmentController {

    @AuraEnabled
    public static List<String> getPrompt(String recordId) {
        try {
            JobDescriptionCreationPrompt.InputWrapper w = new JobDescriptionCreationPrompt.InputWrapper();
            w.recordId = recordId;
            List<String> responses = JobDescriptionCreationPrompt.getJDPromptResponses(
                new List<JobDescriptionCreationPrompt.InputWrapper>{ w });
            if (responses == null || responses.isEmpty()) {
                throw new IntakeProcessor.RejectException('No job description could be created from this file.');
            }
            return responses;
        } catch (Exception e) {
            UtilityClass.createElog(e, 'JD_AttachmentController', 'getPrompt');
            AuraHandledException ae = new AuraHandledException('Error while generating prompt: ' + e.getMessage());
            ae.setMessage('Error while generating prompt: ' + e.getMessage());
            throw ae;
        }
    }

    @AuraEnabled
    public static String createParent(String fileName) {
        Service__c jdSample = new Service__c();
        jdSample.Name = String.isBlank(fileName) ? 'No File Name' : fileName.left(80);
        insert jdSample;
        return jdSample.Id;
    }

    @AuraEnabled
    public static String uploadFile(String base64, String filename, String recordId) {
        ContentVersion cv = createContentVersion(base64, filename);
        ContentDocumentLink cdl = createContentLink(cv != null ? cv.Id : null, recordId);
        // Legacy contract: null when the file could not be saved (error is logged by the helpers).
        if (cv == null || cdl == null) return null;
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
            UtilityClass.createElog(e, 'JD_AttachmentController', 'createContentVersion');
            return null;
        }
    }

    public static ContentDocumentLink createContentLink(String contentVersionId, String recordId) {
        if (contentVersionId == null || recordId == null) return null;
        Id contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :contentVersionId].ContentDocumentId;
        ContentDocumentLink cdl = new ContentDocumentLink(
            ContentDocumentId = contentDocumentId,
            LinkedEntityId = recordId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        try {
            insert cdl;
            return cdl;
        } catch (DmlException e) {
            UtilityClass.createElog(e, 'JD_AttachmentController', 'createContentLink');
            return null;
        }
    }
}