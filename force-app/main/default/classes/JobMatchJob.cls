/**
 * Runs candidate matching in the background (27-11-2026).
 *
 *  1. Quick fit (JobMatchEngine): jobs in chunks of JOBS_PER_RUN, or a few candidates against the open jobs.
 *  2. AI fit: Einstein prompt Qbay_Job_Fit, AI_PER_RUN matches per run, only for the queue that step 1 builds
 *     (top 10 per job with quick fit >= 30). A match whose job and candidate text did not change since the
 *     last AI answer is skipped, so re-runs cost no tokens.
 * Errors are saved on the match (Match_Status__c = Error, Error_Message__c) instead of being lost.
 */
public without sharing class JobMatchJob implements Queueable, Database.AllowsCallouts {

    public static final String TEMPLATE = 'Qbay_Job_Fit';
    static final Integer JOBS_PER_RUN = 5;
    static final Integer AI_PER_RUN = 10;

    @TestVisible static String mockResponse;

    private List<Id> jobIds = new List<Id>();
    private Set<Id> candidateIds = new Set<Id>();
    private List<Id> aiQueue = new List<Id>();

    /** Score these jobs against every candidate. */
    public JobMatchJob(List<Id> jobIds) {
        this.jobIds = jobIds == null ? new List<Id>() : new List<Id>(new Set<Id>(jobIds));
    }

    /** Reverse matching: score these candidates against the open jobs of the last 90 days. */
    public JobMatchJob(Set<Id> candidateIds) {
        this.candidateIds = candidateIds == null ? new Set<Id>() : candidateIds;
    }

    private JobMatchJob() {
    }

    // ---------------------------------------------------------------- entry points

    /** Safe to call from triggers and other async jobs: skips (the nightly run catches up) when no queueable slot is left. */
    public static Id enqueueJobs(List<Id> jobIds) {
        if (jobIds == null || jobIds.isEmpty()) return null;
        return enqueue(new JobMatchJob(jobIds));
    }

    public static Id enqueueCandidates(Set<Id> candidateIds) {
        if (candidateIds == null || candidateIds.isEmpty()) return null;
        return enqueue(new JobMatchJob(candidateIds));
    }

    static Id enqueue(JobMatchJob job) {
        try {
            if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return null;
            return System.enqueueJob(job);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'JobMatchJob', 'enqueue');
            return null;
        }
    }

    // ---------------------------------------------------------------- run

    public void execute(QueueableContext ctx) {
        JobMatchJob next;
        try {
            next = runOnce();
        } catch (Exception e) {
            UtilityClass.createElog(e, 'JobMatchJob', 'execute');
        }
        if (next != null && !Test.isRunningTest()) System.enqueueJob(next);
    }

    /** Does one slice of work and returns the job for the next slice (or null when done). */
    @TestVisible
    JobMatchJob runOnce() {
        JobMatchJob next = new JobMatchJob();
        next.aiQueue.addAll(aiQueue);

        if (!jobIds.isEmpty()) {
            Set<Id> slice = new Set<Id>();
            List<Id> rest = new List<Id>();
            for (Id i : jobIds) {
                if (slice.size() < JOBS_PER_RUN) slice.add(i); else rest.add(i);
            }
            next.aiQueue.addAll(JobMatchEngine.scoreJobs(slice).aiQueue);
            next.jobIds = rest;
        } else if (!candidateIds.isEmpty()) {
            next.aiQueue.addAll(JobMatchEngine.scoreCandidates(candidateIds).aiQueue);
        } else if (!aiQueue.isEmpty()) {
            List<Id> slice = new List<Id>();
            next.aiQueue = new List<Id>();
            for (Id i : aiQueue) {
                if (slice.size() < AI_PER_RUN) slice.add(i); else next.aiQueue.add(i);
            }
            aiScore(slice);
        }
        Boolean more = !next.jobIds.isEmpty() || !next.aiQueue.isEmpty();
        return more ? next : null;
    }

    // ---------------------------------------------------------------- AI stage

    public static Integer aiScore(List<Id> matchIds) {
        List<Job_Match__c> rows = [
            SELECT Id, Opportunity_Name__c, Candidate_Name__c, Quick_Fit_Score__c, AI_Fit_Score__c, AI_Input_Hash__c
            FROM Job_Match__c WHERE Id IN :matchIds
        ];
        Set<Id> jobIds = new Set<Id>();
        Set<Id> personIds = new Set<Id>();
        for (Job_Match__c m : rows) {
            jobIds.add(m.Opportunity_Name__c);
            personIds.add(m.Candidate_Name__c);
        }
        Map<Id, String> jobTexts = new Map<Id, String>();
        for (Opportunity o : JobMatchEngine.queryJobs(jobIds, false)) {
            jobTexts.put(o.Id, JobMatchEngine.jobText(JobMatchEngine.jobProfile(o)));
        }
        Map<Id, String> personTexts = new Map<Id, String>();
        for (Account a : JobMatchEngine.queryPeople(personIds)) {
            personTexts.put(a.Id, JobMatchEngine.personText(JobMatchEngine.personProfile(a)));
        }

        // all callouts first, then one update
        List<Job_Match__c> updates = new List<Job_Match__c>();
        Integer calls = 0;
        for (Job_Match__c m : rows) {
            String job = jobTexts.get(m.Opportunity_Name__c);
            String person = personTexts.get(m.Candidate_Name__c);
            if (job == null || person == null) continue;
            String hash = JobMatchEngine.fingerprint(job, person);
            if (hash == m.AI_Input_Hash__c && m.AI_Fit_Score__c != null) continue; // nothing changed: no tokens spent
            Job_Match__c u = new Job_Match__c(Id = m.Id, Scored_On__c = Datetime.now());
            try {
                calls++;
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleanJson(callPrompt(job, person)));
                Integer score = Math.max(0, Math.min(100, Integer.valueOf(String.valueOf(parsed.get('score')).replaceAll('[^0-9]', ''))));
                String strengths = parsed.get('strengths') == null ? '' : String.valueOf(parsed.get('strengths'));
                String gaps = parsed.get('gaps') == null ? '' : String.valueOf(parsed.get('gaps'));
                u.AI_Fit_Score__c = score;
                u.Match_Score__c = JobMatchEngine.blend(m.Quick_Fit_Score__c, score);
                u.AI_Input_Hash__c = hash;
                u.Match_Status__c = 'AI Scored';
                u.Error_Message__c = null;
                u.Explanation__c = 'Score ' + u.Match_Score__c + '/100 = average of quick fit ' + m.Quick_Fit_Score__c + ' and AI fit ' + score + '. '
                    + (String.isNotBlank(strengths) ? 'Strengths: ' + strengths.trim() + ' ' : '')
                    + (String.isNotBlank(gaps) ? 'Gaps: ' + gaps.trim() : '');
            } catch (Exception e) {
                u.Match_Status__c = 'Error';
                u.Error_Message__c = ('AI scoring failed: ' + e.getMessage()).left(255);
            }
            updates.add(u);
        }
        if (!updates.isEmpty()) Database.update(updates, false);
        return calls;
    }

    static String callPrompt(String job, String person) {
        ConnectApi.WrappedValue j = new ConnectApi.WrappedValue();
        j.value = job;
        ConnectApi.WrappedValue c = new ConnectApi.WrappedValue();
        c.value = person;
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:job' => j, 'Input:candidate' => c };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.isPreview = false;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation out = Test.isRunningTest()
            ? CandidateCreationPrompt.fakeOutput(mockResponse)
            : ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, input);
        return CandidateCreationPrompt.textOf(out, 'The AI returned an empty answer.');
    }

    static String cleanJson(String s) {
        String t = s == null ? '' : s.replace('```json', '').replace('```', '').trim();
        Integer a = t.indexOf('{');
        Integer b = t.lastIndexOf('}');
        return (a >= 0 && b > a) ? t.substring(a, b + 1) : t;
    }
}
