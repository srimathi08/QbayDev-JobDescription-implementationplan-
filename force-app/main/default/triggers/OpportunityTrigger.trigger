/* Matching runs when Generate_Match__c is set to 'Generate Match' (new, or changed to it).
   One background job for all such opportunities in the save (27-11-2026). */
trigger OpportunityTrigger on Opportunity (after insert, after update) {
    List<Id> ids = new List<Id>();
    for (Opportunity opp : Trigger.new) {
        if (
            opp.Generate_Match__c == 'Generate Match' &&
            (Trigger.isInsert || Trigger.oldMap.get(opp.Id).Generate_Match__c != 'Generate Match')
        ) {
            ids.add(opp.Id);
        }
    }
    if (!ids.isEmpty()) JobMatchJob.enqueueJobs(ids);
}