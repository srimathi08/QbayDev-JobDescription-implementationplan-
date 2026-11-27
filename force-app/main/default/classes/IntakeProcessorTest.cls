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
    static void samePhoneDifferentNameCreatesANewCandidate() {
        // 25-11-2026: "dummy resume.pdf" (John Smith) had Rahul Sharma's phone and was merged into Rahul Sharma
        Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account rahul = new Account(Name = 'Rahul Sharma', RecordTypeId = rt, Phone = '9876543210',
            Phone_Normalized__c = '9876543210', Years_of_Experience__c = '2 years');
        insert rahul;
        Id svcId = IntakeTestData.newIntake('Resume', 'john.pdf', 'john-1');
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('John Smith', null, '9876543210');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();

        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.areNotEqual(rahul.Id, s.Account__c, 'a different person is never merged by phone alone');
        Assert.areEqual('John Smith', [SELECT Name FROM Account WHERE Id = :s.Account__c].Name);
        Assert.isTrue(s.Status_Message__c.contains('also on the existing candidate Rahul Sharma'), s.Status_Message__c);
        Account r = [SELECT Name, Years_of_Experience__c FROM Account WHERE Id = :rahul.Id];
        Assert.areEqual('Rahul Sharma', r.Name);
        Assert.areEqual('2 years', r.Years_of_Experience__c, 'the existing candidate is not touched');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :rahul.Id]);
    }

    @IsTest
    static void phoneMatchNameCheckIsLenient() {
        Assert.isTrue(CandidateCreationController.sameName('Rahul Sharma', 'RAHUL SHARMA'));
        Assert.isTrue(CandidateCreationController.sameName('Rahul Sharma', 'R. Sharma'));
        Assert.isTrue(CandidateCreationController.sameName('Ravi S', 'Ravi Shankar'));
        Assert.isFalse(CandidateCreationController.sameName('Rahul Sharma', 'John Smith'));
        // 26-11-2026: one shared word is not enough (these were wrongly merged into "Arjun Kumar")
        Assert.isFalse(CandidateCreationController.sameName('Arjun Kumar', 'Arjun Menon'));
        Assert.isFalse(CandidateCreationController.sameName('Arjun Kumar', 'Arun Kumar'));
        Assert.isTrue(CandidateCreationController.sameName('Rahul Kumar Sharma', 'Rahul Sharma'));
        Assert.isTrue(CandidateCreationController.sameName('Arjun', 'Arjun Kumar'));
        Assert.isFalse(CandidateCreationController.sameName('A', 'Arjun Kumar'));
        Assert.isFalse(CandidateCreationController.sameName(null, 'John Smith'));
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
        Assert.isTrue(s.Status_Message__c.contains('upload it as a Job Description'));
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
        // 27-11-2026: Qbay Home uploads ask for the client name instead of rejecting; nothing is created yet
        Assert.areEqual('Needs Review', load(svcId).Status__c);
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

    // ---------- 25-11-2026: duplicate message for resumes without contact details ----------

    private static String nameOnlyJson(String name) {
        return '{"documentType":"Resume","resumes":[{"account":{"name":"' + name
            + '","email":"","phone":"","linkedin":"","summary":"Business Analyst"}}]}';
    }

    private static Account newCandidate(String name) {
        Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account a = new Account(Name = name, RecordTypeId = rt);
        Database.DMLOptions opts = new Database.DMLOptions();
        opts.DuplicateRuleHeader.allowSave = true;
        Database.insert(a, opts);
        return a;
    }

    @IsTest
    static void nameOnlyResumeOfExistingCandidateIsDuplicate() {
        Account existing = newCandidate('Rahul Venugopal');
        Id svcId = IntakeTestData.newIntake('Resume', 'rahul.pdf', 'rahul-bytes');
        CandidateCreationPrompt.mockResponse = nameOnlyJson('Rahul Venugopal');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Duplicate', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.startsWith('Duplicate: a candidate named Rahul Venugopal already exists'), s.Status_Message__c);
        Assert.areEqual(existing.Id, s.Account__c, 'the upload is linked to the existing candidate');
        Assert.areEqual(1, [SELECT COUNT() FROM Account]);
        Assert.areEqual(0, [SELECT COUNT() FROM Contact]);
    }

    @IsTest
    static void nameOnlyResumeWithSeveralSameNamesIsDuplicate() {
        newCandidate('Rahul Venugopal');
        newCandidate('Rahul Venugopal');
        Id svcId = IntakeTestData.newIntake('Resume', 'rahul.pdf', 'rahul-bytes-2');
        CandidateCreationPrompt.mockResponse = nameOnlyJson('Rahul Venugopal');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Duplicate', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.contains('2 candidates named Rahul Venugopal'), s.Status_Message__c);
        Assert.areEqual(2, [SELECT COUNT() FROM Account]);
        Assert.isNotNull(s.Account__c);
    }

    @IsTest
    static void nameOnlyResumeOfNewPersonNeedsReview() {
        Id svcId = IntakeTestData.newIntake('Resume', 'new.pdf', 'new-bytes');
        CandidateCreationPrompt.mockResponse = nameOnlyJson('Meena Raj');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Needs Review', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.contains('Found the name "Meena Raj"'), s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.contains('click Continue'), s.Status_Message__c);
        Assert.isNotNull(s.AI_Response__c, 'the AI result is kept for the recruiter');
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void nameOnlyResumeByEmailIsStillRejected() {
        Id svcId = IntakeTestData.newIntake('Resume', 'new.pdf', 'new-bytes-email');
        Service__c e = new Service__c(Id = svcId, Source_Channel__c = 'Email');
        update e;
        CandidateCreationPrompt.mockResponse = nameOnlyJson('Meena Raj');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c, 'email intakes keep the old behaviour');
        Assert.isTrue(s.Status_Message__c.contains('inside an image or icon'), s.Status_Message__c);
    }

    @IsTest
    static void sameFileAsLegacyUploadIsDuplicate() {
        Account existing = newCandidate('Legacy Person');
        Id second = IntakeTestData.newIntake('Resume', 'legacy-again.pdf', 'legacy-bytes');
        String checksum = [SELECT File_Checksum__c FROM Service__c WHERE Id = :second].File_Checksum__c;
        // An upload made before v1: no Requested_Type__c, no Status__c, linked to the candidate it created
        insert new Service__c(Name = 'legacy.pdf', Account__c = existing.Id, File_Checksum__c = checksum,
            Request_Key__c = 'legacy-' + Crypto.getRandomInteger());
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Service__c s = load(second);
        Assert.areEqual('Duplicate', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.startsWith('This exact file was already uploaded'), s.Status_Message__c);
        Assert.areEqual(existing.Id, s.Account__c);
    }

    @IsTest
    static void legacyUploadOfJdDoesNotBlockResume() {
        Id second = IntakeTestData.newIntake('Resume', 'r.pdf', 'jd-legacy-bytes');
        String checksum = [SELECT File_Checksum__c FROM Service__c WHERE Id = :second].File_Checksum__c;
        insert new Service__c(Name = 'legacy-jd.pdf', File_Checksum__c = checksum,
            Request_Key__c = 'legacy-' + Crypto.getRandomInteger());
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('Anu Mohan', 'anu@example.com', null);
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Assert.areEqual('Completed', load(second).Status__c, 'a legacy row that created nothing is not a duplicate');
    }
}