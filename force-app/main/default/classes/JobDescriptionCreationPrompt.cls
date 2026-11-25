/**
 * Runs the JD_Prompt template on a Service__c (its attachments + email body).
 * generate()             -> raw AI JSON (used by IntakeProcessor, the UI upload path)
 * getJDPromptResponses() -> legacy invocable entry point kept for the email / WhatsApp paths
 */
public without sharing class JobDescriptionCreationPrompt {

    public static final String TEMPLATE = 'JD_Prompt';

    @TestVisible private static String mockResponse;

    public class InputWrapper {
        @InvocableVariable(required=true)
        public Id recordId;
    }

    public static String generate(Id serviceId) {
        if (serviceId == null) throw new IllegalArgumentException('No upload record was given to the JD prompt.');

        ConnectApi.WrappedValue docVal = new ConnectApi.WrappedValue();
        docVal.value = new Map<String, String>{ 'id' => serviceId };
        ConnectApi.EinsteinPromptTemplateGenerationsInput execInput = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        execInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        execInput.additionalConfig.applicationName = 'PromptBuilderPreview';
        execInput.isPreview = false;
        execInput.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:Document' => docVal };

        if (Test.isRunningTest() && mockResponse == null) return null;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output = Test.isRunningTest()
            ? CandidateCreationPrompt.fakeOutput(mockResponse)
            : ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, execInput);
        return CandidateCreationPrompt.textOf(output, 'The JD prompt returned an empty response.');
    }

    @InvocableMethod(label='Generate JD Prompt Responses')
    public static List<String> getJDPromptResponses(List<InputWrapper> inputs) {
        if (inputs == null || inputs.isEmpty()) return new List<String>();
        Id recordId = inputs[0] != null ? inputs[0].recordId : null;
        if (recordId == null) throw new AuraHandledException('No recordId provided to Prompt.');
        try {
            String promptResult = generate(recordId);
            if (String.isBlank(promptResult)) throw new AuraHandledException('No response generated from Prompt Builder.');
            return JobDescriptionCreationController.createJobDescriptions(promptResult, recordId);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException('Error in JD Prompt: ' + e.getMessage());
        }
    }
}