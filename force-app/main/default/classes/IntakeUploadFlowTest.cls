@IsTest
private class IntakeUploadFlowTest {

    private static Id uploadedDoc(String title, String ext, String body) {
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.' + ext, VersionData = Blob.valueOf(body));
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    private static Service__c load(Id id) {
        return [SELECT Status__c, Status_Message__c, Requested_Type__c, Detected_Type__c, Account__c, Job_Description__c,
                       Upload_Batch__c, File_Checksum__c, Retry_Count__c, AI_Response__c, Source_Channel__c
                FROM Service__c WHERE Id = :id];
    }

    private static String nameOnlyJson(String name) {
        return '{"documentType":"Resume","resumes":[{"account":{"name":"' + name
            + '","email":"","phone":"","linkedin":"","summary":"Business Analyst"}}]}';
    }

    private static Id needsReviewIntake(String name) {
        Id svcId = IntakeTestData.newIntake('Resume', 'nr.pdf', 'nr-' + name);
        Service__c s = new Service__c(Id = svcId, Status__c = 'Needs Review', AI_Response__c = nameOnlyJson(name));
        update s;
        return svcId;
    }

    // ---------------- settings ----------------

    @IsTest
    static void settingsHaveSafeValues() {
        IntakeController.UploadSettings st = IntakeController.getUploadSettings();
        Assert.isTrue(st.maxFiles > 0);
        Assert.isTrue(st.maxFileMb > 0);
        Assert.areEqual(UserInfo.getUserId(), st.userId);
    }

    // ---------------- submitUploadedFiles ----------------

    @IsTest
    static void uploadCreatesOneIntakePerFileAndStartsOnlyTheFirst() {
        Id a = uploadedDoc('Resume A', 'pdf', 'aaa');
        Id b = uploadedDoc('Notes', 'txt', 'bbb');
        Id c = uploadedDoc('Resume C', 'docx', 'ccc');
        Test.startTest();
        List<IntakeController.IntakeStatus> rows = IntakeController.submitUploadedFiles(new List<Id>{ a, b, c }, 'Auto', 'batch-1');
        Assert.areEqual(1, Limits.getQueueableJobs(), 'only the first file starts; the rest follow one by one');
        // checked before stopTest: once the processor runs, Auto is resolved to the detected type
        Assert.isNull(load(rows[0].serviceId).Requested_Type__c, 'Auto = blank requested type');
        Test.stopTest();

        Assert.areEqual(3, rows.size());
        Assert.areEqual('Rejected', rows[1].status);
        Assert.isTrue(rows[1].message.contains('not supported'), rows[1].message);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :b], 'a refused file is removed');

        Service__c first = load(rows[0].serviceId);
        Assert.areEqual('batch-1', first.Upload_Batch__c);
        Assert.isNotNull(first.File_Checksum__c);
        Assert.areEqual('UI Upload', first.Source_Channel__c);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :rows[2].serviceId]);
    }

    @IsTest
    static void sameUploadKeyReturnsTheSameIntakes() {
        Id a = uploadedDoc('Resume A', 'pdf', 'aaa');
        List<IntakeController.IntakeStatus> first = IntakeController.submitUploadedFiles(new List<Id>{ a }, 'Resume', 'batch-2');
        List<IntakeController.IntakeStatus> again = IntakeController.submitUploadedFiles(new List<Id>{ a }, 'Resume', 'batch-2');
        Assert.areEqual(first[0].serviceId, again[0].serviceId);
        Assert.areEqual(1, [SELECT COUNT() FROM Service__c]);
    }

    @IsTest
    static void filesOverTheLimitAreRefused() {
        Integer max = IntakeController.getUploadSettings().maxFiles;
        List<Id> docs = new List<Id>();
        for (Integer i = 0; i <= max; i++) docs.add(uploadedDoc('R' + i, 'pdf', 'body-' + i));
        List<IntakeController.IntakeStatus> rows = IntakeController.submitUploadedFiles(docs, 'Resume', 'batch-3');
        Assert.areEqual(max + 1, rows.size());
        Assert.areEqual('Rejected', rows[max].status);
        Assert.isTrue(rows[max].message.contains('Only ' + max + ' files'), rows[max].message);
        Assert.areEqual(max, [SELECT COUNT() FROM Service__c WHERE Status__c = 'Queued']);
    }

    @IsTest
    static void badInputIsRefused() {
        Boolean failed = false;
        try {
            IntakeController.submitUploadedFiles(new List<Id>(), 'Resume', 'k');
        } catch (AuraHandledException e) {
            failed = true;
        }
        Assert.isTrue(failed);
        failed = false;
        try {
            IntakeController.submitUploadedFiles(new List<Id>{ uploadedDoc('x', 'pdf', 'x') }, 'Invoice', 'k');
        } catch (AuraHandledException e) {
            failed = true;
        }
        Assert.isTrue(failed);
    }

    // ---------------- one file at a time per upload ----------------

    @IsTest
    static void nextFileOfTheSameUploadIsStarted() {
        Id one = IntakeTestData.newIntake('Resume', 'one.pdf', 'one');
        Id two = IntakeTestData.newIntake('Resume', 'two.pdf', 'two');
        Id other = IntakeTestData.newIntake('Resume', 'other.pdf', 'other');
        update new List<Service__c>{
            new Service__c(Id = one, Upload_Batch__c = 'b', Status__c = 'Completed'),
            new Service__c(Id = two, Upload_Batch__c = 'b'),
            new Service__c(Id = other, Upload_Batch__c = 'c')
        };
        IntakeProcessor.startNextInBatch(one);
        Assert.areEqual(two, IntakeProcessor.lastChainedId);
    }

    @IsTest
    static void intakeWithoutUploadKeyStartsNothing() {
        Id one = IntakeTestData.newIntake('Resume', 'one.pdf', 'solo');
        IntakeProcessor.startNextInBatch(one);
        Assert.isNull(IntakeProcessor.lastChainedId);
    }

    // ---------------- Auto-detect ----------------

    @IsTest
    static void autoDetectRunsTheJdPromptForAJd() {
        Id svcId = IntakeTestData.newIntake('Resume', 'auto-jd.pdf', 'auto-jd');
        update new Service__c(Id = svcId, Requested_Type__c = null);
        CandidateCreationPrompt.mockResponse = '{"documentType":"Job Description"}';
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Infosys Ltd.', 'Salesforce Developer', 'Job Description');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.areEqual('Job Description', s.Requested_Type__c);
        Assert.isNotNull(s.Job_Description__c);
    }

    @IsTest
    static void autoDetectKeepsAResume() {
        Id svcId = IntakeTestData.newIntake('Resume', 'auto-cv.pdf', 'auto-cv');
        update new Service__c(Id = svcId, Requested_Type__c = null);
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('Kiran Das', 'kiran@example.com', null);
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Completed', s.Status__c, s.Status_Message__c);
        Assert.areEqual('Resume', s.Requested_Type__c);
        Assert.isNotNull(s.Account__c);
    }

    @IsTest
    static void autoDetectRejectsOtherDocuments() {
        Id svcId = IntakeTestData.newIntake('Resume', 'invoice.pdf', 'invoice');
        update new Service__c(Id = svcId, Requested_Type__c = null);
        CandidateCreationPrompt.mockResponse = '{"documentType":"Other"}';
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c);
        Assert.areEqual('Other', s.Detected_Type__c);
    }

    // ---------------- Needs Review ----------------

    @IsTest
    static void recruiterCompletesANeedsReviewUpload() {
        Id svcId = needsReviewIntake('Meena Raj');
        Test.startTest();
        IntakeController.IntakeStatus st = IntakeController.completeReview(svcId, 'meena.raj@example.com', '', '');
        Test.stopTest();
        Assert.areEqual('Completed', st.status, st.message);
        Account a = [SELECT Name, Personal_Email__c FROM Account WHERE Id = :st.accountId];
        Assert.areEqual('Meena Raj', a.Name);
        Assert.areEqual('meena.raj@example.com', a.Personal_Email__c);
        Assert.isTrue(load(svcId).AI_Response__c.contains('meena.raj@example.com'));
    }

    @IsTest
    static void completeReviewMatchesAnExistingCandidateByEmail() {
        Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account existing = new Account(Name = 'Meena R', RecordTypeId = rt, Personal_Email__c = 'meena.raj@example.com');
        insert existing;
        Id svcId = needsReviewIntake('Meena Raj');
        IntakeController.IntakeStatus st = IntakeController.completeReview(svcId, 'Meena.Raj@example.com', null, null);
        Assert.areEqual(existing.Id, st.accountId);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE RecordTypeId = :rt]);
    }

    @IsTest
    static void completeReviewNeedsAValidDetail() {
        Id svcId = needsReviewIntake('Meena Raj');
        Integer errors = 0;
        try { IntakeController.completeReview(svcId, '', '', ''); } catch (AuraHandledException e) { errors++; }
        try { IntakeController.completeReview(svcId, 'not-an-email', '', ''); } catch (AuraHandledException e) { errors++; }
        Assert.areEqual(2, errors);
        Assert.areEqual('Needs Review', load(svcId).Status__c);
    }

    @IsTest
    static void completeReviewIsOnlyForUploadsThatNeedIt() {
        Id svcId = IntakeTestData.newIntake('Resume', 'done.pdf', 'done');
        update new Service__c(Id = svcId, Status__c = 'Completed');
        Boolean failed = false;
        try { IntakeController.completeReview(svcId, 'a@b.com', null, null); } catch (AuraHandledException e) { failed = true; }
        Assert.isTrue(failed);
    }

    @IsTest
    static void withContactFillsTheFirstResume() {
        String patched = CandidateCreationController.withContact(nameOnlyJson('Ravi'), 'ravi@example.com', '98765 43210', null);
        Map<String, Object> acc = AiJson.obj(AiJson.objList(AiJson.parse(patched), 'resumes')[0], 'account');
        Assert.areEqual('ravi@example.com', acc.get('email'));
        Assert.areEqual('98765 43210', acc.get('phone'));
    }

    // ---------------- Duplicate: attach to existing ----------------

    @IsTest
    static void duplicateResumeCanBeAttachedToTheExistingCandidate() {
        Id rt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account existing = new Account(Name = 'Rahul Venugopal', RecordTypeId = rt);
        insert existing;
        Id svcId = IntakeTestData.newIntake('Resume', 'rahul.pdf', 'rahul');
        update new Service__c(Id = svcId, Status__c = 'Duplicate', Account__c = existing.Id,
            Status_Message__c = 'Duplicate: a candidate named Rahul Venugopal already exists. Nothing was created.');

        IntakeController.IntakeStatus before = IntakeController.getStatus(new List<Id>{ svcId })[0];
        Assert.isTrue(before.canAttach);
        Assert.isTrue(before.canReview, 'a different person can still be created with contact details');

        IntakeController.IntakeStatus st = IntakeController.attachToExisting(svcId);
        Assert.areEqual('Completed', st.status);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :existing.Id]);
    }

    // ---------------- Retry ----------------

    @IsTest
    static void failedUploadCanBeRetried() {
        Id svcId = IntakeTestData.newIntake('Resume', 'f.pdf', 'f');
        update new Service__c(Id = svcId, Status__c = 'Failed');
        Test.startTest();
        IntakeController.IntakeStatus st = IntakeController.retryIntake(svcId);
        Assert.areEqual(1, Limits.getQueueableJobs());
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual(1, s.Retry_Count__c);
        Assert.isNotNull(st);
    }

    @IsTest
    static void retriedFileDoesNotStartTheRestOfItsUpload() {
        Id failed = IntakeTestData.newIntake('Resume', 'f.pdf', 'f2');
        Id waiting = IntakeTestData.newIntake('Resume', 'w.pdf', 'w2');
        update new List<Service__c>{
            new Service__c(Id = failed, Status__c = 'Failed', Upload_Batch__c = 'rb'),
            new Service__c(Id = waiting, Upload_Batch__c = 'rb')
        };
        Test.startTest();
        IntakeController.retryIntake(failed);
        Test.stopTest();
        Assert.isNull(IntakeProcessor.lastChainedId, 'the waiting file is left to its own chain');
    }

    // ---------------- Review step (25-11-2026) ----------------

    @IsTest
    static void reviewListShowsTypeSizeAndChecks() {
        Id a = uploadedDoc('Resume A', 'pdf', 'aaa');
        Id b = uploadedDoc('Notes', 'txt', 'bbb');
        List<IntakeController.UploadedFile> files = IntakeController.getUploadedFileDetails(new List<Id>{ a, b });
        Assert.areEqual(2, files.size());
        Assert.areEqual('Resume A.pdf', files[0].fileName);
        Assert.areEqual('pdf', files[0].extension);
        Assert.areEqual(3, files[0].sizeBytes);
        Assert.isNull(files[0].problem);
        Assert.isTrue(files[1].problem.contains('Not supported'), files[1].problem);
    }

    @IsTest
    static void removeDeletesAnUnprocessedFileOnly() {
        Id a = uploadedDoc('Resume A', 'pdf', 'aaa');
        IntakeController.removeUploadedFile(a);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :a]);

        Id svcId = IntakeTestData.newIntake('Resume', 'p.pdf', 'ppp');
        Id inUse = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :svcId LIMIT 1].ContentDocumentId;
        Boolean refused = false;
        try { IntakeController.removeUploadedFile(inUse); } catch (AuraHandledException e) { refused = true; }
        Assert.isTrue(refused, 'a file that is already being processed is not removed');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocument WHERE Id = :inUse]);
    }

    @IsTest
    static void eachFileKeepsItsOwnTypeInOneUpload() {
        Id a = uploadedDoc('Resume A', 'pdf', 'aaa');
        Id b = uploadedDoc('JD B', 'pdf', 'bbb');
        Id c = uploadedDoc('Mixed C', 'docx', 'ccc');
        Test.startTest();
        List<IntakeController.IntakeStatus> rows = IntakeController.submitUploadedFilesWithTypes(
            new List<Id>{ a, b, c }, new List<String>{ 'Resume', 'Job Description', 'Auto' }, 'batch-types');
        Assert.areEqual(1, Limits.getQueueableJobs(), 'still one file at a time');
        Map<Id, Service__c> byId = new Map<Id, Service__c>([SELECT Requested_Type__c, Upload_Batch__c FROM Service__c]);
        Assert.areEqual('Resume', byId.get(rows[0].serviceId).Requested_Type__c);
        Assert.areEqual('Job Description', byId.get(rows[1].serviceId).Requested_Type__c);
        Assert.isNull(byId.get(rows[2].serviceId).Requested_Type__c, 'Auto = blank type');
        Assert.areEqual('batch-types', byId.get(rows[2].serviceId).Upload_Batch__c);
        Test.stopTest();
    }

    @IsTest
    static void jdDuplicateNeverOffersAttachResume() {
        Id clientRt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Direct_Customers').getRecordTypeId();
        Account client = new Account(Name = 'IBM', RecordTypeId = clientRt);
        insert client;
        Id svcId = IntakeTestData.newIntake(null, 'jd.pdf', 'jd-dup');
        update new Service__c(Id = svcId, Status__c = 'Duplicate', Account__c = client.Id);
        IntakeController.IntakeStatus st = IntakeController.getStatus(new List<Id>{ svcId })[0];
        Assert.isFalse(st.canAttach, 'a client Account is never offered "attach resume"');
        Boolean refused = false;
        try { IntakeController.attachToExisting(svcId); } catch (AuraHandledException e) { refused = true; }
        Assert.isTrue(refused);
    }

    @IsTest
    static void autoDuplicateKeepsTheTypeOfTheEarlierUpload() {
        Id first = IntakeTestData.newIntake('Job Description', 'jd.pdf', 'same-bytes');
        update new Service__c(Id = first, Status__c = 'Completed', Detected_Type__c = 'Job Description');
        Id again = IntakeTestData.newIntake(null, 'jd (1).pdf', 'same-bytes');
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(again));
        Test.stopTest();
        Service__c s = load(again);
        Assert.areEqual('Duplicate', s.Status__c, s.Status_Message__c);
        Assert.areEqual('Job Description', s.Requested_Type__c);
        Assert.areEqual('Job Description', IntakeController.getStatus(new List<Id>{ again })[0].requestedType);
    }

    @IsTest
    static void autoFileWithNoPersonIsNotAResume() {
        Id svcId = IntakeTestData.newIntake(null, 'review.docx', 'review-doc');
        CandidateCreationPrompt.mockResponse = '{"documentType":"Resume","resumes":[{"account":{"name":"","email":"","phone":"","linkedin":""}}]}';
        Test.startTest();
        System.enqueueJob(new IntakeProcessor(svcId));
        Test.stopTest();
        Service__c s = load(svcId);
        Assert.areEqual('Rejected', s.Status__c);
        Assert.isTrue(s.Status_Message__c.contains('does not look like a resume or a job description'), s.Status_Message__c);
    }

    @IsTest
    static void onlyFailedUploadsCanBeRetried() {
        Id done = IntakeTestData.newIntake('Resume', 'c.pdf', 'c');
        update new Service__c(Id = done, Status__c = 'Completed');
        Id email = IntakeTestData.newIntake('Resume', 'e.pdf', 'e');
        update new Service__c(Id = email, Status__c = 'Failed', Source_Channel__c = 'Email');
        Integer errors = 0;
        try { IntakeController.retryIntake(done); } catch (AuraHandledException e) { errors++; }
        try { IntakeController.retryIntake(email); } catch (AuraHandledException e) { errors++; }
        Assert.areEqual(2, errors, 'completed uploads and email intakes are not retried here');
    }

    // ---------------- Inbox ----------------

    @IsTest
    static void inboxFiltersByStatusChannelAndOwner() {
        Id review = IntakeTestData.newIntake('Resume', 'r.pdf', 'r');
        Id done = IntakeTestData.newIntake('Resume', 'd.pdf', 'd');
        Id email = IntakeTestData.newIntake('Resume', 'e.pdf', 'e');
        update new List<Service__c>{
            new Service__c(Id = review, Status__c = 'Needs Review'),
            new Service__c(Id = done, Status__c = 'Completed'),
            new Service__c(Id = email, Status__c = 'Failed', Source_Channel__c = 'Email')
        };

        List<IntakeController.IntakeStatus> action = IntakeController.getInbox('UI Upload', 'Action needed', 7, false);
        Assert.areEqual(1, action.size());
        Assert.areEqual(review, action[0].serviceId);
        Assert.isTrue(action[0].canReview);
        Assert.isFalse(action[0].canRetry);

        Assert.areEqual(3, IntakeController.getInbox('All', 'All', 1, true).size());
        List<IntakeController.IntakeStatus> emails = IntakeController.getInbox('Email', 'All', 30, false);
        Assert.areEqual(1, emails.size());
        Assert.isFalse(emails[0].canRetry, 'email intakes are read-only here');
        Assert.areEqual('Email', emails[0].channel);
    }
}
