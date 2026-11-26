/**
 * @class WhatsAppUtils
 * @desc 
 *   Utility class for integrating with the WhatsApp Business Cloud API (Meta/Facebook).
 *   Handles:
 *   - Sending WhatsApp text messages via HTTP POST
 *   - Downloading media (images or documents) using media ID from webhook payload
 * 
 *   Requires:
 *   - WhatsApp permanent access token stored in `System.Label.WhatsAppToken`
 *   - WhatsApp phone number ID stored in `System.Label.WHATSAPP_PHONE_ID`
 * 
 * @author Afrose Ahamed @updated Sathish
 */
public without sharing class WhatsAppUtils {

    private static String resolveAccessToken() {
        String token = System.Label.WhatsAppToken;
        if (String.isBlank(token)) {
            token = System.Label.WHATSAPPACCESSTOKEN;
        }
        return token != null ? token.trim() : null;
    }

    @future(callout=true)
    public static void sendTextMessage(String messageContent, String toPhone){
        if (String.isBlank(messageContent) || String.isBlank(toPhone)) {
            return;
        }

        String token = resolveAccessToken();
        String phoneId = System.Label.WHATSAPP_PHONE_ID != null ? System.Label.WHATSAPP_PHONE_ID.trim() : null;

        // Auto-fallback to Phone Number ID if the custom label contains the WABA Account ID (1013077571894313)
        if (String.isBlank(phoneId) || phoneId.equals('1013077571894313')) {
            phoneId = '105666505595426';
        }

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndPoint('https://graph.facebook.com/v20.0/' + phoneId + '/messages');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('Authorization', 'Bearer ' + token);
        
        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'recipient_type' => 'individual',
            'to' => toPhone.trim(),
            'type' => 'text',
            'text' => new Map<String, Object>{
                'preview_url' => false,
                'body' => messageContent
            }
        };

        String json = JSON.serialize(payload);
        httpReq.setBody(json);

        Http http = new Http();
        try {
            HttpResponse response = http.send(httpReq);
            System.debug('Whats sent request response: ' + response.getStatusCode() + ' ' + response.getBody());
            if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
                UtilityClass.createElog(
                    new CalloutException('WhatsApp send failed (' + response.getStatusCode() + '): ' + response.getBody()),
                    'WhatsAppUtils',
                    'sendTextMessage'
                );
            }
        } catch(System.CalloutException ex){
            System.debug('CalloutException: ' + ex.getMessage());
            UtilityClass.createElog(ex, 'WhatsAppUtils', 'sendTextMessage');
        } catch(Exception e){
            System.debug('Exception: ' + e.getMessage());
            UtilityClass.createElog(e, 'WhatsAppUtils', 'sendTextMessage');
        }
    }
    
    public static Blob getMedia(String mediaId){
        System.debug('mediaid: ' + mediaId);
        String token = resolveAccessToken();

        Http httpObj = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint('https://graph.facebook.com/v20.0/' + mediaId);
        request.setMethod('GET');
        request.setHeader('Authorization', 'Bearer ' + token);
        HttpResponse response = httpObj.send(request);
        System.debug(response.getBody());

        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            throw new CalloutException('Failed to fetch WhatsApp media metadata (' + response.getStatusCode() + '): ' + response.getBody());
        }

        Map<String, Object> result = (Map<String, Object>)JSON.deserializeUntyped(response.getBody());
        String downloadUrl = result != null ? (String)result.get('url') : null;        
        System.debug('Download Url: ' + downloadUrl);        
        if (String.isBlank(downloadUrl)) {
            throw new CalloutException('WhatsApp media metadata missing download url: ' + response.getBody());
        }

        Http http = new Http();
        HttpRequest requestmedia = new HttpRequest();
        requestmedia.setEndpoint(downloadUrl);
        requestmedia.setMethod('GET');
        requestmedia.setHeader('Authorization', 'Bearer ' + token);
        HttpResponse responsemedia = http.send(requestmedia);
        System.debug('Download Image Response: ' + responsemedia);
        if (responsemedia.getStatusCode() < 200 || responsemedia.getStatusCode() >= 300) {
            throw new CalloutException('Failed to download WhatsApp media (' + responsemedia.getStatusCode() + '): ' + responsemedia.getBody());
        }

        return responsemedia.getBodyAsBlob();
    } 
}