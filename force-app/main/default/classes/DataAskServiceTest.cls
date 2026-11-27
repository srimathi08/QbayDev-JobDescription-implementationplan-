@IsTest
private class DataAskServiceTest {

    @TestSetup
    static void data() {
        Id clientRt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Direct_Customers').getRecordTypeId();
        Account c = new Account(Name = 'Acme Client', RecordTypeId = clientRt);
        insert c;
        insert new Opportunity(Name = 'Salesforce Developer', AccountId = c.Id, StageName = 'Discovery', CloseDate = Date.today().addDays(30));
    }

    @IsTest
    static void findsTheRightObjects() {
        Assert.areEqual('Opportunity', DataAskService.pickObjects('How many opportunities were created last week?')[0]);
        Assert.isTrue(DataAskService.pickObjects('show me all accounts').contains('Account'));
        Assert.isTrue(DataAskService.pickObjects('JDs added this month').contains('Job_Description__c'));
        Assert.isTrue(DataAskService.pickObjects('interviews scheduled today').contains('Interview__c'));
        Assert.isTrue(DataAskService.pickObjects('blue sky thinking').isEmpty());
        Assert.areEqual('opportunity', DataAskService.singular('opportunities'));
        Assert.areEqual('class', DataAskService.singular('classes'));
    }

    @IsTest
    static void routesPeopleSearchesAndDataQuestions() {
        Assert.areEqual('data', DataAskService.route('How many opportunities were created last week?'));
        Assert.areEqual('data', DataAskService.route('show me all accounts'));
        Assert.areEqual('people', DataAskService.route('Salesforce developer Chennai 5+ years'));
        Assert.areEqual('people', DataAskService.route('candidates with Apex and LWC'));
        Assert.areEqual('data', DataAskService.route('candidates created this month'));
    }

    @IsTest
    static void schemaHintsListFieldsAndRecordTypes() {
        String s = DataAskService.describeForPrompt(new List<String>{ 'Opportunity', 'Account' });
        Assert.isTrue(s.contains('Object Opportunity'));
        Assert.isTrue(s.contains('StageName'));
        Assert.isTrue(s.contains('Candidates'), 'Account record types are listed');
    }

    @IsTest
    static void answersAQuestionWithRowsAndCount() {
        DataAskService.mockResponse = '{"soql": "SELECT Id, Name, StageName, Account.Name, CreatedDate FROM Opportunity WHERE CreatedDate = THIS_WEEK ORDER BY CreatedDate DESC LIMIT 5", "title": "Opportunities created this week", "note": ""}';
        DataAskService.Answer a = DataAskService.ask('How many opportunities were created this week?');
        Assert.areEqual('Opportunity', a.objectApiName);
        Assert.areEqual(1, a.totalCount);
        Assert.areEqual(1, a.rows.size());
        Assert.areEqual('Salesforce Developer', a.rows[0].get('Name'));
        Assert.areEqual('Acme Client', a.rows[0].get('Account_Name'));
        Assert.isTrue(a.soql.endsWith('LIMIT 200'), a.soql);
        Assert.areEqual('name', a.columns[0].type);
    }

    @IsTest
    static void unsafeOrBrokenAnswersAreRefused() {
        for (String bad : new List<String>{
            '{"soql": "DELETE FROM Opportunity"}',
            '{"soql": "SELECT Id FROM Opportunity; SELECT Id FROM Account"}',
            '{"soql": "SELECT Id, (SELECT Id FROM Contacts) FROM Account"}',
            '{"soql": "SELECT Id FROM Opportunity FOR UPDATE"}',
            '{"note": "no query"}',
            'not json'
        }) {
            DataAskService.mockResponse = bad;
            try {
                DataAskService.ask('list all opportunities');
                Assert.fail('Expected a refusal for ' + bad);
            } catch (AuraHandledException e) {
                Assert.isTrue(String.isNotBlank(e.getMessage()));
            }
        }
        try {
            DataAskService.ask('blue sky thinking');
            Assert.fail('no object');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('which records'));
        }
    }

    @IsTest
    static void countQueryDropsOrderAndLimit() {
        Assert.areEqual('SELECT COUNT() FROM Opportunity WHERE CreatedDate = LAST_WEEK',
            DataAskService.countQueryOf('SELECT Id, Name FROM Opportunity WHERE CreatedDate = LAST_WEEK ORDER BY CreatedDate DESC LIMIT 200'));
    }
}