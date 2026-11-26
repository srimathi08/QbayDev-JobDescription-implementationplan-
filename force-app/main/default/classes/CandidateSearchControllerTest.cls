@IsTest
private class CandidateSearchControllerTest {

    private static Id rt(String devName) {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get(devName).getRecordTypeId();
    }

    @TestSetup
    static void data() {
        List<Account> accs = new List<Account>{
            new Account(Name = 'Asha Apex', RecordTypeId = rt('Candidates'), Designation__c = 'Salesforce Developer',
                Experience_Years__c = 6, Current_Location__c = 'Chennai'),
            new Account(Name = 'Ravi Java', RecordTypeId = rt('Candidates'), Designation__c = 'Java Developer',
                Experience_Years__c = 3, Current_Location__c = 'Bangalore'),
            new Account(Name = 'Emp One', RecordTypeId = rt('Employee'), Designation__c = 'Salesforce Developer',
                Experience_Years__c = 8)
        };
        insert accs;
        insert new Employee_Skill__c(Name = 'Apex', Employee_Name__c = accs[0].Id);
        insert new Certification__c(Name = 'Platform Developer I', Candidate_Name__c = accs[0].Id);
        insert new ContentVersion(Title = 'Asha resume', PathOnClient = 'asha.pdf', VersionData = Blob.valueOf('x'),
            FirstPublishLocationId = accs[0].Id);
    }

    @IsTest
    static void parsesExperienceAndKeywords() {
        CandidateSearchController.Parsed p = CandidateSearchController.parse('Show Salesforce developers in Chennai with 5+ years experience');
        Assert.areEqual(5, p.minYears);
        Assert.isTrue(p.keywords.contains('salesforce'));
        Assert.isTrue(p.keywords.contains('chennai'));
        Assert.isFalse(p.keywords.contains('years'));
        Assert.isFalse(p.keywords.contains('show'));
        Assert.areEqual(3, CandidateSearchController.parse('at least 3 years C# .net').minYears);
        Assert.isTrue(CandidateSearchController.parse('C# developer').keywords.contains('c#'));
        Assert.areEqual('c\\+\\+', CandidateSearchController.escapeSosl('c++'));
    }

    @IsTest
    static void ranksCandidatesByKeywordsAndFiltersExperience() {
        Account asha = [SELECT Id FROM Account WHERE Name = 'Asha Apex'];
        Account ravi = [SELECT Id FROM Account WHERE Name = 'Ravi Java'];
        Test.setFixedSearchResults(new List<Id>{ asha.Id, ravi.Id });
        CandidateSearchController.SearchResponse r = CandidateSearchController.search('developer chennai 5+ years', null);
        Assert.areEqual(5, r.minYears);
        Assert.areEqual(1, r.results.size(), 'Ravi has 3 years, the employee is not a candidate');
        Assert.areEqual(asha.Id, r.results[0].id);
        Assert.areEqual('Candidate', r.results[0].recordType);
        Assert.isTrue(r.results[0].skills.contains('Apex'));
        Assert.isTrue(r.results[0].certifications.contains('Platform Developer I'));
        Assert.isNotNull(r.results[0].resumeId);
        Assert.areEqual(2, r.results[0].score);
    }

    @IsTest
    static void employeesCanBeIncluded() {
        Account emp = [SELECT Id FROM Account WHERE Name = 'Emp One'];
        Test.setFixedSearchResults(new List<Id>{ emp.Id });
        CandidateSearchController.SearchResponse r = CandidateSearchController.search('salesforce', new List<String>{ 'Candidates', 'Employee', 'Hacker' });
        Assert.areEqual(1, r.results.size());
        Assert.areEqual('Employee', r.results[0].recordType);
    }

    @IsTest
    static void onlyExperienceListsAllCandidates() {
        CandidateSearchController.SearchResponse r = CandidateSearchController.search('5+ years', null);
        Assert.areEqual(0, r.keywordCount);
        Assert.areEqual(1, r.results.size());
    }

    @IsTest
    static void noMatchAndBadInput() {
        CandidateSearchController.SearchResponse r = CandidateSearchController.search('cobol', null);
        Assert.areEqual(0, r.results.size());
        try {
            CandidateSearchController.search('  ', null);
            Assert.fail('blank search must be refused');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Please type'));
        }
    }

    @IsTest
    static void summaryUsesTheTopResults() {
        Account asha = [SELECT Id FROM Account WHERE Name = 'Asha Apex'];
        Assert.areEqual('<p>Summary</p>', CandidateSearchController.summarize('apex', new List<Id>{ asha.Id }));
        CandidateSearchController.mockSummary = null;
        try {
            CandidateSearchController.summarize('apex', new List<Id>{ asha.Id });
            Assert.fail('empty AI answer must give a friendly message');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not available'));
        }
    }
}
