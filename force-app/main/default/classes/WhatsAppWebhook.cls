/**
 * @class WhatsAppWebhook
 * @desc 
 *   Handles inbound webhook requests from WhatsApp Business API via Meta/Facebook Webhooks.
 *   Supports:
 *   - GET verification challenge from WhatsApp (for initial webhook setup)
 *   - POST message ingestion for image and PDF content types
 *   - Auto-creates Service__c records and links uploaded media via ContentDocumentLink
 *   - Validates WhatsApp signature using HMAC SHA-256 for request integrity
 * 
 * @urlMapping /whatsapp/webhooks/v1/*
 * 
 * @author Afrose Ahamed
 */
@RestResource(urlMapping='/whatsapp/webhooks/v1/*')
global without sharing class WhatsAppWebhook {
    
    private static Final String SIGNATURE_VALID_MESSAGE     = 'Signature Verified';
    private static Final String SIGNATURE_NOT_VALID_MESSAGE = 'Signature could not be verified';
    
    @HttpGet // GET
    global static void doGet() {
        RestResponse response = RestContext.response;
        RestRequest request = RestContext.request;
        if(request.params.get('hub.verify_token') == 'WHATSAPPTOKEN'){
            response.responseBody = Blob.valueOf( request.params.get('hub.challenge') );
        }
    }
    
    @HttpPost // POST
    global static void doPost() {
        
        RestResponse response = RestContext.response;
        response.addHeader('Content-type','application/json');
        String responseString = RestContext.request.requestBody.toString();
        Map<String, String> headers = RestContext.request.headers;
        String responseValid = validateWhatsAppSignature(RestContext.request, responseString);
        
        if(responseValid == SIGNATURE_VALID_MESSAGE){
            WhatsAppMessage messages =(WhatsAppMessage) JSON.deserialize(responseString, WhatsAppMessage.class); 
            List<Whatsappmessage.entry> messageEntries=messages.entry;
            System.debug(messageEntries);
            if(messageEntries !=null && messageEntries.size()>0){
                WhatsAppmessage.entry entrymessage=MessageEntries.get(0);
                List<WhatsAppmessage.changes> changeMessages=entrymessage.changes;
                if(changeMessages !=null && changeMessages.size()>0){
                    WhatsAppmessage.changes changeMessage=changeMessages.get(0);
                    system.debug('changeMessage'+changeMessage);
                    List<WhatsAppmessage.messages> messageList =changeMessage.value.messages;
                    system.debug('messageList'+messageList);
                    List<WhatsAppmessage.contacts> contactList =changeMessage.value.contacts;
                    System.debug('messageList'+messageList);
                    if(messageList !=null && messageList.size()>0){
                        //create service records
                        Service__c serv = new Service__c();
                        WhatsAppmessage.messages message =  messageList.get(0);
                        System.debug('message'+message);
                        serv.Name=message.from_x;
                        serv.Email_Body__c=(message.text != null && message.text.body != null)?message.text.body:''; 
                        serv.Whatsapp__c=true;
                        if(contactList !=null && contactList.size()>0){
                            WhatsAppmessage.contacts contact = contactList.get(0);
                            serv.whatsappfrom__c=contact.wa_id;
                            
                        }
                      //  if(message != null && message.image != null &&message.image.mime_type=='image/jpeg'){
if(message != null && message.image != null &&  (message.image.mime_type=='image/jpeg' || message.image.mime_type=='image/png')){
                            String imageid=message.image.id;
                            Blob imgcontent=WhatsAppUtils.getMedia(imageid); 
                            ContentVersion cv = new ContentVersion();
                            cv.VersionData = imgcontent;
                            //cv.Title = (message.document.filename != null) ? message.document.filename : 'WhatsAppDocument';
                           // cv.PathOnClient =(message.document.filename != null) ? message.document.filename : 'WhatsAppDocument'+'.png'; //message.document.filename !=null?message.document.filename:'';
                             cv.Title = 'WhatsAppImage';
                          cv.PathOnClient = 'WhatsAppImage' + (message.image.mime_type == 'image/png' ? '.png' : '.jpg');

                                try {
                                upsert serv;
                                insert cv;
                                ContentDocumentLink cdl = new ContentDocumentLink();
   					 cdl.ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id =: cv.Id ].ContentDocumentId;
         cdl.LinkedEntityId = serv.Id;
    // ShareType is either 'V', 'C', or 'I'
    // V = Viewer, C = Collaborator, I = Inferred
    cdl.ShareType = 'V';
                                
                              try {
      insert cdl;
                              }catch(exception e){
                                  system.debug(e);
                              }   
                            } catch(DMLException e) {
                                System.debug(e);
                                
                            }  
                        }else if(message.document != null && message.document.mime_type=='application/pdf'){
                            String docid=message.document.id;
                            Blob doccontent=WhatsAppUtils.getMedia(docid);
                            ContentVersion cv = new ContentVersion();
                            cv.VersionData = doccontent;
                            cv.Title = (message.document.filename != null) ? message.document.filename : 'WhatsAppDocument';
                            cv.PathOnClient =(message.document.filename != null) ? message.document.filename : 'WhatsAppDocument'+'.pdf'; //message.document.filename !=null?message.document.filename:''; 
                            try {
                               upsert serv;
                                insert cv;
                                AttachmentController.createContentLinkwhatsapp(cv.Id,serv.Id);
                             
                 
                            } catch(exception e) {
                                System.debug(e);
                                
                            }
                        }else{
                            try{
                            upsert serv;
                            }catch(exception e){
                                System.debug(e);
                            }  
                        }  
                    }
                }
            }
            
        }else{
            response.responseBody = Blob.valueOf('{success:false, event:"Unknown","message:"'+responseValid+'"}');
            response.statusCode = 401;
            return;
        }
        
        response.statusCode = 200;
        response.responseBody = Blob.valueOf('{success:true, event:"success"}');
    }
    
    private static String validateWhatsAppSignature(RestRequest request, String responseString) {
        // Validate Stripe signature Start 
        Map<String, String> headers = request.headers;
        
        String whatsAppSignature = headers.get('X-Hub-Signature-256');
        
        String whatsAppPayload = RestContext.request.requestBody.toString();
        
        // Verify the signature using 'hmacSHA256'. I have the Webhook key stored in a Custom Label
        String whatsAppSecret = System.Label.WHATSAPPSECRET; // Facebook Application Secret Key
        Blob signedPayload = Crypto.generateMac('hmacSHA256', Blob.valueOf(whatsAppPayload), Blob.valueOf( whatsAppSecret ));
        
        String encodedPayload = 'sha256='+EncodingUtil.convertToHex(signedPayload);
        // Return status code based on whether signed payload matches or not
        
        String response = (encodedPayload == whatsAppSignature)? SIGNATURE_VALID_MESSAGE : SIGNATURE_NOT_VALID_MESSAGE;
        return response;
        // Validate Stripe signature End 
    }
}