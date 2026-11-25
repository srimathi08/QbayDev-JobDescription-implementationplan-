@isTest
private class parseEmailTest {


    // ---------------- helpers ----------------

    private static Messaging.InboundEmail mail(String fromAddr, String subject, String body, String messageId) {
        Messaging.InboundEmail e = new Messaging.InboundEmail();
        e.fromAddress = fromAddr;
        e.subject = subject;
        e.plainTextBody = body;
        e.messageId = messageId;
        e.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>();
        return e;
    }

    private static Messaging.InboundEmail.BinaryAttachment att(String name, String mime, String content, Boolean inline) {
        Messaging.InboundEmail.BinaryAttachment a = new Messaging.InboundEmail.BinaryAttachment();
        a.fileName = name;
        a.mimeTypeSubType = mime;
        a.body = Blob.valueOf(content);
        if (inline) {
            Messaging.InboundEmail.Header h = new Messaging.InboundEmail.Header();
            h.name = 'Content-ID';
            h.value = '<image001@01DA>';
            a.headers = new List<Messaging.InboundEmail.Header>{ h };
        }
        return a;
    }

    private static Messaging.InboundEnvelope env(String fromAddr) {
        Messaging.InboundEnvelope v = new Messaging.InboundEnvelope();
        v.fromAddress = fromAddr;
        v.toAddress = 'service@example.com';
        return v;
    }

    private static List<Service__c> intakes() {
        return [
            SELECT Id, Name, Status__c, Status_Message__c, Source_Channel__c, Requested_Type__c, Detected_Type__c,
                   EmailFrom__c, Email_Message_Key__c, Request_Key__c, File_Checksum__c, Retry_Count__c, Acknowledged__c
            FROM Service__c WHERE Source_Channel__c = 'Email' ORDER BY Name
        ];
    }

    private static Integer filesOn(Id recordId) {
        return [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :recordId];
    }

    // ---------------- intake (handler) ----------------


    private static List<Service__c> allIntakes() {
        return [
            SELECT Id, Name, Status__c, Status_Message__c, Source_Channel__c, Requested_Type__c, Detected_Type__c,
                   Retry_Count__c
            FROM Service__c ORDER BY Name
        ];
    }

    private static Id fileOn(Id recordId, String name) {
        ContentVersion cv = new ContentVersion(Title = name, PathOnClient = name + '.pdf',
            VersionData = Blob.valueOf('PDF ' + name), FirstPublishLocationId = recordId);
        insert cv;
        return cv.Id;
    }

    @isTest
    static void resumeAttachmentIsSavedAndIdentified() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Profile for Salesforce role', 'Please find the CV attached.', '<m1@x>');
        e.binaryAttachments.add(att('Jane Doe.pdf', 'application/pdf', 'PDF CONTENT 1', false));
        e.binaryAttachments.add(att('image001.png', 'image/png', 'logo', true));
        e.binaryAttachments.add(att('smime.p7s', 'application/pkcs7-signature', 'sig', false));
        IntakeRouter.mockResponse = '{"documentType":"Resume","confidence":0.97,"reason":"Work history and skills"}';

        Test.startTest();
        Messaging.InboundEmailResult r = new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        System.assertEquals(true, r.success);
        List<Service__c> recs = intakes();
        System.assertEquals(1, recs.size(), 'logo and signature must be ignored');
        Service__c s = recs[0];
        System.assertEquals('Jane Doe.pdf', s.Name);
        System.assertEquals('recruiter@quadrobay.com', s.EmailFrom__c);
        System.assertEquals('Queued', s.Status__c, s.Status_Message__c);
        System.assertEquals('Resume', s.Requested_Type__c);
        System.assertEquals('Resume', s.Detected_Type__c);
        System.assertNotEquals(null, s.File_Checksum__c);
        System.assertNotEquals(null, s.Email_Message_Key__c);
        System.assertEquals(1, filesOn(s.Id));
    }

    @isTest
    static void jobDescriptionAttachmentIsIdentified() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'New requirement', 'JD attached', '<m2@x>');
        e.binaryAttachments.add(att('Salesforce Developer JD.docx',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'DOCX', false));
        IntakeRouter.mockResponse = '```json\n{"documentType":"Job Description","confidence":0.9,"reason":"Hiring requirement"}\n```';

        Test.startTest();
        new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        Service__c s = intakes()[0];
        System.assertEquals('Queued', s.Status__c);
        System.assertEquals('Job Description', s.Requested_Type__c);
    }

    @isTest
    static void otherDocumentIsRejected() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'NDA', 'Signed NDA', '<m3@x>');
        e.binaryAttachments.add(att('NDA.pdf', 'application/pdf', 'NDA', false));
        IntakeRouter.mockResponse = '{"documentType":"Other","confidence":0.95,"reason":"Signed NDA"}';

        Test.startTest();
        new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        Service__c s = intakes()[0];
        System.assertEquals('Rejected', s.Status__c);
        System.assertEquals('Other', s.Detected_Type__c);
        System.assert(s.Status_Message__c.contains('not a resume or a job description'), s.Status_Message__c);
    }

    @isTest
    static void unreadableClassifierAnswerFailsAndIsRetried() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'cv', '<m4@x>');
        e.binaryAttachments.add(att('cv.pdf', 'application/pdf', 'X', false));
        IntakeRouter.mockResponse = 'I think this is a resume';

        Test.startTest();
        new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        Service__c s = intakes()[0];
        System.assertEquals('Failed', s.Status__c);
        System.assert(s.Status_Message__c.contains('retried automatically'), s.Status_Message__c);

        Integer restarted = IntakeRouter.runRetry();
        System.assertEquals(1, restarted);
        s = intakes()[0];
        System.assertEquals('New', s.Status__c);
        System.assertEquals(1, s.Retry_Count__c);
        System.assert(s.Status_Message__c.startsWith('Automatic retry 1'), s.Status_Message__c);
    }

    @isTest
    static void unsupportedFilesAreRejectedVisibly() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Files', 'see files', '<m5@x>');
        e.binaryAttachments.add(att('Old Resume.doc', 'application/msword', 'DOC', false));
        e.binaryAttachments.add(att('Tracker.xlsx', 'application/vnd.ms-excel', 'XLS', false));

        Test.startTest();
        new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        List<Service__c> recs = intakes();
        System.assertEquals(2, recs.size());
        for (Service__c s : recs) {
            System.assertEquals('Rejected', s.Status__c);
            System.assertEquals(1, filesOn(s.Id), 'the file is kept for reference');
        }
        System.assert(recs[0].Status_Message__c.contains('.doc'), recs[0].Status_Message__c);
        System.assert(recs[1].Status_Message__c.contains('not a supported file type'), recs[1].Status_Message__c);
    }

    @isTest
    static void longBodyWithoutAttachmentBecomesADocument() {
        String jd = 'We are hiring a Senior Salesforce Developer for our client in Chennai. '.repeat(10);
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Requirement: Salesforce Developer', jd, '<m6@x>');
        IntakeRouter.mockResponse = '{"documentType":"Job Description","confidence":0.9,"reason":"hiring"}';

        Test.startTest();
        new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        Service__c s = intakes()[0];
        System.assert(s.Name.startsWith('Email - Requirement'), s.Name);
        System.assertEquals('Queued', s.Status__c);
        System.assertEquals(1, filesOn(s.Id));
    }

    @isTest
    static void shortBodyWithoutAttachmentIsRejected() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Hi', 'Thanks!', '<m7@x>');
        e.binaryAttachments.add(att('image002.jpg', 'image/jpeg', 'img', true));

        Test.startTest();
        new parseEmail().handleInboundEmail(e, env(e.fromAddress));
        Test.stopTest();

        Service__c s = intakes()[0];
        System.assertEquals('Rejected', s.Status__c);
        System.assert(s.Status_Message__c.contains('image002.jpg'), s.Status_Message__c);
        System.assertEquals(0, filesOn(s.Id));
    }

    @isTest
    static void sameEmailDeliveredTwiceIsIgnored() {
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'cv', '<same@x>');
        e.binaryAttachments.add(att('cv.pdf', 'application/pdf', 'X', false));
        IntakeRouter.getSettings().enabled = false; // keep this test to the intake step

        Test.startTest();
        parseEmail.Outcome first = parseEmail.receive(e, env(e.fromAddress));
        parseEmail.Outcome second = parseEmail.receive(e, env(e.fromAddress));
        Test.stopTest();

        System.assertEquals(1, first.queued.size());
        System.assertEquals(true, second.duplicateEmail);
        System.assertEquals(1, intakes().size());
        System.assertEquals('New', intakes()[0].Status__c, 'intake disabled: record waits');
    }

    @isTest
    static void fileLimitPerEmailIsEnforced() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.maxFilesPerEmail = 1;
        cfg.enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Two CVs', 'cvs', '<m8@x>');
        e.binaryAttachments.add(att('a.pdf', 'application/pdf', 'A', false));
        e.binaryAttachments.add(att('b.pdf', 'application/pdf', 'B', false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, o.queued.size());
        System.assertEquals(1, o.rejected.size());
    }

    @isTest
    static void htmlBodyInvalidSenderAndNoExtension() {
        IntakeRouter.getSettings().enabled = false;
        Messaging.InboundEmail e = mail('not-an-email', null, null, null);
        e.htmlBody = '<html><style>p{}</style><body><p>Hello&nbsp;team</p><br/>Regards</body></html>';
        e.binaryAttachments.add(att('Resume', 'application/pdf', 'PDF', false));

        parseEmail.receive(e, env('not-an-email'));

        Service__c s = intakes()[0];
        System.assertEquals('Resume.pdf', s.Name);
        System.assertEquals(null, s.EmailFrom__c);
        String b = parseEmail.bodyOf(e);
        System.assert(b.contains('Hello') && b.contains('Regards') && !b.contains('<p>'), b);
        System.assertEquals('docx', parseEmail.extensionOf('x', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'));
        System.assertEquals('doc', parseEmail.extensionOf('x', 'application/msword'));
        System.assertEquals('png', parseEmail.extensionOf('x', 'image/png'));
        System.assertEquals('', parseEmail.extensionOf(null, null));
    }

    @isTest
    static void handlerErrorRollsBackAndReportsFailure() {
        parseEmail.forceErrorInTest = true;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'cv', '<m9@x>');

        Messaging.InboundEmailResult r = new parseEmail().handleInboundEmail(e, env(e.fromAddress));

        System.assertEquals(false, r.success);
        System.assert(r.message.contains('could not be saved'), r.message);
        System.assertEquals(0, intakes().size());
    }

    // ---------------- retry job ----------------

    @isTest
    static void acknowledgementIsSentOncePerEmailWhenAllFilesFinish() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.sendAcknowledgement = true;
        cfg.acknowledgementDomains = new Set<String>{ 'quadrobay.com' };
        String key = parseEmail.sha256('<ack@x>');
        List<Service__c> recs = new List<Service__c>{
            new Service__c(Name = 'a.pdf', Source_Channel__c = 'Email', Status__c = 'Queued', Email_Message_Key__c = key,
                EmailFrom__c = 'recruiter@quadrobay.com', Email_Subject__c = 'Two CVs'),
            new Service__c(Name = 'b.pdf', Source_Channel__c = 'Email', Status__c = 'Queued', Email_Message_Key__c = key,
                EmailFrom__c = 'recruiter@quadrobay.com', Email_Subject__c = 'Two CVs')
        };
        insert recs;

        recs[0].Status__c = 'Completed';
        recs[0].Status_Message__c = 'Created candidate A.';
        update recs[0];
        System.assertEquals(0, parseEmail.ackSentCount, 'second file still running');

        recs[1].Status__c = 'Rejected';
        recs[1].Status_Message__c = 'Not a resume.';
        update recs[1];
        System.assertEquals(1, parseEmail.ackSentCount);
        for (Service__c s : intakes()) System.assertEquals(true, s.Acknowledged__c);

        parseEmail.sendPendingAcknowledgements(Datetime.now().addDays(-1));
        System.assertEquals(1, parseEmail.ackSentCount, 'never sent twice');

        List<Service__c> full = [
            SELECT Id, Name, Status__c, Status_Message__c, Detected_Type__c, Email_Subject__c,
                   Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name
            FROM Service__c WHERE Email_Message_Key__c = :key ORDER BY Name
        ];
        String text = parseEmail.acknowledgementSummary(full, 'https://example.com');
        System.assert(text.contains('[OK] a.pdf') && text.contains('[NOT CREATED] b.pdf'), text);
    }

    @isTest
    static void noAcknowledgementForOutsideDomainsOrWhenOff() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.sendAcknowledgement = true;
        cfg.acknowledgementDomains = new Set<String>{ 'quadrobay.com' };
        Service__c s = new Service__c(Name = 'a.pdf', Source_Channel__c = 'Email', Status__c = 'Queued',
            Email_Message_Key__c = 'k1', EmailFrom__c = 'someone@gmail.com');
        insert s;
        s.Status__c = 'Completed';
        update s;
        System.assertEquals(0, parseEmail.ackSentCount);
        System.assertEquals(false, cfg.canAcknowledge('someone@gmail.com'));
        System.assertEquals(true, cfg.canAcknowledge('Someone@QuadroBay.com'));
        cfg.sendAcknowledgement = false;
        System.assertEquals(false, cfg.canAcknowledge('someone@quadrobay.com'));
    }

    @isTest
    static void retryJobRestartsStuckRecordsAndGivesUp() {
        insert new List<Service__c>{
            new Service__c(Name = 'stuck-queued.pdf', Source_Channel__c = 'Email', Status__c = 'Queued',
                Requested_Type__c = 'Resume', Retry_Count__c = 0),
            new Service__c(Name = 'stuck-new.pdf', Source_Channel__c = 'Email', Status__c = 'New', Retry_Count__c = 2),
            new Service__c(Name = 'done.pdf', Source_Channel__c = 'Email', Status__c = 'Rejected', Retry_Count__c = 0)
        };
        IntakeRouter.stuckMinutes = -5; // everything counts as stuck

        Integer restarted = IntakeRouter.runRetry();

        System.assertEquals(1, restarted);
        Map<String, Service__c> byName = new Map<String, Service__c>();
        for (Service__c s : allIntakes()) byName.put(s.Name, s);
        System.assertEquals('Queued', byName.get('stuck-queued.pdf').Status__c);
        System.assertEquals(1, byName.get('stuck-queued.pdf').Retry_Count__c);
        System.assertEquals('Failed', byName.get('stuck-new.pdf').Status__c);
        System.assert(byName.get('stuck-new.pdf').Status_Message__c.startsWith('Gave up'));
        System.assertEquals('Rejected', byName.get('done.pdf').Status__c);
    }

    @isTest
    static void scheduleIsIdempotent() {
        Test.startTest();
        Id jobId = IntakeRouter.scheduleHourly();
        Id again = IntakeRouter.scheduleHourly();
        Test.stopTest();
        System.assertEquals(jobId, again, 'scheduling twice keeps one job');
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :IntakeRouter.JOB_NAME]);
    }

    @isTest
    static void retryJobDoesNothingWhenDisabled() {
        IntakeRouter.getSettings().enabled = false;
        insert new Service__c(Name = 'f.pdf', Source_Channel__c = 'Email', Status__c = 'Failed', Retry_Count__c = 0);
        System.assertEquals(0, IntakeRouter.runRetry());
        new IntakeRouter.RetryJob().execute(null);
        System.assertEquals('Failed', allIntakes()[0].Status__c);
    }

    @isTest
    static void settingsHaveSafeDefaults() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings s = IntakeRouter.getSettings();
        System.assert(s.allowedExtensions.contains('pdf'));
        System.assert(s.maxFilesPerEmail > 0);
        System.assert(s.maxRetries >= 0);
        System.assert(s === IntakeRouter.getSettings(), 'cached per transaction');
    }

    @isTest
    static void classifierRejectsMissingFile() {
        try {
            IntakeRouter.classify(null);
            System.assert(false, 'expected an error');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('No file'));
        }
    }

    @isTest
    static void routerHandlesMissingFileAndAlreadyHandledRecords() {
        Service__c noFile = new Service__c(Name = 'x.pdf', Source_Channel__c = 'Email', Status__c = 'New');
        Service__c done = new Service__c(Name = 'y.pdf', Source_Channel__c = 'Email', Status__c = 'Completed');
        insert new List<Service__c>{ noFile, done };

        Test.startTest();
        System.enqueueJob(new IntakeRouter(noFile.Id));
        System.enqueueJob(new IntakeRouter(done.Id));
        Test.stopTest();

        Map<String, Service__c> byName = new Map<String, Service__c>();
        for (Service__c s : allIntakes()) byName.put(s.Name, s);
        System.assertEquals('Failed', byName.get('x.pdf').Status__c);
        System.assertEquals('Completed', byName.get('y.pdf').Status__c);
    }

    @isTest
    static void routerSendsResumeToProcessing() {
        Service__c s = new Service__c(Name = 'cv.pdf', Source_Channel__c = 'Email', Status__c = 'New');
        insert s;
        fileOn(s.Id, 'cv');
        IntakeRouter.mockResponse = '{"documentType":"Resume","confidence":0.9,"reason":"CV"}';
        Test.startTest();
        IntakeRouter.start(new List<Id>{ s.Id });
        Test.stopTest();
        Service__c r = allIntakes()[0];
        System.assertEquals('Queued', r.Status__c);
        System.assertEquals('Resume', r.Requested_Type__c);
        System.assert(r.Status_Message__c.startsWith('Identified as Resume'), r.Status_Message__c);
    }

    @isTest
    static void routerRejectsOtherAndFailsOnBadAnswer() {
        Service__c other = new Service__c(Name = 'a-nda.pdf', Source_Channel__c = 'Email', Status__c = 'New');
        insert other;
        fileOn(other.Id, 'nda');
        IntakeRouter.mockResponse = '{"documentType":"Other","reason":"NDA"}';
        Test.startTest();
        System.enqueueJob(new IntakeRouter(other.Id));
        Test.stopTest();
        System.assertEquals('Rejected', allIntakes()[0].Status__c);

        IntakeRouter.mockResponse = 'not json';
        Service__c bad = new Service__c(Name = 'b-bad.pdf', Source_Channel__c = 'Email', Status__c = 'New');
        insert bad;
        fileOn(bad.Id, 'bad');
        try {
            IntakeRouter.classify([SELECT ContentDocumentId FROM ContentVersion WHERE FirstPublishLocationId = :bad.Id LIMIT 1].ContentDocumentId);
            System.assert(false, 'expected an error');
        } catch (CalloutException e) {
            System.assert(e.getMessage().contains('could not be read'));
        }
    }

    @isTest
    static void retryOnlyTouchesConfiguredChannels() {
        insert new List<Service__c>{
            new Service__c(Name = 'email.pdf', Source_Channel__c = 'Email', Status__c = 'Failed', Retry_Count__c = 0),
            new Service__c(Name = 'upload.pdf', Source_Channel__c = 'UI Upload', Status__c = 'Failed',
                Requested_Type__c = 'Resume', Retry_Count__c = 0),
            new Service__c(Name = 'whatsapp.pdf', Source_Channel__c = 'WhatsApp', Status__c = 'Failed', Retry_Count__c = 0)
        };
        IntakeRouter.getSettings().retryChannels = new Set<String>{ 'Email' };

        System.assertEquals(1, IntakeRouter.runRetry());

        Map<String, Service__c> byName = new Map<String, Service__c>();
        for (Service__c s : allIntakes()) byName.put(s.Name, s);
        System.assertEquals('New', byName.get('email.pdf').Status__c);
        System.assertEquals('Failed', byName.get('upload.pdf').Status__c, 'uploader records are not retried');
        System.assertEquals('Failed', byName.get('whatsapp.pdf').Status__c, 'WhatsApp not on the shared pipeline yet');
    }

    @isTest
    static void settingsParseLists() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings s = IntakeRouter.getSettings();
        s.sendAcknowledgement = true;
        s.acknowledgementDomains = new Set<String>{ 'quadrobay.com' };
        System.assertEquals(true, s.canAcknowledge('A@QuadroBay.com'));
        System.assertEquals(false, s.canAcknowledge('a@gmail.com'));
        System.assertEquals(false, s.canAcknowledge(null));
        System.assert(s.retryChannels.contains('Email'));
    }

    @isTest
    static void handler_testCandidateResumeEmail() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'candidate@test.com';
        email.subject = 'Candidate Resume';
        email.plainTextBody = 'Please find attached resume';
        Messaging.InboundEmail.BinaryAttachment att = new Messaging.InboundEmail.BinaryAttachment();
        att.fileName = 'resume.pdf';
        att.mimeTypeSubType = 'application/pdf';
        att.body = Blob.valueOf('PDF DATA');
        email.binaryAttachments = new List<Messaging.InboundEmail.BinaryAttachment>{ att };
        IntakeRouter.mockResponse = '{"documentType":"Resume"}';

        Test.startTest();
        Messaging.InboundEmailResult result = new parseEmail().handleInboundEmail(email, env(email.fromAddress));
        Test.stopTest();

        System.assertEquals(true, result.success);
        Service__c s = [
            SELECT Id, Name, EmailFrom__c, Email_Subject__c, Source_Channel__c, Status__c
            FROM Service__c WHERE EmailFrom__c = 'candidate@test.com' LIMIT 1
        ];
        System.assertEquals('resume.pdf', s.Name);
        System.assertEquals('Candidate Resume', s.Email_Subject__c);
        System.assertEquals('Email', s.Source_Channel__c);
        System.assertEquals('Queued', s.Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :s.Id]);
    }

    @isTest
    static void handler_testShortEmailWithoutAttachment() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'jd@test.com';
        email.subject = 'Salesforce Developer JD';
        email.plainTextBody = 'This is a job description';

        Messaging.InboundEmailResult result = new parseEmail().handleInboundEmail(email, env(email.fromAddress));

        System.assertEquals(true, result.success);
        Service__c s = [SELECT Name, Status__c FROM Service__c WHERE EmailFrom__c = 'jd@test.com' LIMIT 1];
        System.assertEquals('Salesforce Developer JD', s.Name);
        System.assertEquals('Rejected', s.Status__c);
    }

    @isTest
    static void handler_testNoSubjectEmail() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'nosubject@test.com';
        email.plainTextBody = 'Email body only';

        Messaging.InboundEmailResult result = new parseEmail().handleInboundEmail(email, env(email.fromAddress));

        System.assertEquals(true, result.success);
        Service__c s = [SELECT Name FROM Service__c WHERE EmailFrom__c = 'nosubject@test.com' LIMIT 1];
        System.assertEquals('Email with no attachment', s.Name);
    }

    @isTest
    static void handler_testSafeExecutionFlow() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'test123@gmail.com';
        email.subject = 'Test Subject';
        email.plainTextBody = 'Test Body';

        Messaging.InboundEmailResult result = new parseEmail().handleInboundEmail(email, env(email.fromAddress));

        System.assertEquals(true, result.success);
        System.assertEquals('Email processed successfully', result.message);
    }
}