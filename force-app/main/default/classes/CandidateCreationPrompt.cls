/**
 * Runs the Candidate_CreationFile prompt template on one resume file.
 * generate()               -> raw AI JSON (used by IntakeProcessor, the UI upload path)
 * getPDDPromptResponses()  -> legacy entry points kept for the email / WhatsApp paths
 */
public without sharing class CandidateCreationPrompt {

    public static final String TEMPLATE = 'Candidate_CreationFile';

    @TestVisible private static String mockResponse;

    public class InputWrapper {
        @InvocableVariable(required=true)
        public Id recordId;
    }

    /** Returns the raw AI response for a ContentDocument. Throws if the AI returned nothing. */
    public static String generate(String contentDocumentId) {
        if (String.isBlank(contentDocumentId)) {
            throw new IllegalArgumentException('No file was given to the resume prompt.');
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput promptInput = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        ConnectApi.WrappedValue docValue = new ConnectApi.WrappedValue();
        docValue.value = new Map<String, String>{ 'id' => contentDocumentId, 'type' => 'ContentDocument' };
        promptInput.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:File' => docValue };
        promptInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        promptInput.isPreview = false;

        if (Test.isRunningTest() && mockResponse == null) return null;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = Test.isRunningTest()
            ? fakeOutput(mockResponse)
            : ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, promptInput);
        return textOf(response, 'The resume prompt returned an empty response.');
    }

    /** First generation's text, or an exception when the AI returned nothing. */
    public static String textOf(ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response, String emptyMessage) {
        if (response == null || response.generations == null || response.generations.isEmpty()
                || String.isBlank(response.generations[0].text)) {
            throw new CalloutException(emptyMessage);
        }
        return response.generations[0].text;
    }

    /** Test stand-in for the Einstein response (only called when Test.isRunningTest()). */
    public static ConnectApi.EinsteinPromptTemplateGenerationsRepresentation fakeOutput(String text) {
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation r = new ConnectApi.EinsteinPromptTemplateGenerationsRepresentation();
        r.generations = new List<ConnectApi.EinsteinLLMGenerationItemOutput>();
        ConnectApi.EinsteinLLMGenerationItemOutput g = new ConnectApi.EinsteinLLMGenerationItemOutput();
        g.text = text;
        r.generations.add(g);
        return r;
    }

    /** Legacy: one ContentDocument -> candidate Accounts (email path via AsynCandidateCreationBatch). */
    public static List<Account> getPDDPromptResponses(String contentIds) {
        if (contentIds == null) return null;
        String text = generate(contentIds);
        return CandidateCreationController.createCandidates(text, contentIds);
    }

    /** Legacy invocable shape used by CandidatePromptQueueable (WhatsApp): returns "accountId:accountName". */
    public static List<String> getPDDPromptResponses(List<InputWrapper> inputs) {
        List<String> result = new List<String>();
        if (inputs == null || inputs.isEmpty() || inputs[0] == null || inputs[0].recordId == null) return result;
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :inputs[0].recordId
        ]) {
            List<Account> accs = getPDDPromptResponses(String.valueOf(cdl.ContentDocumentId));
            if (accs == null) continue;
            for (Account a : accs) result.add(a.Id + ':' + a.Name);
        }
        return result;
    }
}
