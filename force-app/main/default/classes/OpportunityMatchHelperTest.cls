@isTest
public class OpportunityMatchHelperTest {

    @testSetup
    static void setupData() {
        // ✅ Record Type (if lookup filter depends on it)
        RecordType accRT = [
            SELECT Id 
            FROM RecordType 
            WHERE SObjectType = 'Account' 
            LIMIT 1
        ];

        // ✅ Candidate Account
        Account candidate = new Account(
            Name = 'Candidate Tester',
            Type = 'Candidate',
            RecordTypeId = accRT.Id
        );
        insert candidate;

        // ✅ Interviewer Account
        Account interviewer = new Account(
            Name = 'Candidate Interview',
            Type = 'Candidate',
            RecordTypeId = accRT.Id
        );
        insert interviewer;

        // ✅ Opportunity
        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(10),
            Job_Description__c = 'Salesforce Developer required',
            Skills_Required__c = 'Apex, LWC',
            Experience_Required__c = '3 Years'
        );
        insert opp;

        // ✅ Skill Master
        Skill__c skillMaster = new Skill__c(
            Skill_Name__c = 'Apex',
            Category__c = 'Programming',
            Active__c = true
        );
        insert skillMaster;

        // ✅ Employee Skill
        Employee_Skill__c empSkill = new Employee_Skill__c(
            Employee_Name__c = candidate.Id,
            Skill__c = skillMaster.Id,
            Proficiency__c = 'Expert'
        );
        insert empSkill;

        // ✅ Certification
        Certification__c cert = new Certification__c(
            Candidate_Name__c = candidate.Id,
            Name = 'Salesforce Admin'
        );
        insert cert;

        // ✅ Project Experience
        Project_Experience__c proj = new Project_Experience__c(
            Employee_Name__c = candidate.Id,
            Project_Name__c = 'Migration',
            Skills_Applied__c = 'Apex',
            Tools_Used__c = 'Data Loader',
            Achievements__c = 'Optimized Data Flow'
        );
        insert proj;
    }

    // ✅ Test: generateMatchesForSubset()
    @isTest
    static void testGenerateMatchesForSubset() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account acc = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1];

        Test.startTest();
        OpportunityMatchHelper.generateMatchesForSubset(opp.Id, new List<Id>{acc.Id});
        Test.stopTest();

        List<Job_Match__c> matches = [SELECT Id, Match_Score__c, Explanation__c FROM Job_Match__c];
        System.assert(!matches.isEmpty(), 'Job_Match__c should be created');
    }

    // ✅ Test: getAllMatches()
    @isTest
    static void testGetAllMatches() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account acc = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1];

        Job_Match__c jm = new Job_Match__c(
            Candidate_Name__c = acc.Id,
            Opportunity_Name__c = opp.Id,
            Match_Score__c = 90,
            Explanation__c = 'Good fit'
        );
        insert jm;

        List<Job_Match__c> results = OpportunityMatchHelper.getAllMatches(opp.Id);
        System.assertEquals(1, results.size());
        System.assertEquals(90, results[0].Match_Score__c);
    }

    // ✅ Test: getInterviewByCandidate()
    @isTest
    static void testGetInterviewByCandidate() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account candidate = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1];
        Account interviewer = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1 OFFSET 1];

        Interview__c interview = new Interview__c(
            Candidate_Name__c = candidate.Id,
            Interviewer_Name__c = interviewer.Id,
            Scheduled_Date_Time__c = System.now().addDays(1),
            Opportunity__c = opp.Id,
            Job_Description__c = 'Developer Interview'
        );
        insert interview;

        Interview__c result = OpportunityMatchHelper.getInterviewByCandidate(candidate.Id);
        System.assertEquals(interviewer.Id, result.Interviewer_Name__c);
    }

    // ✅ Test: getOpportunityDetails()
    @isTest
    static void testGetOpportunityDetails() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Opportunity result = OpportunityMatchHelper.getOpportunityDetails(opp.Id);
        System.assertEquals(opp.Id, result.Id);
    }

    // ✅ Test: createInterviewRecord()
    @isTest
    static void testCreateInterviewRecord() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account candidate = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1];
        Account interviewer = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1 OFFSET 1];

        Map<String, Object> interviewData = new Map<String, Object>{
            'Candidate_Name__c' => candidate.Id,
            'Interviewer_Name__c' => interviewer.Id,
            'Scheduled_Date_Time__c' => System.now().addDays(2),
            'Opportunity__c' => opp.Id,
            'Job_Description__c' => 'Technical Interview'
        };

        OpportunityMatchHelper.createInterviewRecord(interviewData);

        List<Interview__c> interviews = [SELECT Id FROM Interview__c WHERE Candidate_Name__c = :candidate.Id];
        System.assert(!interviews.isEmpty(), 'Interview should be created');
    }

    // ✅ Test: saveInterview() success
    @isTest
    static void testSaveInterview_success() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account candidate = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1];
        Account interviewer = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1 OFFSET 1];

        Test.startTest();
        OpportunityMatchHelper.saveInterview(
            'test@test.com',
            interviewer.Id,
            System.now().addDays(3),
            candidate.Id,
            opp.Id,
            'Job Desc'
        );
        Test.stopTest();

        List<Interview__c> interviews = [SELECT Id FROM Interview__c WHERE Candidate_Name__c = :candidate.Id];
        System.assert(!interviews.isEmpty());
    }

    // ✅ Test: saveInterview() failure for blank email
    @isTest
    static void testSaveInterview_failure() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Account candidate = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1];
        Account interviewer = [SELECT Id FROM Account WHERE Type = 'Candidate' LIMIT 1 OFFSET 1];

        Boolean thrown = false;
        try {
            OpportunityMatchHelper.saveInterview(
                '', // blank email
                interviewer.Id,
                System.now().addDays(3),
                candidate.Id,
                opp.Id,
                'Job Desc'
            );
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'Should throw exception for missing email');
    }
}