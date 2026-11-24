@IsTest
private class AiJsonTest {
    @IsTest
    static void parsing() {
        Assert.isNull(AiJson.parse(null));
        Assert.isNull(AiJson.parse('not json'));
        Map<String, Object> m = AiJson.parse('```json\n{"a":" x ","b":"null","n":5,"l":[{"k":1}],"s":["p","q"]}\n```');
        Assert.areEqual('x', AiJson.str(m, 'a'));
        Assert.isNull(AiJson.str(m, 'b'));
        Assert.areEqual('5', AiJson.str(m, 'n'));
        Assert.areEqual(1, AiJson.objList(m, 'l').size());
        Assert.areEqual(2, AiJson.strList(m, 's').size());
        Assert.areEqual('Resume', AiJson.documentType('{"documentType":"resume"}'));
        Assert.areEqual('Job Description', AiJson.documentType('{"documentType":"Job Description"}'));
        Assert.areEqual('Other', AiJson.documentType('{"documentType":"invoice"}'));
        Assert.isNull(AiJson.documentType('{}'));
    }

    @IsTest
    static void conversions() {
        Assert.areEqual(Date.newInstance(2024, 3, 5), AiJson.toDate('2024-03-05'));
        Assert.areEqual(Date.newInstance(2024, 3, 1), AiJson.toDate('2024-03'));
        Assert.areEqual(Date.newInstance(1995, 5, 15), AiJson.toDate('15/05/1995'));
        Assert.areEqual(Date.newInstance(2023, 9, 1), AiJson.toDate('Sept-2023'));
        Assert.isNull(AiJson.toDate('Present'));
        Assert.isNull(AiJson.toDate('31/02/2020x'));
        Assert.areEqual(3, AiJson.toNumber('3-5 years'));
        Assert.areEqual(6.5, AiJson.toNumber('6.5 yrs'));
        Assert.isNull(AiJson.toNumber('none'));
        Assert.areEqual('9876543210', AiJson.digitsOnly('+91 98765-43210'));
        Assert.isNull(AiJson.digitsOnly('123'));
        Assert.areEqual('a.b@x.com', AiJson.normalizeEmail(' A.B@X.com '));
        Assert.isNull(AiJson.normalizeEmail('abgmailcom'));
        Assert.areEqual('linkedin.com/in/abc', AiJson.normalizeUrl('https://www.LinkedIn.com/in/abc/'));
    }
}
