/*global class AsynCandidateCreationBatch implements Database.Batchable<sObject>
	{
    private String Serviceids;
    
     public AsynCandidateCreationBatch(String Serviceids){
         this.Serviceids = Serviceids;
   }    
        
    global Database.QueryLocator start(Database.BatchableContext BC)
    {
        return Database.getQueryLocator([ SELECT Id, ContentDocumentId, LinkedEntityId 
   FROM ContentDocumentLink WHERE LinkedEntityId=:serviceIds]); 
    }
    global void execute(Database.BatchableContext BC, List<ContentDocumentLink> scope)
    {		for(ContentDocumentLink s:scope){
    		CandidateCreationPrompt.getPDDPromptResponses(s.ContentDocumentId);	
			}	  
    }
    global void finish(Database.BatchableContext BC) {
    }
} */


global class AsynCandidateCreationBatch
    implements Database.Batchable<ContentDocumentLink> {

    private Id serviceId;

    global AsynCandidateCreationBatch(Id serviceId) {
        this.serviceId = serviceId;
    }

    // Use Iterable to avoid metadata cache issues
    global Iterable<ContentDocumentLink> start(Database.BatchableContext bc) {
        return [
            SELECT Id, ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :serviceId
        ];
    }

    global void execute(
        Database.BatchableContext bc,
        List<ContentDocumentLink> scope
    ) {
        for (ContentDocumentLink cdl : scope) {
            // 🔑 EXACT MATCH with your method signature
            CandidateCreationPrompt.getPDDPromptResponses(
                String.valueOf(cdl.ContentDocumentId)
            );
        }
    }

    global void finish(Database.BatchableContext bc) {
        System.debug('AsyncCandidateCreationBatch completed');
    }
}