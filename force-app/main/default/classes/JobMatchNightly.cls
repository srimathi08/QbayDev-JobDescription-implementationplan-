/**
 * Nightly matching refresh (27-11-2026): quick fit for every open job of the last 90 days against everyone,
 * AI only where a top-10 match's job or candidate changed. Catches manual edits and skipped runs.
 * Schedule once (after deploy): System.schedule('Qbay nightly matching', '0 0 2 * * ?', new JobMatchNightly());
 */
public without sharing class JobMatchNightly implements Schedulable {
    public void execute(SchedulableContext ctx) {
        List<Id> ids = new List<Id>(new Map<Id, Opportunity>(JobMatchEngine.queryJobs(null, true)).keySet());
        JobMatchJob.enqueueJobs(ids);
    }
}