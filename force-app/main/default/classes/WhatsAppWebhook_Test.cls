@IsTest
public class WhatsAppWebhook_Test {

    private static final String AUTH_PHONE = '919999000111';
    private static final String AUTH_LANDLINE_PHONE = '919999000444';
    private static final String INACTIVE_USER_PHONE = '919999000555';
    private static final String UNAUTH_PHONE = '919999000222';
    private static final String EXTERNAL_DOMAIN_PHONE = '919999000333';

    @TestSetup
    static void setupUsers() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String suffix = String.valueOf(Crypto.getRandomInteger()).replace('-', '');

        List<User> testUsers = new List<User>{
            new User(
                FirstName = 'WA',
                LastName = 'Recruiter',
                Alias = 'warec',
                Email = 'wa.recruiter.' + suffix + '@quadrobay.com',
                Username = 'wa.recruiter.' + suffix + '@quadrobay.com.test',
                MobilePhone = '+91 99990 00111',
                ProfileId = p.Id,
                TimeZoneSidKey = 'Asia/Kolkata',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                IsActive = true
            ),
            new User(
                FirstName = 'WA',
                LastName = 'PhoneUser',
                Alias = 'waphn',
                Email = 'wa.phone.' + suffix + '@quadrobay.com',
                Username = 'wa.phone.' + suffix + '@quadrobay.com.test',
                Phone = '+91-99990-00444',
                ProfileId = p.Id,
                TimeZoneSidKey = 'Asia/Kolkata',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                IsActive = true
            ),
            new User(
                FirstName = 'WA',
                LastName = 'Inactive',
                Alias = 'wainc',
                Email = 'wa.inactive.' + suffix + '@quadrobay.com',
                Username = 'wa.inactive.' + suffix + '@quadrobay.com.test',
                MobilePhone = '9999000555',
                ProfileId = p.Id,
                TimeZoneSidKey = 'Asia/Kolkata',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                IsActive = false
            ),
            new User(
                FirstName = 'WA',
                LastName = 'External',
                Alias = 'waext',
                Email = 'wa.external.' + suffix + '@gmail.com',
                Username = 'wa.external.' + suffix + '@gmail.com.test',
                MobilePhone = '9999000333',
                ProfileId = p.Id,
                TimeZoneSidKey = 'Asia/Kolkata',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                IsActive = true
            )
        };
        insert testUsers;
    }

    private static User getAuthorizedUser() {
        return [SELECT Id, Email, MobilePhone FROM User WHERE Alias = 'warec' LIMIT 1];
    }

    private static void initContext(String method, String body, Map<String, String> headers) {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/whatsapp/webhooks/v1';
        req.httpMethod = method;
        if (body != null) req.requestBody = Blob.valueOf(body);
        if (headers != null) req.headers.putAll(headers);
        RestContext.request = req;
        RestContext.response = res;
    }

    private static String signBody(String body) {
        String secret = System.Label.WHATSAPPSECRET != null ? System.Label.WHATSAPPSECRET.trim() : '';
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(secret));
        return 'sha256=' + EncodingUtil.convertToHex(mac);
    }

    @IsTest
    static void test_doGet_success() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'GET';
        req.params.put('hub.verify_token', System.Label.WHATSAPP_VERIFY_TOKEN);
        req.params.put('hub.challenge', '1234');
        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        WhatsAppWebhook.doGet();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
        System.assertEquals('1234', res.responseBody.toString());
    }

    @IsTest
    static void test_doGet_invalid() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'GET';
        req.params.put('hub.verify_token', 'INVALID');
        req.params.put('hub.challenge', 'ignored');
        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        WhatsAppWebhook.doGet();
        Test.stopTest();

        System.assertEquals(403, res.statusCode);
        System.assertEquals(null, res.responseBody);
    }

    @IsTest
    static void test_doPost_unregisteredAndNonQuadrobayUsersBlocked() {
        String bodyUnreg = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.UNREG1","from":"' + UNAUTH_PHONE
            + '","type":"document","document":{"id":"doc1","mime_type":"application/pdf","filename":"resume.pdf"}}]}}]}]}';
        String bodyExtDomain = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.EXT1","from":"' + EXTERNAL_DOMAIN_PHONE
            + '","type":"document","document":{"id":"doc2","mime_type":"application/pdf","filename":"resume.pdf"}}]}}]}]}';

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        initContext('POST', bodyUnreg, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(bodyUnreg) });
        WhatsAppWebhook.doPost();
        initContext('POST', bodyExtDomain, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(bodyExtDomain) });
        WhatsAppWebhook.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Service__c], 'Unauthorized senders must not create Service__c');
    }

    @IsTest
    static void test_doPost_shortTextMessageIsRejected() {
        String body = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.TEXT1","from":"' + AUTH_PHONE
            + '","type":"text","text":{"body":"Hello"}}],"contacts":[{"wa_id":"' + AUTH_PHONE + '"}]}}]}]}';

        initContext('POST', body, new Map<String, String>{ 'x-hub-signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        User authUser = getAuthorizedUser();
        Service__c svc = [
            SELECT OwnerId, emailfrom__c, Email_Body__c, Whatsapp__c, whatsappfrom__c, Source_Channel__c, Status__c, Detected_Type__c
            FROM Service__c LIMIT 1
        ];
        System.assertEquals(authUser.Id, svc.OwnerId);
        System.assertEquals(authUser.Email, svc.emailfrom__c);
        System.assertEquals(AUTH_PHONE, svc.whatsappfrom__c);
        System.assertEquals('Hello', svc.Email_Body__c);
        System.assertEquals(false, svc.Whatsapp__c);
        System.assertEquals('WhatsApp', svc.Source_Channel__c);
        System.assertEquals('Rejected', svc.Status__c);
        System.assertEquals('Other', svc.Detected_Type__c);
    }

    @IsTest
    static void test_doPost_longTextMessageIsRoutedViaPlatformEvent() {
        String longJd = 'Role: Senior Salesforce Developer. Location: Chennai. Client: Acme Corp. '.repeat(6);
        String body = JSON.serialize(new Map<String, Object>{
            'entry' => new List<Object>{
                new Map<String, Object>{
                    'changes' => new List<Object>{
                        new Map<String, Object>{
                            'value' => new Map<String, Object>{
                                'messages' => new List<Object>{
                                    new Map<String, Object>{
                                        'id' => 'wamid.LONG1',
                                        'from' => AUTH_PHONE,
                                        'type' => 'text',
                                        'text' => new Map<String, Object>{ 'body' => longJd }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        });

        IntakeRouter.mockResponse = '{"documentType":"Job Description","confidence":0.95,"reason":"Hiring requirement"}';
        initContext('POST', body, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Service__c svc = [
            SELECT Status__c, Requested_Type__c, Detected_Type__c, File_Checksum__c, Whatsapp__c
            FROM Service__c LIMIT 1
        ];
        System.assertNotEquals(null, svc.File_Checksum__c);
        System.assertEquals(false, svc.Whatsapp__c);
        System.assertEquals('Queued', svc.Status__c);
        System.assertEquals('Job Description', svc.Requested_Type__c);
    }

    @IsTest
    static void test_doPost_invalidSignature() {
        initContext('POST', '{"entry":[]}', new Map<String, String>{ 'X-Hub-Signature-256' => 'invalid' });

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.stopTest();

        System.assertEquals(401, RestContext.response.statusCode);
    }

    @IsTest
    static void test_doPost_imageAndUnsupportedDocAreRejected() {
        String imgBody = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.IMG1","from":"' + AUTH_PHONE
            + '","type":"image","image":{"id":"img1","mime_type":"image/jpeg"}}]}}]}]}';
        String docBody = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.OLD1","from":"' + AUTH_PHONE
            + '","type":"document","document":{"id":"docOld","mime_type":"application/msword","filename":"legacy.doc"}}]}}]}]}';

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        initContext('POST', imgBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(imgBody) });
        WhatsAppWebhook.doPost();
        initContext('POST', docBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(docBody) });
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        List<Service__c> svcs = [SELECT Name, Status__c, Detected_Type__c FROM Service__c ORDER BY CreatedDate ASC];
        System.assertEquals(2, svcs.size());
        System.assertEquals('Rejected', svcs[0].Status__c);
        System.assertEquals('Other', svcs[0].Detected_Type__c);
        System.assertEquals('Rejected', svcs[1].Status__c);
        System.assertEquals('Other', svcs[1].Detected_Type__c);
    }

    @IsTest
    static void test_doPost_pdfResumeOwnedByInternalUserAndDownloadedAsync() {
        String body = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.DOC1","from":"' + AUTH_PHONE
            + '","type":"document","document":{"id":"doc1","mime_type":"application/pdf","filename":"resume.pdf"}}],"contacts":[{"wa_id":"' + AUTH_PHONE + '"}]}}]}]}';

        initContext('POST', body, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        User authUser = getAuthorizedUser();
        Service__c svc = [
            SELECT Id, Name, OwnerId, emailfrom__c, Status__c, File_Checksum__c, Whatsapp__c, Source_Channel__c
            FROM Service__c LIMIT 1
        ];
        System.assertEquals('resume.pdf', svc.Name);
        System.assertEquals(authUser.Id, svc.OwnerId);
        System.assertEquals(authUser.Email, svc.emailfrom__c);
        System.assertEquals('WhatsApp', svc.Source_Channel__c);
        System.assertEquals(false, svc.Whatsapp__c);
        System.assertEquals('New', svc.Status__c);
        System.assertNotEquals(null, svc.File_Checksum__c, 'Async downloader should attach file and set checksum');
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :svc.Id]);
    }

    @IsTest
    static void test_mediaDownloadQueueable_rejectsOverMaxMb() {
        Service__c svc = new Service__c(
            Name = 'huge_resume.pdf',
            Source_Channel__c = 'WhatsApp',
            Status__c = 'New',
            whatsappfrom__c = AUTH_PHONE
        );
        insert svc;

        Long elevenMb = 11L * 1024L * 1024L;
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout(elevenMb));

        Test.startTest();
        System.enqueueJob(new WhatsAppMediaDownloadQueueable(svc.Id, 'docBig', 'huge_resume.pdf'));
        Test.stopTest();

        Service__c updated = [
            SELECT Status__c, Detected_Type__c, Status_Message__c, Acknowledged__c
            FROM Service__c WHERE Id = :svc.Id
        ];
        System.assertEquals('Rejected', updated.Status__c);
        System.assertEquals('Other', updated.Detected_Type__c);
        System.assert(updated.Status_Message__c.contains('10 MB'), updated.Status_Message__c);
        System.assertEquals(true, updated.Acknowledged__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :svc.Id]);
    }

    @IsTest
    static void test_mediaDownloadQueueable_rejectsEmptyFile() {
        Service__c svc = new Service__c(
            Name = 'empty.pdf',
            Source_Channel__c = 'WhatsApp',
            Status__c = 'New',
            whatsappfrom__c = AUTH_PHONE
        );
        insert svc;

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout(0L));

        Test.startTest();
        System.enqueueJob(new WhatsAppMediaDownloadQueueable(svc.Id, 'docEmpty', 'empty.pdf'));
        Test.stopTest();

        Service__c updated = [
            SELECT Status__c, Detected_Type__c, Status_Message__c
            FROM Service__c WHERE Id = :svc.Id
        ];
        System.assertEquals('Rejected', updated.Status__c);
        System.assertEquals('Other', updated.Detected_Type__c);
        System.assert(updated.Status_Message__c.contains('empty'), updated.Status_Message__c);
    }

    @IsTest
    static void test_doPost_openModeAllowsExternalWhenSettingDisabled() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.restrictWhatsAppToInternal = false;

        String body = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.OPEN1","from":"' + UNAUTH_PHONE
            + '","type":"document","document":{"id":"docOpen","mime_type":"application/vnd.openxmlformats-officedocument.wordprocessingml.document","filename":"Java_JD.docx"}}]}}]}]}';

        initContext('POST', body, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        Service__c svc = [SELECT Name, Status__c, File_Checksum__c FROM Service__c LIMIT 1];
        System.assertEquals('Java_JD.docx', svc.Name);
        System.assertEquals('New', svc.Status__c);
        System.assertNotEquals(null, svc.File_Checksum__c);
    }

    @IsTest
    static void test_doPost_statusAndDuplicate() {
        String statusBody = '{"entry":[{"changes":[{"value":{"statuses":[{"id":"wamid.S1","status":"delivered"}]}}]}]}';
        initContext('POST', statusBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(statusBody) });
        WhatsAppWebhook.doPost();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Service__c]);

        String msgBody = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.DUP1","from":"' + AUTH_PHONE
            + '","type":"document","document":{"id":"docDup","mime_type":"application/pdf","filename":"cv.pdf"}}]}}]}]}';
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        initContext('POST', msgBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(msgBody) });
        WhatsAppWebhook.doPost();
        initContext('POST', msgBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(msgBody) });
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Service__c]);
    }

    @IsTest
    static void test_onServiceAfterUpdate_sendsFinalAck() {
        Id candRt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
        Account cand = new Account(Name = 'Priya Kumar', RecordTypeId = candRt);
        insert cand;

        Service__c svc = new Service__c(
            Name = 'priya.pdf',
            Source_Channel__c = 'WhatsApp',
            Status__c = 'Queued',
            whatsappfrom__c = AUTH_PHONE,
            Acknowledged__c = false
        );
        insert svc;

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        svc.Status__c = 'Completed';
        svc.Detected_Type__c = 'Resume';
        svc.Account__c = cand.Id;
        update svc;
        Test.stopTest();

        Service__c updated = [SELECT Acknowledged__c FROM Service__c WHERE Id = :svc.Id];
        System.assertEquals(true, updated.Acknowledged__c);

        Service__c queried = [
            SELECT Name, Status__c, Status_Message__c, Detected_Type__c,
                   Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name
            FROM Service__c WHERE Id = :svc.Id
        ];
        queried.Status_Message__c = 'Created candidate Priya Kumar.';
        String resumeMsg = WhatsAppWebhook.buildFinalSummary(queried, 'https://example.my.salesforce.com');
        System.assert(resumeMsg.contains('[OK] priya.pdf'), resumeMsg);
        System.assert(resumeMsg.contains('Candidate: Priya Kumar - https://example.my.salesforce.com/' + cand.Id), resumeMsg);
        System.assert(resumeMsg.endsWith('This is an automated message from Salesforce. Please do not reply.'), resumeMsg);
        System.assert(!resumeMsg.contains('Intake record:'), resumeMsg);

        queried.Status__c = 'Duplicate';
        queried.Status_Message__c = 'This exact file was already uploaded.';
        String dupMsg = WhatsAppWebhook.buildFinalSummary(queried, 'https://example.my.salesforce.com');
        System.assert(dupMsg.contains('[ALREADY EXISTS] priya.pdf'), dupMsg);
        System.assert(!dupMsg.contains('Intake record:'), dupMsg);

        queried.Status__c = 'Rejected';
        queried.Account__c = null;
        queried.Status_Message__c = 'No company name found. Please upload again. Please try again.';
        String rejMsg = WhatsAppWebhook.buildFinalSummary(queried, 'https://example.my.salesforce.com');
        System.assert(rejMsg.contains('[NOT CREATED] priya.pdf'), rejMsg);
        System.assert(rejMsg.contains('Please send it again.'), rejMsg);
        System.assert(rejMsg.contains('It will be checked by the team.'), rejMsg);
        System.assert(!rejMsg.contains('Intake record:'), rejMsg);
    }

    @IsTest
    static void test_mediaDownloadQueueable_apiErrorsEmptyBlobAndFinalizer() {
        List<Service__c> svcs = new List<Service__c>{
            new Service__c(Name = 'meta_err.pdf', Source_Channel__c = 'WhatsApp', Status__c = 'New', whatsappfrom__c = AUTH_PHONE),
            new Service__c(Name = 'dl_err.pdf', Source_Channel__c = 'WhatsApp', Status__c = 'New', whatsappfrom__c = AUTH_PHONE),
            new Service__c(Name = 'no_size_empty.pdf', Source_Channel__c = 'WhatsApp', Status__c = 'New', whatsappfrom__c = AUTH_PHONE),
            new Service__c(Name = 'finalizer.pdf', Source_Channel__c = 'WhatsApp', Status__c = 'New', whatsappfrom__c = AUTH_PHONE)
        };
        insert svcs;

        Test.setMock(HttpCalloutMock.class, new WhatsAppErrorMockCallout());
        Test.startTest();
        System.enqueueJob(new WhatsAppMediaDownloadQueueable(svcs[0].Id, 'm1_fail_meta', 'meta_err.pdf'));
        System.enqueueJob(new WhatsAppMediaDownloadQueueable(svcs[1].Id, 'm2_fail_dl', 'dl_err.pdf'));
        System.enqueueJob(new WhatsAppMediaDownloadQueueable(svcs[2].Id, 'm3_empty', 'no_size_empty.pdf'));
        WhatsAppMediaDownloadQueueable.markUnexpectedFailure(svcs[3].Id, new CalloutException('Simulated timeout'));
        Test.stopTest();

        Map<Id, Service__c> byId = new Map<Id, Service__c>([
            SELECT Status__c, Status_Message__c FROM Service__c WHERE Id IN :svcs
        ]);
        System.assertEquals('Failed', byId.get(svcs[0].Id).Status__c);
        System.assertEquals('Failed', byId.get(svcs[1].Id).Status__c);
        System.assertEquals('Rejected', byId.get(svcs[2].Id).Status__c);
        System.assertEquals('Failed', byId.get(svcs[3].Id).Status__c);
    }

    @IsTest
    static void test_userMatching_inactiveBlockedAndPhoneFieldMatches() {
        String inactiveBody = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.INACT1","from":"' + INACTIVE_USER_PHONE
            + '","type":"document","document":{"id":"docInact","mime_type":"application/pdf","filename":"cv.pdf"}}]}}]}]}';
        String phoneFieldBody = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.PHN1","from":"' + AUTH_LANDLINE_PHONE
            + '","type":"document","document":{"id":"docPhn","mime_type":"application/pdf","filename":"cv_phone.pdf"}}]}}]}]}';

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        initContext('POST', inactiveBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(inactiveBody) });
        WhatsAppWebhook.doPost();
        initContext('POST', phoneFieldBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(phoneFieldBody) });
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        User phoneUser = [SELECT Id FROM User WHERE Alias = 'waphn' LIMIT 1];
        List<Service__c> svcs = [SELECT Name, OwnerId, File_Checksum__c FROM Service__c];
        System.assertEquals(1, svcs.size(), 'Inactive user must be blocked while Phone-matched user succeeds');
        System.assertEquals('cv_phone.pdf', svcs[0].Name);
        System.assertEquals(phoneUser.Id, svcs[0].OwnerId);
        System.assertNotEquals(null, svcs[0].File_Checksum__c);
    }

    @IsTest
    static void test_mediaDownload_within10MbAndUnsupportedExtensions() {
        String zipBody = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.ZIP1","from":"' + AUTH_PHONE
            + '","type":"document","document":{"id":"docZip","mime_type":"application/zip","filename":"archive.zip"}}]}}]}]}';
        Service__c bigValid = new Service__c(
            Name = 'nine_mb.pdf',
            Source_Channel__c = 'WhatsApp',
            Status__c = 'New',
            whatsappfrom__c = AUTH_PHONE
        );
        insert bigValid;

        Long nineMb = 9L * 1024L * 1024L;
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout(nineMb));
        Test.startTest();
        initContext('POST', zipBody, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(zipBody) });
        WhatsAppWebhook.doPost();
        System.enqueueJob(new WhatsAppMediaDownloadQueueable(bigValid.Id, 'docNineMb', 'nine_mb.pdf'));
        Test.stopTest();

        Service__c zipSvc = [SELECT Status__c, Detected_Type__c, Acknowledged__c FROM Service__c WHERE Name = 'archive.zip' LIMIT 1];
        System.assertEquals('Rejected', zipSvc.Status__c);
        System.assertEquals('Other', zipSvc.Detected_Type__c);
        System.assertEquals(true, zipSvc.Acknowledged__c);

        Service__c nineMbSvc = [SELECT Status__c, File_Checksum__c FROM Service__c WHERE Id = :bigValid.Id];
        System.assertEquals('New', nineMbSvc.Status__c);
        System.assertNotEquals(null, nineMbSvc.File_Checksum__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :bigValid.Id]);
    }

    @IsTest
    static void test_endToEnd_resumeCreationAndDuplicateChecksum() {
        User authUser = getAuthorizedUser();
        Service__c first = new Service__c(
            Name = 'arjun.pdf',
            OwnerId = authUser.Id,
            Source_Channel__c = 'WhatsApp',
            Requested_Type__c = 'Resume',
            Status__c = 'Queued',
            whatsappfrom__c = AUTH_PHONE
        );
        insert first;
        ContentVersion cv1 = new ContentVersion(
            Title = 'arjun',
            PathOnClient = 'arjun.pdf',
            VersionData = Blob.valueOf('SAME-RESUME-BYTES'),
            FirstPublishLocationId = first.Id
        );
        insert cv1;
        first.File_Checksum__c = [SELECT Checksum FROM ContentVersion WHERE Id = :cv1.Id].Checksum;
        update first;

        Service__c dup = new Service__c(
            Name = 'arjun_copy.pdf',
            OwnerId = authUser.Id,
            Source_Channel__c = 'WhatsApp',
            Requested_Type__c = 'Resume',
            Status__c = 'Queued',
            File_Checksum__c = first.File_Checksum__c,
            whatsappfrom__c = AUTH_PHONE
        );
        insert dup;
        insert new ContentVersion(
            Title = 'arjun_copy',
            PathOnClient = 'arjun_copy.pdf',
            VersionData = Blob.valueOf('SAME-RESUME-BYTES'),
            FirstPublishLocationId = dup.Id
        );

        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('ARJUN KUMAR', 'arjun.wa@example.com', '+91 98765 11111');
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        System.enqueueJob(new IntakeProcessor(first.Id));
        System.enqueueJob(new IntakeProcessor(dup.Id));
        Test.stopTest();

        Service__c firstDone = [SELECT Status__c, Detected_Type__c, Account__c, Acknowledged__c FROM Service__c WHERE Id = :first.Id];
        System.assertEquals('Completed', firstDone.Status__c);
        System.assertEquals('Resume', firstDone.Detected_Type__c);
        System.assertNotEquals(null, firstDone.Account__c);
        System.assertEquals(true, firstDone.Acknowledged__c);

        Service__c dupDone = [SELECT Status__c, Account__c, Acknowledged__c FROM Service__c WHERE Id = :dup.Id];
        System.assertEquals('Duplicate', dupDone.Status__c);
        System.assertEquals(firstDone.Account__c, dupDone.Account__c);
        System.assertEquals(true, dupDone.Acknowledged__c);
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = 'Arjun Kumar']);
    }

    @IsTest
    static void test_endToEnd_jdCreationAndMissingCompanyRejected() {
        User authUser = getAuthorizedUser();
        Service__c jdSvc = new Service__c(
            Name = 'acme_jd.docx',
            OwnerId = authUser.Id,
            Source_Channel__c = 'WhatsApp',
            Requested_Type__c = 'Job Description',
            Status__c = 'Queued',
            whatsappfrom__c = AUTH_PHONE
        );
        Service__c noCoSvc = new Service__c(
            Name = 'nocompany_jd.pdf',
            OwnerId = authUser.Id,
            Source_Channel__c = 'WhatsApp',
            Requested_Type__c = 'Job Description',
            Status__c = 'Queued',
            whatsappfrom__c = AUTH_PHONE
        );
        insert new List<Service__c>{ jdSvc, noCoSvc };

        insert new List<ContentVersion>{
            new ContentVersion(Title = 'acme_jd', PathOnClient = 'acme_jd.docx', VersionData = Blob.valueOf('JD-1'), FirstPublishLocationId = jdSvc.Id),
            new ContentVersion(Title = 'nocompany_jd', PathOnClient = 'nocompany_jd.pdf', VersionData = Blob.valueOf('JD-2'), FirstPublishLocationId = noCoSvc.Id)
        };

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Acme Corp', 'Salesforce Architect', 'Job Description');
        System.enqueueJob(new IntakeProcessor(jdSvc.Id));
        Test.stopTest();

        Service__c jdDone = [SELECT Status__c, Detected_Type__c, Account__c, Opportunity__c, Job_Description__c, Acknowledged__c FROM Service__c WHERE Id = :jdSvc.Id];
        System.assertEquals('Completed', jdDone.Status__c);
        System.assertEquals('Job Description', jdDone.Detected_Type__c);
        System.assertNotEquals(null, jdDone.Opportunity__c);
        System.assertNotEquals(null, jdDone.Job_Description__c);
        System.assertEquals(true, jdDone.Acknowledged__c);

        // Verify missing-company JD is rejected cleanly
        JobDescriptionCreationPrompt.mockResponse = IntakeTestData.jdJson('Temp Holding Account', 'Developer', 'Job Description');
        try {
            JobDescriptionCreationController.process(JobDescriptionCreationPrompt.mockResponse, noCoSvc.Id, true);
            System.assert(false, 'Expected RejectException for missing company name');
        } catch (IntakeProcessor.RejectException rej) {
            System.assert(rej.getMessage().contains('No company name'), rej.getMessage());
        }
    }

    @IsTest
    static void test_endToEnd_otherDocAndResumeMissingContactRejected() {
        Service__c ndaSvc = new Service__c(
            Name = 'nda.pdf',
            Source_Channel__c = 'WhatsApp',
            Status__c = 'New',
            whatsappfrom__c = AUTH_PHONE
        );
        Service__c noContactSvc = new Service__c(
            Name = 'nocontact.pdf',
            Source_Channel__c = 'WhatsApp',
            Requested_Type__c = 'Resume',
            Status__c = 'Queued',
            whatsappfrom__c = AUTH_PHONE
        );
        insert new List<Service__c>{ ndaSvc, noContactSvc };
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'nda', PathOnClient = 'nda.pdf', VersionData = Blob.valueOf('NDA'), FirstPublishLocationId = ndaSvc.Id),
            new ContentVersion(Title = 'nocontact', PathOnClient = 'nocontact.pdf', VersionData = Blob.valueOf('NO-CONTACT'), FirstPublishLocationId = noContactSvc.Id)
        };

        IntakeRouter.mockResponse = '{"documentType":"Other","confidence":0.95,"reason":"Signed NDA"}';
        String noContactJson = '{"documentType":"Resume","resumes":[{"account":{"name":"No Contact Candidate"}}]}';
        CandidateCreationPrompt.mockResponse = noContactJson;

        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());
        Test.startTest();
        System.enqueueJob(new IntakeRouter(ndaSvc.Id));
        System.enqueueJob(new IntakeProcessor(noContactSvc.Id));
        Test.stopTest();

        Service__c ndaDone = [SELECT Status__c, Detected_Type__c, Acknowledged__c FROM Service__c WHERE Id = :ndaSvc.Id];
        System.assertEquals('Rejected', ndaDone.Status__c);
        System.assertEquals('Other', ndaDone.Detected_Type__c);
        System.assertEquals(true, ndaDone.Acknowledged__c);

        Service__c noContactDone = [SELECT Status__c, Acknowledged__c FROM Service__c WHERE Id = :noContactSvc.Id];
        System.assertEquals('Rejected', noContactDone.Status__c);
        System.assertEquals(true, noContactDone.Acknowledged__c);
    }

    @IsTest
    static void test_enabledFalseAndRetrySuppression() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.enabled = false;
        cfg.retryChannels = new Set<String>{ 'Email', 'WhatsApp' };
        cfg.maxRetries = 2;

        String body = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.PAUSED1","from":"' + AUTH_PHONE
            + '","type":"document","document":{"id":"docPaused","mime_type":"application/pdf","filename":"paused.pdf"}}]}}]}]}';
        initContext('POST', body, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        Service__c pausedSvc = [SELECT Status__c, Acknowledged__c FROM Service__c WHERE Name = 'paused.pdf' LIMIT 1];
        System.assertEquals('New', pausedSvc.Status__c, 'Paused pipeline must not process New records');
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pausedSvc.Id]);

        // Retry 0 Failed should NOT notify yet; Retry 2 Failed SHOULD notify
        pausedSvc.Status__c = 'Failed';
        pausedSvc.Retry_Count__c = 0;
        update pausedSvc;
        System.assertEquals(false, [SELECT Acknowledged__c FROM Service__c WHERE Id = :pausedSvc.Id].Acknowledged__c);

        pausedSvc.Status__c = 'New';
        update pausedSvc;
        pausedSvc.Status__c = 'Failed';
        pausedSvc.Retry_Count__c = 2;
        update pausedSvc;
        System.assertEquals(true, [SELECT Acknowledged__c FROM Service__c WHERE Id = :pausedSvc.Id].Acknowledged__c);
    }

    @IsTest
    static void test_settingsIncludeMaxMbAndRestriction() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        System.assert(cfg.retryChannels.contains('Email'));
        System.assertEquals(true, cfg.restrictWhatsAppToInternal);
        System.assertEquals(10, cfg.maxUploadFileMb);
    }

    private class WhatsAppErrorMockCallout implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String url = req.getEndpoint();
            if (url.contains('lookaside.fbsbx.com/fail')) {
                res.setStatusCode(500);
                res.setBody('Download error');
            } else if (url.contains('lookaside.fbsbx.com/empty')) {
                res.setStatusCode(200);
                res.setBodyAsBlob(Blob.valueOf(''));
            } else if (url.contains('m1_fail_meta')) {
                res.setStatusCode(500);
                res.setBody('Metadata error');
            } else if (url.contains('m2_fail_dl')) {
                res.setStatusCode(200);
                res.setBody('{"url": "https://lookaside.fbsbx.com/fail"}');
            } else if (url.contains('m3_empty')) {
                res.setStatusCode(200);
                res.setBody('{"url": "https://lookaside.fbsbx.com/empty"}');
            } else {
                res.setStatusCode(200);
                res.setBody('{"messages": [{"id": "mock"}]}');
            }
            return res;
        }
    }

    private class WhatsAppMockCallout implements HttpCalloutMock {
        private Long mockFileSize;
        WhatsAppMockCallout() { this.mockFileSize = 1024L; }
        WhatsAppMockCallout(Long mockFileSize) { this.mockFileSize = mockFileSize; }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('lookaside.fbsbx.com')) {
                res.setBodyAsBlob(Blob.valueOf('Mock content'));
            } else if (req.getMethod() == 'GET') {
                res.setBody('{"url": "https://lookaside.fbsbx.com/mock", "file_size": ' + mockFileSize + ', "mime_type": "application/pdf"}');
            } else {
                res.setBody('{"messages": [{"id": "mock"}]}');
            }
            return res;
        }
    }
}