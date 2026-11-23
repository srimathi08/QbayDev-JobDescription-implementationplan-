public with sharing class InternshipReminderScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        InternshipReminderBatch batch = new InternshipReminderBatch();
        Database.executeBatch(batch, 100);
    }
}