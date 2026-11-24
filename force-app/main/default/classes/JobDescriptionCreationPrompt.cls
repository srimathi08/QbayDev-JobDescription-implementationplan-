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
        if (Test.isRunningTest()) return mockResponse;

        ConnectApi.WrappedValue docVal = new ConnectApi.WrappedValue();
        docVal.value = new Map<String, String>{ 'id' => serviceId };
        ConnectApi.EinsteinPromptTemplateGenerationsInput execInput = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        execInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        execInput.additionalConfig.applicationName = 'PromptBuilderPreview';
        execInput.isPreview = false;
        execInput.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:Document' => docVal };

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, execInput);
        if (output == null || output.generations == null || output.generations.isEmpty()
                || String.isBlank(output.generations[0].text)) {
            throw new CalloutException('The JD prompt returned an empty response.');
        }
        return output.generations[0].text;
    }

    @InvocableMethod(label='Generate JD Prompt Responses')
    public static List<String> getJDPromptResponses(List<InputWrapper> inputs) {
        if (inputs == null || inputs.isEmpty() || inputs[0] == null || inputs[0].recordId == null) {
            return new List<String>();
        }
        Id recordId = inputs[0].recordId;
        try {
            String promptResult = generate(recordId);
            return JobDescriptionCreationController.createJobDescriptions(promptResult, recordId);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException('Error in JD Prompt: ' + e.getMessage());
        }
    }
}
