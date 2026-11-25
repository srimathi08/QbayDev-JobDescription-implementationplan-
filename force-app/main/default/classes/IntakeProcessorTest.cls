@IsTest
private class IntakeProcessorTest {

    private static Service__c load(Id id) {
        return [SELECT Status__c, Status_Message__c, Detected_Type__c, Account__c, Opportunity__c,
                       Job_Description__c, AI_Response__c FROM Service__c WHERE Id = :id];
    }

    @IsTest
    static void resumeCreatesCandidateWithAllRecords() {
        Id svcId = IntakeTestData.newIntake('Resume', 'priya.pdf', 'resume-1');
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('PRIYA KUMAR', 'priya@example.com', '+91 98765 43210');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();

        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.areEqual('Resume', s.Detected_Type__c);
        Account a = [SELECT Name, RecordType.DeveloperName, Personal_Email__c, Phone_Normalized__c, Experience_Years__c,
                            Date_of_Birth__c, FileName__c, Account_Type__c, Current_Organization__c, LinkedIn__c
                     FROM Account WHERE Id = :s.Account__c];
        Assert.areEqual('Priya Kumar', a.Name);
        Assert.areEqual('Candidates', a.RecordType.DeveloperName);
        Assert.areEqual('priya@example.com', a.Personal_Email__c);
        Assert.areEqual('9876543210', a.Phone_Normalized__c);
        Assert.areEqual(5.5, a.Experience_Years__c);
        Assert.areEqual(Date.newInstance(1995, 5, 15), a.Date_of_Birth__c);
        Assert.areEqual('priya.pdf', a.FileName__c);
        Contact c = [SELECT FirstName, LastName, Email, Contact_Type__c, Candidate_Contact__c FROM Contact WHERE AccountId = :a.Id];
        Assert.areEqual('Priya', c.FirstName);
        Assert.areEqual('Kumar', c.LastName);
        Assert.areEqual('Candidates', c.Contact_Type__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Certification__c WHERE Candidate_Name__c = :a.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM Project_Experience__c WHERE Employee_Name__c = :a.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :a.Id]);
    }

    @IsTest
    static void reuploadMatchesByPhoneAndNeverBlanks() {
        Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account existing = new Account(Name = 'Ravi S', RecordTypeId = rt, Phone = '9876500000',
            Phone_Normalized__c = '9876500000', Designation__c = 'Architect');
        insert existing;
        Id svcId = IntakeTestData.newIntake('Resume', 'ravi.pdf', 'resume-2');
        String json = IntakeTestData.resumeJson('Ravi Shankar', null, '+91-98765-00000');
        CandidateCreationPrompt.mockResponse = json;
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();

        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.areEqual(existing.Id, s.Account__c);
        Account a = [SELECT Name, Designation__c, Current_Location__c FROM Account WHERE Id = :existing.Id];
        Assert.areEqual('Ravi S', a.Name, 'existing candidates are never renamed');
        Assert.areEqual('Architect', a.Designation__c, 'existing values are kept');
        Assert.areEqual('Chennai', a.Current_Location__c, 'blank fields are filled');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE RecordTypeId = :rt]);
    }

    @IsTest
    static void jdUploadedAsResumeIsRejected() {
        Id svcId = IntakeTestData.newIntake('Resume', 'jd.pdf', 'jd-1');
        CandidateCreationPrompt.mockResponse = '{"documentType":"Job Description","resumes":[]}';
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c);
        Assert.isTrue(s.Status_Message__c.contains('Add Job Description'));
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void resumeWithoutContactDetailsIsRejected() {
        Id svcId = IntakeTestData.newIntake('Resume', 'blank.pdf', 'blank');
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('', null, null);
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Assert.areEqual('Rejected', load(svcId).Status__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
        Assert.areEqual(0, [SELECT COUNT() FROM Contact]);
    }

    @IsTest
    static void unreadableAiResponseIsRejected() {
        Id svcId = IntakeTestData.newIntake('Resume', 'x.pdf', 'x');
        CandidateCreationPrompt.mockResponse = 'Sorry, I cannot read this file';
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Assert.areEqual('Rejected', load(svcId).Status__c);
    }

    @IsTest
    static void sameFileTwiceIsDuplicate() {
        Id first = IntakeTestData.newIntake('Resume', 'same.pdf', 'identical-bytes');
        Service__c f = [SELECT Id FROM Service__c WHERE Id = :first];
        f.Status__c = 'Completed';
        update f;
        Id second = IntakeTestData.newIntake('Resume', 'same-again.pdf', 'identical-bytes');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Assert.areEqual('Duplicate', load(second).Status__c);
    }

    @IsTest
    static void alreadyProcessedIntakeIsNotRunAgain() {
        Id svcId = IntakeTestData.newIntake('Resume', 'done.pdf', 'done');
        Service__c s = [SELECT Id FROM Service__c WHERE Id = :svcId];
        s.Status__c = 'Completed';
        update s;
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('A B', 'ab@example.com', null);
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void jdCreatesClientOpportunityAndJd() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-bytes');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Infosys Ltd.', 'Salesforce Developer', 'Job Description');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();

        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Account client = [SELECT Name, RecordType.DeveloperName, Account_Type__c FROM Account WHERE Id = :s.Account__c];
        Assert.areNotEqual('Candidates', client.RecordType?.DeveloperName);
        Assert.areEqual('Customer', client.Account_Type__c);
        Opportunity o = [SELECT Name, StageName, IsClosed, Experience_Required__c, Resource_Needed__c, Job_type__c,
                                JD_Lookup__c, Source_Of_Requirement__c, Original_Budget_Amount__c, Original_Currency__c,
                                CloseDate, Identified_Budget__c
                         FROM Opportunity WHERE Id = :s.Opportunity__c];
        Assert.areEqual('Salesforce Developer', o.Name);
        Assert.areEqual('3', o.Experience_Required__c);
        Assert.areEqual(2, o.Resource_Needed__c);
        Assert.areEqual('Remote', o.Job_type__c);
        Assert.areEqual(s.Job_Description__c, o.JD_Lookup__c);
        Assert.areEqual('Qbay Home Upload', o.Source_Of_Requirement__c);
        Assert.areEqual(1500, o.Original_Budget_Amount__c);
        Assert.areEqual('OMR', o.Original_Currency__c);
        Assert.areEqual(Date.newInstance(2030, 1, 15), o.CloseDate);
        Assert.areEqual(1800000, o.Identified_Budget__c);
        Job_Description__c jd = [SELECT AR__c, Other_Location__c, Seniority__c, Source_Service__c, FileName__c
                                 FROM Job_Description__c WHERE Id = :s.Job_Description__c];
        Assert.areEqual(2, jd.AR__c);
        Assert.areEqual('Remote', jd.Other_Location__c);
        Assert.areEqual(svcId, jd.Source_Service__c);
    }

    @IsTest
    static void sameJdAgainReusesOpenOpportunityAndClient() {
        Id first = IntakeTestData.newIntake('Job Description', 'jd1.pdf', 'jd-a');
        Id second = IntakeTestData.newIntake('Job Description', 'jd2.pdf', 'jd-b');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Infosys Ltd.', 'Salesforce Developer', 'Job Description');
        JobDescriptionCreationController.process(JobDescriptionCreationPrompt.mockResponse, first, true);
        Test.startTest();
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('INFOSYS LIMITED', 'Salesforce Developer', 'Job Description');
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Assert.areEqual('Completed', load(second).Status__c, load(second).Status_Message__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity]);
        Assert.areEqual(1, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void closedOpportunityIsNeverUpdated() {
        Id first = IntakeTestData.newIntake('Job Description', 'jd1.pdf', 'jd-c');
        String json = IntakeTestData.jdJson('Acme', 'QA Engineer', 'Job Description');
        JobDescriptionCreationController.Result r = JobDescriptionCreationController.process(json, first, true);
        Opportunity o = new Opportunity(Id = r.opportunityId, StageName = 'Closed Lost', Loss_Reason__c = 'Other');
        update o;
        Id second = IntakeTestData.newIntake('Job Description', 'jd2.pdf', 'jd-d');
        JobDescriptionCreationPrompt.mockResponse = json;
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void jdWithoutCompanyIsRejected() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-e');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Temp Holding Account', 'Developer', 'Job Description');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Assert.areEqual('Rejected', load(svcId).Status__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void resumeUploadedAsJdIsRejected() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'cv.pdf', 'cv');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Acme', 'Developer', 'Resume');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c);
        Assert.areEqual('Resume', s.Detected_Type__c);
    }

    @IsTest
    static void skillsAreNotDuplicated() {
        Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account a = new Account(Name = 'Skill Test', RecordTypeId = rt);
        insert a;
        insert new Skill__c(Skill_Name__c = 'Apex', Active__c = true);
        List<Map<String, Object>> skills = new List<Map<String, Object>>{
            new Map<String, Object>{ 'name' => 'apex', 'proficiency' => 'Expert' },
            new Map<String, Object>{ 'name' => 'Node.js', 'proficiency' => 'Beginner' },
            new Map<String, Object>{ 'name' => 'NodeJS', 'proficiency' => 'Beginner' }
        };
        Test.startTest();
        System.enqueueJob(new CandidateSkillQueueable(new List<Account>{ a }, new List<List<Map<String, Object>>>{ skills }));
        Test.stopTest();
        Assert.areEqual(2, [SELECT COUNT() FROM Skill__c]);
        Assert.areEqual(2, [SELECT COUNT() FROM Employee_Skill__c WHERE Employee_Name__c = :a.Id]);
    }
}