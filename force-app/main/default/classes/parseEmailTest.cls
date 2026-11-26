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
        System.assert(r.message.contains('reference EM-'), 'sender gets a reference: ' + r.message);
        System.assert(!r.message.contains('Forced test error'), 'no technical error to the sender: ' + r.message);
        System.assertEquals(0, intakes().size());
    }

    @isTest
    static void fileTypeComesFromMimeWhenNameHasADot() {
        System.assertEquals('pdf', parseEmail.emailFileType('CV - J.Smith', 'application/pdf'));
        System.assertEquals('docx', parseEmail.emailFileType('Resume v2.1',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document'));
        System.assertEquals('pdf', parseEmail.emailFileType('Resume.PDF', 'application/octet-stream'));
        System.assertEquals('xlsx', parseEmail.emailFileType('Tracker.xlsx', 'application/pdf'), 'a real extension wins');
        System.assertEquals('final', parseEmail.emailFileType('Report.final', 'application/octet-stream'));
        // the public helper shared with WhatsApp keeps its old behaviour
        System.assertEquals('smith', parseEmail.extensionOf('CV - J.Smith', 'application/pdf'));

        IntakeRouter.getSettings().enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'cv', '<m10@x>');
        e.binaryAttachments.add(att('CV - J.Smith', 'application/pdf', 'PDF SMITH', false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, o.queued.size(), 'accepted, not rejected as ".smith"');
        Service__c s = intakes()[0];
        System.assertEquals('CV - J.Smith.pdf', s.Name);
        System.assertEquals('New', s.Status__c);
    }

    @isTest
    static void sameFileTwiceInOneEmailIsSavedOnce() {
        IntakeRouter.getSettings().enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'cv', '<m11@x>');
        e.binaryAttachments.add(att('Jane.pdf', 'application/pdf', 'SAME BYTES', false));
        e.binaryAttachments.add(att('Jane (1).pdf', 'application/pdf', 'SAME BYTES', false));
        e.binaryAttachments.add(att('John.pdf', 'application/pdf', 'OTHER BYTES', false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(2, o.queued.size());
        System.assertEquals(2, intakes().size());
        System.assert(String.join(o.ignored, ',').contains('Jane (1).pdf (same file attached twice)'), o.ignored);
    }

    @isTest
    static void sameBodySentTwiceGetsTheSameChecksum() {
        IntakeRouter.getSettings().enabled = false;
        String jd = 'We are hiring a Senior Salesforce Developer for our client in Chennai. '.repeat(10);
        parseEmail.receive(mail('recruiter@quadrobay.com', 'Requirement', jd, '<m12@x>'), env('recruiter@quadrobay.com'));
        parseEmail.receive(mail('recruiter@quadrobay.com', 'Fwd: Requirement', '  ' + jd.toUpperCase() + '\n', '<m13@x>'),
            env('recruiter@quadrobay.com'));

        List<Service__c> recs = intakes();
        System.assertEquals(2, recs.size());
        System.assertNotEquals(null, recs[0].File_Checksum__c);
        System.assertEquals(recs[0].File_Checksum__c, recs[1].File_Checksum__c, 'same text, same checksum');
        System.assertEquals(parseEmail.textChecksum(jd), recs[0].File_Checksum__c);
        System.assertNotEquals(parseEmail.textChecksum(jd), parseEmail.textChecksum(jd + ' Budget 20 LPA'));
    }

    // ---------------- email text together with files ----------------

    private static String longJd() {
        return 'Client ABC Technologies is hiring a Senior Salesforce Developer in Chennai, 5 positions, budget 20 LPA. '.repeat(10);
    }

    @isTest
    static void longTextWithFilesIsCheckedAsAJobDescription() {
        IntakeRouter.getSettings().enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Profiles for ABC', longJd(), '<m20@x>');
        e.binaryAttachments.add(att('Jane.pdf', 'application/pdf', 'JANE', false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(2, o.queued.size(), 'the file and the email text');
        Service__c text = [SELECT Name, Requested_Type__c, Status__c, Upload_Batch__c, File_Checksum__c FROM Service__c
                           WHERE Name LIKE 'Email text - %'];
        System.assertEquals('Job Description', text.Requested_Type__c);
        System.assertEquals('New', text.Status__c);
        System.assert(text.Upload_Batch__c.startsWith('EM-'), text.Upload_Batch__c);
        System.assertEquals(parseEmail.textChecksum(longJd()), text.File_Checksum__c);
    }

    @isTest
    static void shortTextWithFilesIsNotADocumentAndSettingCanTurnItOff() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'Please find the CV attached. Regards, Team', '<m21@x>');
        e.binaryAttachments.add(att('Jane.pdf', 'application/pdf', 'JANE', false));
        System.assertEquals(1, parseEmail.receive(e, env(e.fromAddress)).queued.size());

        cfg.minBodyLengthWithFiles = 0;
        Messaging.InboundEmail e2 = mail('recruiter@quadrobay.com', 'CV', longJd(), '<m22@x>');
        e2.binaryAttachments.add(att('John.pdf', 'application/pdf', 'JOHN', false));
        System.assertEquals(1, parseEmail.receive(e2, env(e2.fromAddress)).queued.size(), '0 = text never used with files');
    }

    @isTest
    static void emailTextThatIsNotAJobDescriptionIsSetAsideQuietly() {
        Service__c s = new Service__c(Name = 'Email text - Profiles.pdf', Source_Channel__c = 'Email', Status__c = 'New',
            Requested_Type__c = 'Job Description');
        insert s;
        fileOn(s.Id, 'text');
        IntakeRouter.mockResponse = '{"documentType":"Resume","confidence":0.8,"reason":"cover letter"}';
        Test.startTest();
        System.enqueueJob(new IntakeRouter(s.Id));
        Test.stopTest();
        Service__c r = allIntakes()[0];
        System.assertEquals('Rejected', r.Status__c);
        System.assertEquals('Other', r.Detected_Type__c);
        System.assert(r.Status_Message__c.contains('not a job description'), r.Status_Message__c);

        List<Service__c> grp = [SELECT Id, Name, Status__c, Status_Message__c, Detected_Type__c, Email_Subject__c,
            Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name FROM Service__c];
        String text = parseEmail.acknowledgementSummary(grp, 'https://example.com');
        System.assert(!text.contains('Email text - '), 'not reported to the sender: ' + text);
    }

    @isTest
    static void emailTextThatIsAJobDescriptionIsQueued() {
        Service__c s = new Service__c(Name = 'Email text - Req.pdf', Source_Channel__c = 'Email', Status__c = 'New',
            Requested_Type__c = 'Job Description');
        insert s;
        fileOn(s.Id, 'text');
        IntakeRouter.mockResponse = '{"documentType":"Job Description","confidence":0.9,"reason":"hiring"}';
        Test.startTest();
        System.enqueueJob(new IntakeRouter(s.Id));
        Test.stopTest();
        System.assertEquals('Queued', allIntakes()[0].Status__c);
        System.assertEquals('Job Description', allIntakes()[0].Detected_Type__c);
    }

    // ---------------- forwarded emails (.eml) ----------------

    private static String forwardedEmail(String innerText, String pdfName, String pdfContent) {
        String b64 = EncodingUtil.base64Encode(Blob.valueOf(pdfContent));
        return 'From: client@abc.com\r\nSubject: Fwd: profiles\r\nMIME-Version: 1.0\r\n'
            + 'Content-Type: multipart/mixed; boundary="OUTER"\r\n\r\n'
            + 'preamble\r\n--OUTER\r\n'
            + 'Content-Type: multipart/alternative; boundary=INNER\r\n\r\n'
            + '--INNER\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n'
            + innerText + '\r\n'
            + '--INNER\r\nContent-Type: text/html\r\n\r\n<p>html version</p>\r\n--INNER--\r\n'
            + '--OUTER\r\nContent-Type: application/pdf; name="ignored.pdf"\r\n'
            + 'Content-Disposition: attachment;\r\n filename="' + pdfName + '"\r\n'
            + 'Content-Transfer-Encoding: base64\r\n\r\n' + b64 + '\r\n'
            + '--OUTER\r\nContent-Type: image/png\r\nContent-ID: <logo>\r\nContent-Disposition: inline; filename="logo.png"\r\n'
            + 'Content-Transfer-Encoding: base64\r\n\r\n' + EncodingUtil.base64Encode(Blob.valueOf('PNG')) + '\r\n'
            + '--OUTER--\r\n';
    }

    @isTest
    static void filesInsideAForwardedEmailAreRead() {
        IntakeRouter.getSettings().enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'FW: profiles', 'see below', '<m30@x>');
        Messaging.InboundEmail.BinaryAttachment eml = att('profiles.eml', 'message/rfc822',
            forwardedEmail('short', '=?UTF-8?B?' + EncodingUtil.base64Encode(Blob.valueOf('Ravi CV.pdf')) + '?=', 'PDF RAVI'), false);
        e.binaryAttachments.add(eml);

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, o.queued.size(), 'the PDF inside the forwarded email');
        Service__c s = intakes()[0];
        System.assertEquals('Ravi CV.pdf', s.Name);
        ContentVersion cv = [SELECT VersionData FROM ContentVersion WHERE FirstPublishLocationId = :s.Id];
        System.assertEquals('PDF RAVI', cv.VersionData.toString());
        System.assert(String.join(o.ignored, ',').contains('logo.png'), o.ignored);
    }

    @isTest
    static void textOfAForwardedEmailWithoutFilesBecomesADocument() {
        IntakeRouter.getSettings().enabled = false;
        String raw = 'Subject: JD\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: quoted-printable\n\n'
            + 'We are hiring =E2=80=93 ' + longJd().left(400) + '=\nend';
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'FW: JD', '', '<m31@x>');
        Messaging.InboundEmail.TextAttachment t = new Messaging.InboundEmail.TextAttachment();
        t.fileName = 'jd.eml';
        t.mimeTypeSubType = 'message/rfc822';
        t.body = raw;
        e.textAttachments = new List<Messaging.InboundEmail.TextAttachment>{ t };

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, o.queued.size());
        System.assert(intakes()[0].Name.startsWith('Email - FW') && intakes()[0].Name.contains('JD'), intakes()[0].Name);
    }

    @isTest
    static void unreadableOrHugeForwardedEmailsAreRejectedVisibly() {
        IntakeRouter.getSettings().enabled = false;
        parseEmail.forwardedEmailMaxBytes = 10;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'FW', 'x', '<m32@x>');
        e.binaryAttachments.add(att('big.eml', 'message/rfc822', 'Subject: big\n\nlong enough body', false));
        e.binaryAttachments.add(att('Outlook item.msg', 'application/vnd.ms-outlook', 'MSG', false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(2, o.rejected.size());
        String all = '';
        for (Service__c s : intakes()) all += s.Status_Message__c + ' ';
        System.assert(all.contains('too large to open') && all.contains('Outlook item (.msg)'), all);
    }

    @isTest
    static void mimeHelpers() {
        System.assertEquals('CV A.pdf', parseEmail.headerParam('attachment; filename*=UTF-8\'\'CV%20A.pdf', 'filename'));
        System.assertEquals('b.pdf', parseEmail.headerParam('attachment; filename=b.pdf; size=3', 'filename'));
        System.assertEquals(null, parseEmail.headerParam(null, 'filename'));
        System.assertEquals('Résumé', parseEmail.decodeWords('=?UTF-8?Q?R=C3=A9sum=C3=A9?='));
        System.assertEquals('a b', parseEmail.decodeWords('a b'));
        System.assertEquals('é 100%', parseEmail.decodeQuotedPrintable('=C3=A9 100%', 'UTF-8'));
        parseEmail.MimePart p = parseEmail.parseMime('Content-Type: multipart/mixed\n\nno boundary', 0);
        System.assertEquals(0, p.children.size());
        System.assertEquals('Hello', parseEmail.htmlToText('<div>Hello</div>'));
    }

    // ---------------- images, size limit, no Message-Id ----------------

    @isTest
    static void bigImagesAreRejectedSmallOnesIgnored() {
        IntakeRouter.getSettings().enabled = false;
        parseEmail.scannedImageMinBytes = 100;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV photo', 'cv', '<m40@x>');
        e.binaryAttachments.add(att('cv-photo.jpg', 'image/jpeg', 'x'.repeat(200), false));
        e.binaryAttachments.add(att('tiny.png', 'image/png', 'logo', false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, o.rejected.size());
        System.assert(intakes()[0].Status_Message__c.contains('is an image'), intakes()[0].Status_Message__c);
        System.assert(String.join(o.ignored, ',').contains('tiny.png'), o.ignored);
    }

    @isTest
    static void oversizeFilesAreRejectedWithoutSavingTheFile() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.enabled = false;
        cfg.maxEmailFileMb = 1;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Big CV', 'cv', '<m41@x>');
        e.binaryAttachments.add(att('big.pdf', 'application/pdf', 'x'.repeat(1100000), false));

        parseEmail.Outcome o = parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, o.rejected.size());
        Service__c s = intakes()[0];
        System.assert(s.Status_Message__c.contains('larger than 1 MB'), s.Status_Message__c);
        System.assertEquals(0, filesOn(s.Id));
    }

    @isTest
    static void emailWithoutMessageIdIsStillRecognisedWhenDeliveredTwice() {
        IntakeRouter.getSettings().enabled = false;
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'CV', 'cv', null);
        Messaging.InboundEmail.Header d = new Messaging.InboundEmail.Header();
        d.name = 'Date';
        d.value = 'Wed, 26 Nov 2026 10:00:00 +0530';
        e.headers = new List<Messaging.InboundEmail.Header>{ d };
        e.binaryAttachments.add(att('cv.pdf', 'application/pdf', 'X', false));

        System.assertEquals(false, parseEmail.receive(e, env(e.fromAddress)).duplicateEmail);
        System.assertEquals(true, parseEmail.receive(e, env(e.fromAddress)).duplicateEmail);
    }

    // ---------------- one email = one chain ----------------

    @isTest
    static void filesOfOneEmailAreProcessedOneAfterAnother() {
        String b = 'EM-chain';
        Service__c a = new Service__c(Name = 'a.pdf', Source_Channel__c = 'Email', Status__c = 'Queued', Upload_Batch__c = b);
        Service__c n = new Service__c(Name = 'b.pdf', Source_Channel__c = 'Email', Status__c = 'New', Upload_Batch__c = b);
        insert new List<Service__c>{ a, n };

        IntakeRouter.continueEmailChain(a.Id);
        System.assertEquals(n.Id, IntakeRouter.lastChainedRouterId, 'next file is identified first');

        n.Status__c = 'Queued';
        update n;
        IntakeRouter.continueEmailChain(n.Id);
        System.assertEquals(a.Id, IntakeRouter.lastChainedProcessorId, 'then records are created from the first file');
    }

    @isTest
    static void chainRouterDoesNotStartProcessingItself() {
        Service__c s = new Service__c(Name = 'cv.pdf', Source_Channel__c = 'Email', Status__c = 'New', Upload_Batch__c = 'EM-1');
        insert s;
        fileOn(s.Id, 'cv');
        IntakeRouter.mockResponse = '{"documentType":"Resume","confidence":0.9,"reason":"CV"}';
        Test.startTest();
        IntakeRouter.startEmailChain(s.Id);
        IntakeRouter.startEmailChain(null);
        Test.stopTest();
        System.assertEquals('Queued', allIntakes()[0].Status__c);
        IntakeRouter.markFailed(s.Id, null); // not New any more: unchanged
        System.assertEquals('Queued', allIntakes()[0].Status__c);
    }

    @isTest
    static void scannedHintOnlyForEmail() {
        Service__c em = new Service__c(Name = 'a.pdf', Source_Channel__c = 'Email', Status__c = 'New');
        Service__c wa = new Service__c(Name = 'b.pdf', Source_Channel__c = 'WhatsApp', Status__c = 'New');
        insert new List<Service__c>{ em, wa };
        fileOn(em.Id, 'a');
        fileOn(wa.Id, 'b');
        IntakeRouter.mockResponse = '{"documentType":"Other","reason":"empty"}';
        Test.startTest();
        System.enqueueJob(new IntakeRouter(em.Id));
        System.enqueueJob(new IntakeRouter(wa.Id));
        Test.stopTest();
        Map<String, Service__c> byName = new Map<String, Service__c>();
        for (Service__c s : allIntakes()) byName.put(s.Name, s);
        System.assert(byName.get('a.pdf').Status_Message__c.contains('scanned'), byName.get('a.pdf').Status_Message__c);
        System.assert(!byName.get('b.pdf').Status_Message__c.contains('scanned'), 'WhatsApp message unchanged');
    }

    @isTest
    static void retryIdentifiesEmailTextBeforeProcessing() {
        insert new Service__c(Name = 'Email text - x.pdf', Source_Channel__c = 'Email', Status__c = 'Failed',
            Requested_Type__c = 'Job Description', Retry_Count__c = 0);
        IntakeRouter.getSettings().retryChannels = new Set<String>{ 'Email' };
        System.assertEquals(1, IntakeRouter.runRetry());
        System.assertEquals('New', allIntakes()[0].Status__c, 'identified again, not sent straight to processing');
    }

    // ---------------- acknowledgement and failure alert ----------------

    @isTest
    static void fullyRejectedEmailIsAcknowledgedAtOnce() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.sendAcknowledgement = true;
        cfg.acknowledgementDomains = new Set<String>{ 'quadrobay.com' };
        cfg.acknowledgementFromAddress = 'nobody-' + Datetime.now().getTime() + '@example.com';
        Messaging.InboundEmail e = mail('recruiter@quadrobay.com', 'Old CV', 'cv', '<m50@x>');
        e.binaryAttachments.add(att('Old.doc', 'application/msword', 'DOC', false));

        parseEmail.receive(e, env(e.fromAddress));

        System.assertEquals(1, parseEmail.ackSentCount);
        System.assertEquals(true, intakes()[0].Acknowledged__c);
    }

    @isTest
    static void failedFileIsNotReportedUntilRetriesAreUsedThenAlerts() {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.sendAcknowledgement = true;
        cfg.acknowledgementDomains = new Set<String>{ 'quadrobay.com' };
        cfg.retryChannels = new Set<String>{ 'Email' };
        cfg.maxRetries = 2;
        cfg.failureAlertEmails = new List<String>{ 'team@example.com' };
        Service__c s = new Service__c(Name = 'a.pdf', Source_Channel__c = 'Email', Status__c = 'New', Retry_Count__c = 0,
            Email_Message_Key__c = 'k-fail', EmailFrom__c = 'recruiter@quadrobay.com');
        insert s;

        s.Status__c = 'Failed';
        update s;
        System.assertEquals(0, parseEmail.ackSentCount, 'will be retried: not reported yet');
        System.assertEquals(0, parseEmail.alertSentCount);

        s.Status__c = 'New';
        s.Retry_Count__c = 2;
        update s;
        s.Status__c = 'Failed';
        update s;
        System.assertEquals(1, parseEmail.ackSentCount, 'reported after the last retry');
        System.assertEquals(1, parseEmail.alertSentCount);
    }

    @isTest
    static void uploadScreenWordingIsRewordedForEmailSenders() {
        String m = parseEmail.forEmailSender('This file looks like a Job Description, not a resume. Please upload it as a '
            + 'Job Description, or choose Auto-detect. Nothing was created.');
        System.assert(!m.contains('Auto-detect'), m);
        System.assert(parseEmail.forEmailSender('Please upload again.').contains('send it again'));
        System.assertEquals(null, parseEmail.forEmailSender(null));
    }

    @isTest
    static void newSettingsHaveSafeDefaults() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings s = IntakeRouter.getSettings();
        System.assert(s.minBodyLengthWithFiles >= 0);
        System.assert(s.maxEmailFileMb >= 0);
        System.assertNotEquals(null, s.failureAlertEmails);
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