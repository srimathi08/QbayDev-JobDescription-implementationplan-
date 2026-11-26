@IsTest
private class IntakeControllerTest {

    @IsTest
    static void submitIsIdempotentPerRequestKey() {
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('pdf-bytes'));
        CandidateCreationPrompt.mockResponse = IntakeTestData.resumeJson('Asha N', 'asha@example.com', null);
        Test.startTest();
        IntakeController.IntakeStatus s1 = IntakeController.submitFile('key-1', 'Resume', 'asha.pdf', b64);
        IntakeController.IntakeStatus s2 = IntakeController.submitFile('key-1', 'Resume', 'asha.pdf', b64);
        Test.stopTest();
        Assert.areEqual(s1.serviceId, s2.serviceId);
        Assert.areEqual(1, [SELECT COUNT() FROM Service__c]);
        Service__c s = [SELECT Status__c, Source_Channel__c, File_Checksum__c FROM Service__c];
        Assert.areEqual('Completed', s.Status__c);
        Assert.areEqual('UI Upload', s.Source_Channel__c);
        Assert.isNotNull(s.File_Checksum__c);
        Assert.areEqual(1, IntakeController.getStatus(new List<Id>{ s1.serviceId }).size());
        Assert.areEqual(1, IntakeController.getMyUploadsToday('Resume').size());
    }

    @IsTest
    static void rejectsUnsupportedOrBadInput() {
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('x'));
        List<List<String>> bad = new List<List<String>>{
            new List<String>{ 'k1', 'Resume', 'cv.doc', b64 },
            new List<String>{ 'k2', 'Resume', 'cv.csv', b64 },
            new List<String>{ '', 'Resume', 'cv.pdf', b64 },
            new List<String>{ 'k3', 'Other', 'cv.pdf', b64 },
            new List<String>{ 'k4', 'Resume', 'cv.pdf', '' }
        };
        for (List<String> b : bad) {
            try {
                IntakeController.submitFile(b[0], b[1], b[2], b[3]);
                Assert.fail('Expected an error for ' + b);
            } catch (AuraHandledException e) {
                Assert.isTrue(String.isNotBlank(e.getMessage()));
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Service__c]);
    }

    @IsTest
    static void helpers() {
        Assert.areEqual('pdf', IntakeController.extensionOf('A.B.PDF'));
        Assert.areEqual('', IntakeController.extensionOf('noext'));
        Assert.areEqual('A.B', IntakeController.titleOf('A.B.PDF'));
    }
}