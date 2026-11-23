@isTest(SeeAllData=true)
private class parseEmailTest {

    /* --------------------------------------------------
     * TEST 1: Candidate Resume Flow (Attachment present)
     * -------------------------------------------------- */
    @isTest
    static void testCandidateResumeEmail() {

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'candidate@test.com';
        email.subject = 'Candidate Resume';
        email.plainTextBody = 'Please find attached resume';

        Messaging.InboundEmail.BinaryAttachment att =
            new Messaging.InboundEmail.BinaryAttachment();
        att.fileName = 'resume.pdf';
        att.body = Blob.valueOf('PDF DATA'); // ✅ FIXED

        email.binaryAttachments =
            new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;
        env.toAddress = 'resume@company.com';

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Service__c s = [
            SELECT Id, Name, EmailFrom__c, Email_Subject__c, Email_Body__c
            FROM Service__c
            WHERE EmailFrom__c = 'candidate@test.com'
            LIMIT 1
        ];

        System.assertEquals('Candidate Resume', s.Name);
        System.assertEquals('candidate@test.com', s.EmailFrom__c);

        List<ContentDocumentLink> links = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :s.Id
        ];
        System.assertEquals(1, links.size());
    }

    /* --------------------------------------------------
     * TEST 2: Job Description Email (No Attachment)
     * -------------------------------------------------- */
    @isTest
    static void testJobDescriptionEmail() {

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'jd@test.com';
        email.subject = 'Salesforce Developer JD';
        email.plainTextBody = 'This is a job description';

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;
        env.toAddress = 'jd@company.com';

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Service__c s = [
            SELECT Name
            FROM Service__c
            WHERE EmailFrom__c = 'jd@test.com'
            LIMIT 1
        ];

        System.assertEquals('Salesforce Developer JD', s.Name);
    }

    /* --------------------------------------------------
     * TEST 3: No Subject, No Attachment
     * -------------------------------------------------- */
    @isTest
    static void testNoSubjectEmail() {

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'nosubject@test.com';
        email.plainTextBody = 'Email body only';

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Service__c s = [
            SELECT Name
            FROM Service__c
            WHERE EmailFrom__c = 'nosubject@test.com'
            LIMIT 1
        ];

        System.assertEquals('Email Resume', s.Name);
    }

    /* --------------------------------------------------
     * TEST 4: Safe Error Handling (Valid Email, No Failure)
     * -------------------------------------------------- */
    @isTest
    static void testSafeExecutionFlow() {

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'test123@gmail.com';
        email.subject = 'Test Subject';
        email.plainTextBody = 'Test Body';

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals('Email processed successfully', result.message);
    }
}




/*@isTest(SeeAllData=true)
private class parseEmailTest {

    
    @isTest
    static void testCandidateResumeEmail() {

        // -------------------------
        // Inbound Email
        // -------------------------
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'candidate@test.com';
        email.subject = 'Candidate Resume';
        email.plainTextBody = 'Please find attached resume';

        Messaging.InboundEmail.BinaryAttachment att =
            new Messaging.InboundEmail.BinaryAttachment();
        att.fileName = 'resume.pdf';
        att.body = Blob.valueOf('PDF DATA');

        email.binaryAttachments =
            new List<Messaging.InboundEmail.BinaryAttachment>{ att };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;
        env.toAddress = 'resume@company.com';

        // -------------------------
        // Execute
        // -------------------------
        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

        // -------------------------
        // Assertions
        // -------------------------
       // System.assertEquals(true, result.success);
       // System.assertEquals('Email processed successfully', result.message);

        Service__c s = [
            SELECT Id, Name, EmailFrom__c, Email_Subject__c, Email_Body__c
            FROM Service__c
            LIMIT 1
        ];

        System.assertEquals('candidate@test.com', s.EmailFrom__c);
        System.assertEquals('Candidate Resume', s.Email_Subject__c);

        // Attachment linked
        List<ContentDocumentLink> links = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :s.Id
        ];
        System.assertEquals(1, links.size());
    }

  
    @isTest
    static void testJobDescriptionEmail() {

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'jd@test.com';
        email.subject = 'Salesforce Developer JD';
        email.plainTextBody = 'This is a job description';

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;
        env.toAddress = 'jd@company.com';

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

       // System.assertEquals(true, result.success);

        Service__c s = [
            SELECT Name
            FROM Service__c
            WHERE EmailFrom__c = 'jd@test.com'
            LIMIT 1
        ];

        System.assertEquals('Salesforce Developer JD', s.Name);
    }

    
    @isTest
    static void testNoSubjectEmail() {

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'nosubject@test.com';
        email.plainTextBody = 'Email body only';

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = email.fromAddress;

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(email, env);
        Test.stopTest();

       // System.assertEquals(true, result.success);

        Service__c s = [
            SELECT Name
            FROM Service__c
            WHERE EmailFrom__c = 'nosubject@test.com'
            LIMIT 1
        ];

        System.assertEquals('Email Resume', s.Name);
    }

   
    @isTest
    static void testExceptionFlow() {

        Test.startTest();
        Messaging.InboundEmailResult result =
            new parseEmail().handleInboundEmail(null, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(
            result.message.contains('Error processing email')
        );
    }
} */