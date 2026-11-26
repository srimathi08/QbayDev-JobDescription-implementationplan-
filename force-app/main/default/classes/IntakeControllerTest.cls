@IsTest
private class IntakeControllerTest {

    // submitFile (the old one-call upload) was removed on 26-11-2026; the upload path is tested in IntakeUploadFlowTest.

    private static final String CLIENT = 'Carewell Insurance Ltd';
    private static final String ROLE = 'Salesforce Service Cloud Developer';

    private static Service__c load(Id id) {
        return [SELECT Status__c, Status_Message__c, Detected_Type__c, Account__c, Opportunity__c, Job_Description__c
                FROM Service__c WHERE Id = :id];
    }

    /** jdJson with other responsibilities / skills: the same requirement written differently by the AI. */
    private static String jdWith(String role, String responsibilities, String skills) {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(IntakeTestData.jdJson(CLIENT, role, 'Job Description'));
        Map<String, Object> jd = (Map<String, Object>) ((Map<String, Object>) ((List<Object>) root.get('jobs'))[0]).get('jobDescription');
        jd.put('responsibilities', responsibilities);
        jd.put('skillsRequired', skills);
        return JSON.serialize(root);
    }

    private static final String OTHER_TEXT = 'Own case management, omni-channel routing and knowledge base rollout';
    private static final String OTHER_SKILLS = 'Service Cloud, Omni-Channel, Knowledge, CTI';

    /** First JD for the client (creates the Opportunity), then a second upload of the same role written differently. */
    private static Id secondJdUpload(String channel, String json) {
        Id first = IntakeTestData.newIntake('Job Description', 'jd1.pdf', 'jd-1');
        JobDescriptionCreationController.process(IntakeTestData.jdJson(CLIENT, ROLE, 'Job Description'), first, true);
        Id second = IntakeTestData.newIntake('Job Description', 'jd2.pdf', 'jd-2');
        if (channel != null) update new Service__c(Id = second, Source_Channel__c = channel);
        JobDescriptionCreationPrompt.mockResponse = json;
        return second;
    }

    @IsTest
    static void sameRoleWrittenDifferentlyWaitsForTheRecruiter() {
        Id second = secondJdUpload(null, jdWith(ROLE, OTHER_TEXT, OTHER_SKILLS));
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Service__c s = load(second);
        Assert.areEqual('Needs Review', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.startsWith(JobDescriptionCreationController.POSSIBLE_DUPLICATE_PREFIX));
        Assert.isNotNull(s.Opportunity__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity]);
        IntakeController.IntakeStatus st = IntakeController.getStatus(new List<Id>{ second })[0];
        Assert.isTrue(st.canChooseJd);
        Assert.isFalse(st.canReview, 'a JD never shows the contact details form');
    }

    @IsTest
    static void recruiterKeepsTheExistingOpportunity() {
        Id second = secondJdUpload(null, jdWith(ROLE, OTHER_TEXT, OTHER_SKILLS));
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Id existingOpp = load(second).Opportunity__c;
        IntakeController.IntakeStatus st = IntakeController.resolveJdDuplicate(second, true);
        Assert.areEqual('Completed', st.status, st.message);
        Assert.areEqual(existingOpp, st.opportunityId);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity]);
        Assert.isTrue([SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :existingOpp] >= 2, 'both JD files are on the Opportunity');
    }

    @IsTest
    static void recruiterCreatesANewOpportunity() {
        Id second = secondJdUpload(null, jdWith(ROLE, OTHER_TEXT, OTHER_SKILLS));
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Id existingOpp = load(second).Opportunity__c;
        IntakeController.IntakeStatus st = IntakeController.resolveJdDuplicate(second, false);
        Assert.areEqual('Completed', st.status, st.message);
        Assert.areNotEqual(existingOpp, st.opportunityId);
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity]);
        try {
            IntakeController.resolveJdDuplicate(second, true);
            Assert.fail('a completed upload cannot be decided again');
        } catch (AuraHandledException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()));
        }
    }

    @IsTest
    static void seniorRoleIsADifferentRequirement() {
        Id second = secondJdUpload(null, jdWith('Sr. SFDC Service Cloud Dev', OTHER_TEXT, 'Apex, LWC, Integration'));
        // "Sr." makes it a senior role: a different requirement
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Assert.areEqual('Completed', load(second).Status__c);
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void sameRoleSameSkillsOtherWordingIsTheSameRequirement() {
        Id second = secondJdUpload(null, jdWith('SFDC Service Cloud Dev', OTHER_TEXT, 'Apex, LWC and Integration'));
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Service__c s = load(second);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.startsWith('Updated open Opportunity'), s.Status_Message__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void emailPossibleDuplicateIsCreatedAndNamed() {
        Id second = secondJdUpload('Email', jdWith(ROLE, OTHER_TEXT, OTHER_SKILLS));
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second, false));
        Test.stopTest();
        Service__c s = load(second);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.contains('Possible duplicate of the open Opportunity'), s.Status_Message__c);
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity]);
    }

    @IsTest
    static void documentWithNoJobDetailsIsNotAJd() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'audit.docx', 'audit');
        JobDescriptionCreationPrompt.mockResponse = JSON.serialize(new Map<String, Object>{
            'documentType' => 'Job Description',
            'jobs' => new List<Object>{ new Map<String, Object>{ 'jobDescription' => new Map<String, Object>{
                'title' => 'Upload audit', 'companyName' => '', 'responsibilities' => 'Both uploaders create records.',
                'skillsRequired' => '', 'experience' => '', 'ar' => '1'
            } } }
        });
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c);
        Assert.areEqual(JobDescriptionCreationController.NOT_A_JD_MESSAGE, s.Status_Message__c);
        Assert.areEqual('Other', s.Detected_Type__c);
    }

    @IsTest
    static void rolesAndSkillsAreComparedLoosely() {
        Assert.areEqual(JobDescriptionCreationController.roleKey('Senior Salesforce Developer'),
            JobDescriptionCreationController.roleKey('Sr. SFDC Dev'));
        Assert.areEqual(JobDescriptionCreationController.roleKey('Developer - Salesforce'),
            JobDescriptionCreationController.roleKey('Salesforce Developer (urgent hiring)'));
        Assert.areNotEqual(JobDescriptionCreationController.roleKey('Salesforce Developer'),
            JobDescriptionCreationController.roleKey('Salesforce Administrator'));
        Assert.areEqual('', JobDescriptionCreationController.roleKey(null));
        Assert.areEqual(1, JobDescriptionCreationController.skillSimilarity('Apex, LWC and Integration', 'apex; lwc / integration'));
        Assert.areEqual(0, JobDescriptionCreationController.skillSimilarity(null, 'Apex'));
    }

    @IsTest
    static void waitingFilesShowTheirPlaceInTheUpload() {
        List<Service__c> batch = new List<Service__c>();
        for (Integer i = 1; i <= 3; i++) {
            batch.add(new Service__c(Name = 'f' + i + '.pdf', Source_Channel__c = 'UI Upload', Status__c = 'Queued',
                Requested_Type__c = 'Resume', Upload_Batch__c = 'B-1', Request_Key__c = 'B-1-' + i));
        }
        insert batch;
        List<IntakeController.IntakeStatus> st = IntakeController.getStatus(new List<Id>{ batch[0].Id, batch[1].Id, batch[2].Id });
        Assert.areEqual(3, st[2].batchTotal);
        Set<Integer> positions = new Set<Integer>{ st[0].batchPosition, st[1].batchPosition, st[2].batchPosition };
        Assert.areEqual(new Set<Integer>{ 1, 2, 3 }, positions);
        update new Service__c(Id = batch[0].Id, Status__c = 'Completed');
        Assert.isNull(IntakeController.getStatus(new List<Id>{ batch[0].Id })[0].batchPosition, 'only waiting files show a place');
    }

    // ---------------- Client name box (26-11-2026) ----------------

    private static Id uploadedDoc(String title) {
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = Blob.valueOf(title));
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    @IsTest
    static void typedClientNameIsKeptOnJdAndAutoFilesOnly() {
        List<Id> docs = new List<Id>{ uploadedDoc('cv'), uploadedDoc('jd'), uploadedDoc('auto') };
        Test.startTest();
        IntakeController.submitUploadedFilesWithClient(docs, new List<String>{ 'Resume', 'Job Description', 'Auto' }, 'B-CLIENT', '  Carewell   Insurance Ltd ');
        Test.stopTest();
        Map<String, String> clientByType = new Map<String, String>();
        for (Service__c s : [SELECT Requested_Type__c, Client_Name__c, Name FROM Service__c WHERE Upload_Batch__c = 'B-CLIENT']) {
            clientByType.put(s.Name, s.Client_Name__c);
        }
        Assert.isNull(clientByType.get('cv.pdf'));
        Assert.areEqual('Carewell Insurance Ltd', clientByType.get('jd.pdf'));
        Assert.areEqual('Carewell Insurance Ltd', clientByType.get('auto.pdf'));
    }

    @IsTest
    static void typedClientNameIsUsedWhenTheJdNamesNoCompany() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-no-company');
        update new Service__c(Id = svcId, Client_Name__c = CLIENT);
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('', ROLE, 'Job Description');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.areEqual(CLIENT, [SELECT Name FROM Account WHERE Id = :s.Account__c].Name);
    }

    @IsTest
    static void companyInTheJdWinsOverTheTypedName() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-with-company');
        update new Service__c(Id = svcId, Client_Name__c = 'Someone Else Ltd');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Infosys Ltd.', ROLE, 'Job Description');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Infosys Ltd.', [SELECT Name FROM Account WHERE Id = :s.Account__c].Name);
    }

    @IsTest
    static void noCompanyAndNoTypedNameAsksForTheClientName() {
        Id svcId = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'jd-nothing');
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('', ROLE, 'Job Description');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c);
        Assert.isTrue(s.Status_Message__c.contains('Client name box'), s.Status_Message__c);
    }

    // ---------------- Same file already waiting in Needs Review (26-11-2026) ----------------

    private static Id waitingReview(Id docId) {
        String sum = [SELECT Checksum FROM ContentVersion WHERE ContentDocumentId = :docId AND IsLatest = true].Checksum;
        Service__c s = new Service__c(Name = 'first.pdf', Source_Channel__c = 'UI Upload', Status__c = 'Needs Review',
            Requested_Type__c = 'Resume', File_Checksum__c = sum, Request_Key__c = 'first-' + docId);
        insert s;
        return s.Id;
    }

    @IsTest
    static void reviewListFlagsAFileWaitingInNeedsReview() {
        Id doc = uploadedDoc('abhishek');
        waitingReview(doc);
        IntakeController.UploadedFile f = IntakeController.getUploadedFileDetails(new List<Id>{ doc })[0];
        Assert.areEqual('Already waiting in Needs Review', f.problem);
        Assert.isTrue(f.pendingMessage.contains('Please finish it in the Intake inbox'), f.pendingMessage);
    }

    @IsTest
    static void submitRefusesAFileWaitingInNeedsReview() {
        Id doc = uploadedDoc('abhishek');
        Id first = waitingReview(doc);
        List<IntakeController.IntakeStatus> st = IntakeController.submitUploadedFilesWithClient(
            new List<Id>{ doc }, new List<String>{ 'Auto' }, 'B-AGAIN', null);
        Assert.areEqual('Rejected', st[0].status);
        Assert.isTrue(st[0].message.contains('already waiting in Needs Review'), st[0].message);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :doc], 'the second copy is removed');
        Assert.areEqual('Needs Review', load(first).Status__c, 'the first one is untouched');
    }

    @IsTest
    static void sameFileTwiceInOneUploadIsReadOnce() {
        List<Id> docs = new List<Id>{ uploadedDoc('same'), uploadedDoc('same') };
        Test.startTest();
        List<IntakeController.IntakeStatus> st = IntakeController.submitUploadedFilesWithClient(
            docs, new List<String>{ 'Resume', 'Resume' }, 'B-TWICE', null);
        Test.stopTest();
        Assert.areEqual('Rejected', st[1].status);
        Assert.isTrue(st[1].message.contains('same file as another file in this upload'), st[1].message);
    }

    @IsTest
    static void processorDoesNotAskTwiceForTheSameFile() {
        Id first = IntakeTestData.newIntake('Resume', 'a.pdf', 'same-bytes');
        update new Service__c(Id = first, Status__c = 'Needs Review');
        Id second = IntakeTestData.newIntake('Resume', 'a.pdf', 'same-bytes');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(second));
        Test.stopTest();
        Service__c s = load(second);
        Assert.areEqual('Duplicate', s.Status__c, s.Status_Message__c);
        Assert.isTrue(s.Status_Message__c.contains('already waiting in Needs Review'), s.Status_Message__c);
    }

    @IsTest
    static void helpers() {
        Assert.areEqual('pdf', IntakeController.extensionOf('A.B.PDF'));
        Assert.areEqual('', IntakeController.extensionOf('noext'));
        Assert.areEqual('A.B', IntakeController.titleOf('A.B.PDF'));
    }
}
