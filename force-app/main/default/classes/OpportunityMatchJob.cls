/**
 * Kept for existing callers. Since 27-11-2026 it runs the two-stage matching (JobMatchJob):
 * quick fit for every candidate, AI only for the top 10 per job.
 */
public class OpportunityMatchJob implements Queueable, Database.AllowsCallouts {
    private List<Id> opportunityIds;

    public OpportunityMatchJob(Id oppId) {
        this.opportunityIds = new List<Id>{ oppId };
    }

    public OpportunityMatchJob(List<Id> oppIds) {
        this.opportunityIds = oppIds;
    }

    public void execute(QueueableContext context) {
        new JobMatchJob(opportunityIds).execute(context);
    }
}