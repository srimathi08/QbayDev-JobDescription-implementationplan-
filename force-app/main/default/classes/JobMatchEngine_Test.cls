@isTest
private class JobMatchEngine_Test {

    static Id rt(String sobj, String devName) {
        return [SELECT Id FROM RecordType WHERE SObjectType = :sobj AND DeveloperName = :devName LIMIT 1].Id;
    }

    @testSetup
    static void setup() {
        Account client = new Account(Name = 'Client Co', RecordTypeId = rt('Account', 'Direct_Customers'));
        insert client;

        Id candRt = rt('Account', 'Candidates');
        Account strong = new Account(Name = 'Strong Dev', RecordTypeId = candRt, Designation__c = 'Salesforce Developer',
            Years_of_Experience__c = '4 years', Current_Location__c = 'Bengaluru, India', Description = 'Built Apex triggers and LWC screens.');
        Account weak = new Account(Name = 'Weak Fit', RecordTypeId = candRt, Designation__c = 'Accountant',
            Years_of_Experience__c = '1 year', Current_Location__c = 'Jaipur');
        insert new List<Account>{ strong, weak };

        List<Skill__c> skills = new List<Skill__c>{
            new Skill__c(Skill_Name__c = 'Apex Test Skill X', Category__c = 'Technical', Role__c = 'Developer', Active__c = true),
            new Skill__c(Skill_Name__c = 'Lightning Web Components', Category__c = 'Technical', Role__c = 'Developer', Active__c = true),
            new Skill__c(Skill_Name__c = 'Tally', Category__c = 'Technical', Role__c = 'Developer', Active__c = true)
        };
        insert skills;
        insert new List<Employee_Skill__c>{
            new Employee_Skill__c(Name = 'S1', Employee_Name__c = strong.Id, Skill__c = skills[0].Id, Primary_Secondary_Skill__c = 'Primary Skill', Proficiency__c = 'Beginner'),
            new Employee_Skill__c(Name = 'S2', Employee_Name__c = strong.Id, Skill__c = skills[1].Id, Primary_Secondary_Skill__c = 'Primary Skill', Proficiency__c = 'Beginner'),
            new Employee_Skill__c(Name = 'S3', Employee_Name__c = weak.Id, Skill__c = skills[2].Id, Primary_Secondary_Skill__c = 'Primary Skill', Proficiency__c = 'Beginner')
        };

        Opportunity job = new Opportunity(Name = 'Salesforce Developer', RecordTypeId = rt('Opportunity', 'Resourcing'),
            AccountId = client.Id, StageName = 'Discovery', CloseDate = Date.today().addDays(30),
            Skills_Required__c = 'Apex, LWC, SOQL', Experience_Required__c = '3-5 years', Job_Location__c = 'Bangalore',
            Role_Required__c = 'Salesforce Developer', Job_Description__c = 'Salesforce developer for Apex and LWC.',
            Generate_Match__c = 'Ignore');
        insert job;
    }

    @isTest
    static void normalisesSynonymsAndRanges() {
        System.assertEquals('lwc', JobMatchEngine.norm('Lightning Web Components'));
        System.assertEquals('rest api', JobMatchEngine.norm('RESTful APIs'));
        System.assertEquals('cicd', JobMatchEngine.norm('CI/CD'));
        System.assertEquals('bengaluru karnataka', JobMatchEngine.norm('Bangalore, Karnataka'));
        Decimal[] r = JobMatchEngine.parseRange('3-5 Years');
        System.assertEquals(3, r[0]);
        System.assertEquals(5, r[1]);
        System.assertEquals(5, JobMatchEngine.parseRange('5+ years')[0]);
        System.assertEquals(null, JobMatchEngine.parseRange('5+ years')[1]);
        System.assertEquals(null, JobMatchEngine.parseRange('')[0]);
        System.assertEquals(0.5, JobMatchEngine.parseYears('6 months'));
        System.assertEquals(3, JobMatchEngine.splitList('Apex, LWC and SOQL').size());
    }

    @isTest
    static void quickFitRanksTheRightPerson() {
        Opportunity job = [SELECT Id FROM Opportunity LIMIT 1];
        Test.startTest();
        JobMatchEngine.RunResult res = JobMatchEngine.scoreJobs(new Set<Id>{ job.Id });
        Test.stopTest();

        System.assertEquals(2, res.saved);
        Map<String, Job_Match__c> byName = new Map<String, Job_Match__c>();
        for (Job_Match__c m : [SELECT Candidate_Name__r.Name, Match_Score__c, Quick_Fit_Score__c, Match_Key__c,
                                      Skills_Matched__c, Skills_Missing__c, Match_Status__c, Explanation__c FROM Job_Match__c]) {
            byName.put(m.Candidate_Name__r.Name, m);
        }
        Job_Match__c s = byName.get('Strong Dev');
        Job_Match__c w = byName.get('Weak Fit');
        System.assert(s.Quick_Fit_Score__c > w.Quick_Fit_Score__c, 'strong ' + s.Quick_Fit_Score__c + ' weak ' + w.Quick_Fit_Score__c);
        System.assert(s.Quick_Fit_Score__c >= 70, 'strong candidate scored ' + s.Quick_Fit_Score__c + ': ' + s.Explanation__c);
        System.assert(s.Skills_Matched__c.contains('LWC'), s.Skills_Matched__c);
        System.assert(s.Skills_Missing__c.contains('SOQL'), s.Skills_Missing__c);
        System.assertEquals(s.Quick_Fit_Score__c, s.Match_Score__c);
        System.assertNotEquals(null, s.Match_Key__c);
        System.assertEquals('Waiting for AI', s.Match_Status__c, 'top candidate goes to the AI queue');
        System.assertEquals(1, res.aiQueue.size(), 'only quick fit >= 30 goes to the AI');

        // running again updates, never duplicates
        JobMatchEngine.scoreJobs(new Set<Id>{ job.Id });
        System.assertEquals(2, [SELECT COUNT() FROM Job_Match__c]);
    }

    @isTest
    static void adoptsLegacyRowInsteadOfDuplicating() {
        Opportunity job = [SELECT Id FROM Opportunity LIMIT 1];
        Account a = [SELECT Id FROM Account WHERE Name = 'Strong Dev'];
        insert new Job_Match__c(Opportunity_Name__c = job.Id, Candidate_Name__c = a.Id, Match_Score__c = 0, Explanation__c = 'old');
        JobMatchEngine.scoreCandidates(new Set<Id>{ a.Id });
        List<Job_Match__c> rows = [SELECT Match_Key__c, Match_Score__c FROM Job_Match__c WHERE Candidate_Name__c = :a.Id];
        System.assertEquals(1, rows.size());
        System.assertNotEquals(null, rows[0].Match_Key__c);
        System.assert(rows[0].Match_Score__c > 0);
    }

    @isTest
    static void aiScoresTopCandidatesOnce() {
        Opportunity job = [SELECT Id FROM Opportunity LIMIT 1];
        JobMatchEngine.RunResult res = JobMatchEngine.scoreJobs(new Set<Id>{ job.Id });
        JobMatchJob.mockResponse = '```json\n{"score": 88, "strengths": "Apex and LWC", "gaps": "SOQL depth"}\n```';
        Test.startTest();
        Integer calls = JobMatchJob.aiScore(res.aiQueue);
        Integer second = JobMatchJob.aiScore(res.aiQueue);
        Test.stopTest();
        System.assertEquals(1, calls);
        System.assertEquals(0, second, 'nothing changed, so no second AI call');
        Job_Match__c m = [SELECT AI_Fit_Score__c, Match_Score__c, Match_Status__c, Explanation__c FROM Job_Match__c WHERE Id = :res.aiQueue[0]];
        System.assertEquals(88, m.AI_Fit_Score__c);
        Decimal quick = [SELECT Quick_Fit_Score__c FROM Job_Match__c WHERE Id = :res.aiQueue[0]].Quick_Fit_Score__c;
        System.assertEquals(Math.round((quick + 88) / 2), m.Match_Score__c, 'average of quick fit and AI fit');
        System.assertEquals('AI Scored', m.Match_Status__c);
        System.assert(m.Explanation__c.contains('Strengths'));

        // a later quick-fit run keeps the AI score
        JobMatchEngine.scoreJobs(new Set<Id>{ job.Id });
        System.assertEquals(m.Match_Score__c, [SELECT Match_Score__c FROM Job_Match__c WHERE Id = :res.aiQueue[0]].Match_Score__c);
    }

    @isTest
    static void aiErrorIsSavedOnTheMatch() {
        Opportunity job = [SELECT Id FROM Opportunity LIMIT 1];
        JobMatchEngine.RunResult res = JobMatchEngine.scoreJobs(new Set<Id>{ job.Id });
        JobMatchJob.mockResponse = 'not json';
        JobMatchJob.aiScore(res.aiQueue);
        Job_Match__c m = [SELECT Match_Status__c, Error_Message__c, Match_Score__c, Quick_Fit_Score__c FROM Job_Match__c WHERE Id = :res.aiQueue[0]];
        System.assertEquals('Error', m.Match_Status__c);
        System.assertNotEquals(null, m.Error_Message__c);
        System.assertEquals(m.Quick_Fit_Score__c, m.Match_Score__c, 'quick fit stays as the score');
    }

    @isTest
    static void jobRunsQuickFitThenAi() {
        Opportunity job = [SELECT Id FROM Opportunity LIMIT 1];
        JobMatchJob.mockResponse = '{"score": 75, "strengths": "a", "gaps": "b"}';
        JobMatchJob step = new JobMatchJob(new List<Id>{ job.Id });
        Test.startTest();
        JobMatchJob next = step.runOnce();
        System.assertNotEquals(null, next, 'AI step follows');
        System.assertEquals(null, next.runOnce(), 'done after the AI step');
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Job_Match__c WHERE AI_Fit_Score__c = 75]);
    }

    @isTest
    static void reverseMatchingForNewCandidate() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Strong Dev'];
        Test.startTest();
        JobMatchJob step = new JobMatchJob(new Set<Id>{ a.Id });
        step.runOnce();
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Job_Match__c WHERE Candidate_Name__c = :a.Id]);
        System.assertEquals(0, [SELECT COUNT() FROM Job_Match__c WHERE Candidate_Name__r.Name = 'Weak Fit']);
    }

    @isTest
    static void controllerTriggerAndNightly() {
        Opportunity job = [SELECT Id FROM Opportunity LIMIT 1];
        JobMatchEngine.scoreJobs(new Set<Id>{ job.Id });
        Test.startTest();
        JobMatchController.MatchList ml = JobMatchController.getMatches(job.Id);
        System.assertEquals(2, ml.rows.size());
        System.assert(ml.rows[0].score >= ml.rows[1].score, 'sorted by score');
        System.assertEquals('Strong Dev', ml.rows[0].candidateName);
        System.assertEquals(1, ml.waiting);
        System.assertEquals(2, ml.rows.size());
        System.assert(JobMatchController.rescore(job.Id));
        new JobMatchNightly().execute(null);
        job.Generate_Match__c = 'Generate Match';
        update job;
        new OpportunityMatchJob(job.Id);
        Test.stopTest();
        System.assert([SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'JobMatchJob'] >= 1);
    }
}