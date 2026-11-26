@IsTest
private class PromptClassesTest {

    // ---------- CandidateCreationPrompt ----------

    @IsTest
    static void candidateGenerateReturnsTheAiText() {
        CandidateCreationPrompt.mockResponse = '{"documentType":"Resume","resumes":[]}';
        Assert.areEqual('{"documentType":"Resume","resumes":[]}', CandidateCreationPrompt.generate('069000000000001'));
    }

    @IsTest
    static void candidateGenerateEmptyAiTextThrows() {
        CandidateCreationPrompt.mockResponse = '';
        try {
            CandidateCreationPrompt.generate('069000000000001');
            Assert.fail('Expected an exception for an empty AI response');
        } catch (CalloutException e) {
            Assert.isTrue(e.getMessage().contains('empty response'));
        }
    }

    @IsTest
    static void candidateGenerateWithoutFileThrows() {
        try {
            CandidateCreationPrompt.generate(' ');
            Assert.fail('Expected an exception when no file is given');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('No file'));
        }
    }

    @IsTest
    static void candidateGenerateWithoutMockReturnsNull() {
        CandidateCreationPrompt.mockResponse = null;
        Assert.isNull(CandidateCreationPrompt.generate('069000000000001'));
    }

    @IsTest
    static void candidateLegacyInvocableCreatesCandidate() {
        Id svcId = IntakeTestData.newIntake('Resume', 'meena.pdf', 'resume-bytes');
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('Meena Raj', 'meena@example.com', '9876511111');
        CandidateCreationPrompt.InputWrapper w = new CandidateCreationPrompt.InputWrapper();
        w.recordId = svcId;

        Test.startTest();
        List<String> res = CandidateCreationPrompt.getPDDPromptResponses(new List<CandidateCreationPrompt.InputWrapper>{ w });
        Test.stopTest();

        Assert.areEqual(1, res.size(), 'One candidate expected: ' + res);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Personal_Email__c = 'meena@example.com']);
    }

    @IsTest
    static void textOfRejectsMissingResponse() {
        try {
            CandidateCreationPrompt.textOf(null, 'nothing came back');
            Assert.fail('Expected an exception');
        } catch (CalloutException e) {
            Assert.areEqual('nothing came back', e.getMessage());
        }
    }

    // ---------- JobDescriptionCreationPrompt ----------

    @IsTest
    static void jdGenerateReturnsTheAiText() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-bytes');
        JobDescriptionCreationPrompt.mockResponse = '{"documentType":"Job Description","jobs":[]}';
        Assert.areEqual('{"documentType":"Job Description","jobs":[]}', JobDescriptionCreationPrompt.generate(svcId));
    }

    @IsTest
    static void jdGenerateWithoutRecordThrows() {
        try {
            JobDescriptionCreationPrompt.generate(null);
            Assert.fail('Expected an exception');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('No upload record'));
        }
    }

    @IsTest
    static void jdLegacyInvocableCreatesOpportunityAndJd() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-bytes-2');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Wipro Ltd', 'Apex Developer', 'Job Description');
        JobDescriptionCreationPrompt.InputWrapper w = new JobDescriptionCreationPrompt.InputWrapper();
        w.recordId = svcId;

        Test.startTest();
        List<String> res = JobDescriptionCreationPrompt.getJDPromptResponses(new List<JobDescriptionCreationPrompt.InputWrapper>{ w });
        Test.stopTest();

        Assert.isNotNull(res, 'Legacy result expected');
        Assert.isFalse(res.isEmpty());
        Assert.areEqual(1, [SELECT COUNT() FROM Job_Description__c WHERE Source_Service__c = :svcId]);
    }

    @IsTest
    static void jdLegacyEmptyAiResponseThrowsHandled() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-bytes-3');
        JobDescriptionCreationPrompt.mockResponse = null;
        JobDescriptionCreationPrompt.InputWrapper w = new JobDescriptionCreationPrompt.InputWrapper();
        w.recordId = svcId;
        Boolean caught = false;
        try {
            JobDescriptionCreationPrompt.getJDPromptResponses(new List<JobDescriptionCreationPrompt.InputWrapper>{ w });
        } catch (AuraHandledException e) {
            caught = true;
        }
        Assert.isTrue(caught, 'Expected AuraHandledException');
    }

    @IsTest
    static void jdLegacyBadAiResponseIsWrapped() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-bytes-4');
        JobDescriptionCreationPrompt.mockResponse = '';
        JobDescriptionCreationPrompt.InputWrapper w = new JobDescriptionCreationPrompt.InputWrapper();
        w.recordId = svcId;
        Boolean caught = false;
        try {
            JobDescriptionCreationPrompt.getJDPromptResponses(new List<JobDescriptionCreationPrompt.InputWrapper>{ w });
        } catch (AuraHandledException e) {
            caught = true;
        }
        Assert.isTrue(caught, 'Expected AuraHandledException');
    }
}