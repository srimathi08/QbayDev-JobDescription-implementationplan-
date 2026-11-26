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

    @IsTest
    static void helpers() {
        Assert.areEqual('pdf', IntakeController.extensionOf('A.B.PDF'));
        Assert.areEqual('', IntakeController.extensionOf('noext'));
        Assert.areEqual('A.B', IntakeController.titleOf('A.B.PDF'));
    }
}
