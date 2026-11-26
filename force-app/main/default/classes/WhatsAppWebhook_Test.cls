@IsTest
public class WhatsAppWebhook_Test {

    private static final String AUTH_PHONE = '919999000111';
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
        Test.getEventBus().deliver();
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
        Test.stopTest();

        List<Service__c> svcs = [SELECT Name, Status__c, Detected_Type__c FROM Service__c ORDER BY CreatedDate ASC];
        System.assertEquals(2, svcs.size());
        System.assertEquals('Rejected', svcs[0].Status__c);
        System.assertEquals('Other', svcs[0].Detected_Type__c);
        System.assertEquals('Rejected', svcs[1].Status__c);
        System.assertEquals('Other', svcs[1].Detected_Type__c);
    }

    @IsTest
    static void test_doPost_pdfResumeOwnedByInternalUserAndRoutedViaPlatformEvent() {
        String body = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.DOC1","from":"' + AUTH_PHONE
            + '","type":"document","document":{"id":"doc1","mime_type":"application/pdf","filename":"resume.pdf"}}],"contacts":[{"wa_id":"' + AUTH_PHONE + '"}]}}]}]}';

        IntakeRouter.mockResponse = '{"documentType":"Resume","confidence":0.98,"reason":"Candidate CV"}';
        initContext('POST', body, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        User authUser = getAuthorizedUser();
        Service__c svc = [
            SELECT Id, Name, OwnerId, emailfrom__c, Status__c, Requested_Type__c, Detected_Type__c, File_Checksum__c, Whatsapp__c, Source_Channel__c
            FROM Service__c LIMIT 1
        ];
        System.assertEquals('resume.pdf', svc.Name);
        System.assertEquals(authUser.Id, svc.OwnerId);
        System.assertEquals(authUser.Email, svc.emailfrom__c);
        System.assertEquals('WhatsApp', svc.Source_Channel__c);
        System.assertEquals(false, svc.Whatsapp__c);
        System.assertNotEquals(null, svc.File_Checksum__c);
        System.assertEquals('Queued', svc.Status__c);
        System.assertEquals('Resume', svc.Requested_Type__c);
        System.assertEquals('Resume', svc.Detected_Type__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :svc.Id]);
    }

    @IsTest
    static void test_doPost_openModeAllowsExternalWhenSettingDisabled() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        cfg.restrictWhatsAppToInternal = false;

        String body = '{"entry":[{"changes":[{"value":{"messages":[{"id":"wamid.OPEN1","from":"' + UNAUTH_PHONE
            + '","type":"document","document":{"id":"docOpen","mime_type":"application/vnd.openxmlformats-officedocument.wordprocessingml.document","filename":"Java_JD.docx"}}]}}]}]}';

        IntakeRouter.mockResponse = '{"documentType":"Job Description","confidence":0.94,"reason":"Hiring spec"}';
        initContext('POST', body, new Map<String, String>{ 'X-Hub-Signature-256' => signBody(body) });
        Test.setMock(HttpCalloutMock.class, new WhatsAppMockCallout());

        Test.startTest();
        WhatsAppWebhook.doPost();
        Test.getEventBus().deliver();
        Test.stopTest();

        Service__c svc = [SELECT Status__c, Requested_Type__c, File_Checksum__c FROM Service__c LIMIT 1];
        System.assertEquals('Queued', svc.Status__c);
        System.assertEquals('Job Description', svc.Requested_Type__c);
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
        IntakeRouter.mockResponse = '{"documentType":"Resume","confidence":0.9,"reason":"CV"}';
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
    }

    @IsTest
    static void test_settingsIncludeWhatsAppRetryAndRestriction() {
        IntakeRouter.cachedSettings = null;
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        System.assert(cfg.retryChannels.contains('Email'));
        System.assert(cfg.retryChannels.contains('WhatsApp'));
        System.assertEquals(true, cfg.restrictWhatsAppToInternal);
    }

    private class WhatsAppMockCallout implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getMethod() == 'GET' && req.getEndpoint().contains('lookaside.fbsbx.com')) {
                res.setBodyAsBlob(Blob.valueOf('Mock content'));
            } else if (req.getMethod() == 'GET') {
                res.setBody('{"url": "https://lookaside.fbsbx.com/mock"}');
            } else {
                res.setBody('{"messages": [{"id": "mock"}]}');
            }
            return res;
        }
    }
}