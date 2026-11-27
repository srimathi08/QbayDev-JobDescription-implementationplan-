/**
 * @class WhatsAppWebhook
 * @desc
 *   Handles inbound webhook requests from WhatsApp Business API via Meta/Facebook Webhooks.
 *   Follows the shared intake pipeline used by Email and UI Upload:
 *     WhatsAppWebhook (authorize @quadrobay.com user + save Service__c)
 *       -> WhatsApp_Intake_Event__e (switch from Site Guest User to licensed internal user)
 *       -> IntakeRouter (identify Resume vs JD)
 *       -> IntakeProcessor (create Candidate or JD/Opportunity records)
 *
 *   - GET: verification challenge using System.Label.WHATSAPP_VERIFY_TOKEN
 *   - POST: validates HMAC SHA-256 signature, checks active internal @quadrobay.com User
 *     by phone number (when Restrict_WhatsApp_To_Internal__c is enabled), deduplicates by
 *     message ID (Request_Key__c), downloads supported documents (PDF/DOCX) before DML,
 *     converts long text messages to PDF, populates File_Checksum__c, and publishes
 *     WhatsApp_Intake_Event__e.
 *   - Trigger helper onServiceAfterUpdate(): sends final WhatsApp summary once processing finishes.
 *
 * @urlMapping /whatsapp/webhooks/v1/*
 */
@RestResource(urlMapping='/whatsapp/webhooks/v1/*')
global without sharing class WhatsAppWebhook {

    public static final String CHANNEL = 'WhatsApp';
    private static final String SIGNATURE_VALID_MESSAGE     = 'Signature Verified';
    private static final String SIGNATURE_NOT_VALID_MESSAGE = 'Signature could not be verified';
    private static final String DEFAULT_INTERNAL_DOMAIN     = 'quadrobay.com';

    private class InboundItem {
        Service__c service;
        String fileName;
        Blob fileData;
        String mediaId;
        Boolean shouldRoute;
        String replyTo;
        String replyMessage;
    }

    private class ReplyNotice {
        String toPhone;
        String body;
        ReplyNotice(String toPhone, String body) {
            this.toPhone = toPhone;
            this.body = body;
        }
    }

    private class CollectResult {
        List<InboundItem> items = new List<InboundItem>();
        List<ReplyNotice> unauthorizedReplies = new List<ReplyNotice>();
    }

    @HttpGet
    global static void doGet() {
        RestResponse response = RestContext.response;
        RestRequest request = RestContext.request;
        String verifyToken = String.isNotBlank(System.Label.WHATSAPP_VERIFY_TOKEN)
            ? System.Label.WHATSAPP_VERIFY_TOKEN.trim()
            : 'WHATSAPPTOKEN';

        if (request.params.get('hub.verify_token') == verifyToken) {
            String challenge = request.params.get('hub.challenge');
            response.statusCode = 200;
            response.responseBody = Blob.valueOf(challenge != null ? challenge : '');
        } else {
            response.statusCode = 403;
        }
    }

    @HttpPost
    global static void doPost() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        String responseString = RestContext.request.requestBody != null
            ? RestContext.request.requestBody.toString()
            : '';
        if (validateWhatsAppSignature(RestContext.request) != SIGNATURE_VALID_MESSAGE) {
            response.statusCode = 401;
            response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'success' => false,
                'event'   => 'Unknown',
                'message' => SIGNATURE_NOT_VALID_MESSAGE
            }));
            return;
        }

        try {
            IntakeRouter.Settings cfg = IntakeRouter.getSettings();
            CollectResult collected = collectInboundItems(responseString, cfg);

            for (ReplyNotice deny : collected.unauthorizedReplies) {
                sendWhatsAppSafe(deny.body, deny.toPhone);
            }

            List<InboundItem> items = collected.items;
            if (items.isEmpty()) {
                respondSuccess(response);
                return;
            }

            List<Service__c> services = new List<Service__c>();
            for (InboundItem it : items) {
                services.add(it.service);
            }
            insert services;

            List<ContentVersion> versions = new List<ContentVersion>();
            Map<Integer, Integer> versionIndexByItem = new Map<Integer, Integer>();
            for (Integer i = 0; i < items.size(); i++) {
                InboundItem it = items[i];
                if (it.fileData == null) continue;
                versionIndexByItem.put(i, versions.size());
                String title = it.fileName.contains('.')
                    ? it.fileName.substringBeforeLast('.').left(255)
                    : it.fileName.left(255);
                versions.add(new ContentVersion(
                    Title                  = title,
                    PathOnClient           = it.fileName,
                    VersionData            = it.fileData,
                    FirstPublishLocationId = services[i].Id
                ));
            }
            if (!versions.isEmpty()) {
                insert versions;
                Map<Id, ContentVersion> saved = new Map<Id, ContentVersion>([
                    SELECT Id, Checksum FROM ContentVersion WHERE Id IN :versions
                ]);
                List<Service__c> checksumUpdates = new List<Service__c>();
                for (Integer i : versionIndexByItem.keySet()) {
                    Id cvId = versions[versionIndexByItem.get(i)].Id;
                    checksumUpdates.add(new Service__c(
                        Id = services[i].Id,
                        File_Checksum__c = saved.get(cvId).Checksum
                    ));
                }
                if (!checksumUpdates.isEmpty()) update checksumUpdates;
            }

            List<WhatsApp_Intake_Event__e> events = new List<WhatsApp_Intake_Event__e>();
            if (cfg.enabled) {
                for (Integer i = 0; i < items.size(); i++) {
                    if (items[i].shouldRoute) {
                        events.add(new WhatsApp_Intake_Event__e(
                            Service_Id__c = String.valueOf(services[i].Id),
                            Media_Id__c   = items[i].mediaId,
                            File_Name__c  = items[i].fileName != null ? items[i].fileName.left(255) : null
                        ));
                    }
                }
            }
            if (!events.isEmpty()) {
                List<Database.SaveResult> pubResults = EventBus.publish(events);
                for (Database.SaveResult sr : pubResults) {
                    if (!sr.isSuccess()) {
                        String errMsg = sr.getErrors().isEmpty() ? 'Unknown Platform Event error' : sr.getErrors()[0].getMessage();
                        UtilityClass.createElog(new DmlException(errMsg), 'WhatsAppWebhook', 'publishEvent');
                    }
                }
            }

            for (InboundItem it : items) {
                sendWhatsAppSafe(it.replyMessage, it.replyTo);
            }

            respondSuccess(response);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'WhatsAppWebhook', 'doPost');
            response.statusCode = 500;
            response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'success' => false,
                'event'   => 'error',
                'message' => e.getMessage()
            }));
        }
    }

    // =====================================================================
    // Inbound parsing, internal @quadrobay.com lookup & pre-DML download
    // =====================================================================

    private static CollectResult collectInboundItems(String responseString, IntakeRouter.Settings cfg) {
        CollectResult out = new CollectResult();
        if (String.isBlank(responseString)) return out;

        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseString);
        List<Object> entries = (List<Object>) root.get('entry');
        if (entries == null || entries.isEmpty()) return out;

        List<Map<String, Object>> rawMessages = new List<Map<String, Object>>();
        List<String> rawReplyTos = new List<String>();
        List<String> rawKeys = new List<String>();
        Set<String> keysToCheck = new Set<String>();
        Set<String> phoneDigitsSet = new Set<String>();

        for (Object eObj : entries) {
            Map<String, Object> entryMap = (Map<String, Object>) eObj;
            List<Object> changes = (List<Object>) entryMap.get('changes');
            if (changes == null) continue;

            for (Object cObj : changes) {
                Map<String, Object> changeMap = (Map<String, Object>) cObj;
                Map<String, Object> valueMap = (Map<String, Object>) changeMap.get('value');
                if (valueMap == null) continue;

                List<Object> messageList = (List<Object>) valueMap.get('messages');
                if (messageList == null || messageList.isEmpty()) continue;

                List<Object> contactList = (List<Object>) valueMap.get('contacts');
                Map<String, Object> firstContact = (contactList != null && !contactList.isEmpty())
                    ? (Map<String, Object>) contactList.get(0)
                    : null;
                String waId = firstContact != null ? (String) firstContact.get('wa_id') : null;

                for (Object mObj : messageList) {
                    Map<String, Object> msgMap = (Map<String, Object>) mObj;
                    String fromPhone = firstNonBlank((String) msgMap.get('from'), (String) msgMap.get('from_x'));
                    String replyTo = firstNonBlank(fromPhone, waId);
                    String msgId = (String) msgMap.get('id');
                    String reqKey = String.isNotBlank(msgId)
                        ? ('W' + parseEmail.sha256(msgId)).left(64)
                        : null;
                    if (reqKey != null) keysToCheck.add(reqKey);

                    String digits = AiJson.digitsOnly(replyTo);
                    if (digits != null) phoneDigitsSet.add(digits);

                    rawMessages.add(msgMap);
                    rawReplyTos.add(replyTo);
                    rawKeys.add(reqKey);
                }
            }
        }

        if (rawMessages.isEmpty()) return out;

        Set<String> existingKeys = new Set<String>();
        if (!keysToCheck.isEmpty()) {
            for (Service__c existing : [
                SELECT Request_Key__c FROM Service__c WHERE Request_Key__c IN :keysToCheck
            ]) {
                existingKeys.add(existing.Request_Key__c);
            }
        }

        Map<String, User> internalUsersByDigits = findInternalUsersByPhone(phoneDigitsSet, cfg);
        Set<String> seenInBatch = new Set<String>();
        Set<String> deniedPhonesNotified = new Set<String>();

        for (Integer i = 0; i < rawMessages.size(); i++) {
            String reqKey = rawKeys[i];
            if (reqKey != null && (existingKeys.contains(reqKey) || seenInBatch.contains(reqKey))) {
                continue;
            }
            if (reqKey != null) seenInBatch.add(reqKey);

            String replyTo = rawReplyTos[i];
            String digits = AiJson.digitsOnly(replyTo);
            User matchedUser = digits != null ? internalUsersByDigits.get(digits) : null;

            if (cfg.restrictWhatsAppToInternal && matchedUser == null) {
                if (String.isNotBlank(replyTo) && !deniedPhonesNotified.contains(replyTo)) {
                    deniedPhonesNotified.add(replyTo);
                    out.unauthorizedReplies.add(new ReplyNotice(
                        replyTo,
                        'Access restricted: your phone number is not registered to an active @quadrobay.com Salesforce user. '
                        + 'Please ask your Salesforce admin to add your WhatsApp number to your User record.'
                    ));
                }
                continue;
            }

            InboundItem item = buildInboundItem(rawMessages[i], replyTo, reqKey, matchedUser, cfg);
            if (item != null) out.items.add(item);
        }

        return out;
    }

    /**
     * Finds active Salesforce Users whose Email domain is in Acknowledgement_Domains__c
     * (defaulting to quadrobay.com) and whose Phone or MobilePhone matches the last 10 digits.
     */
    @TestVisible
    private static Map<String, User> findInternalUsersByPhone(Set<String> targetDigits, IntakeRouter.Settings cfg) {
        Map<String, User> byDigits = new Map<String, User>();
        if (targetDigits == null || targetDigits.isEmpty()) return byDigits;

        Set<String> allowedDomains = new Set<String>();
        if (cfg != null && cfg.acknowledgementDomains != null && !cfg.acknowledgementDomains.isEmpty()) {
            allowedDomains.addAll(cfg.acknowledgementDomains);
        } else {
            allowedDomains.add(DEFAULT_INTERNAL_DOMAIN);
        }

        for (User u : [
            SELECT Id, Email, Phone, MobilePhone
            FROM User
            WHERE IsActive = true
              AND Email != null
              AND (Phone != null OR MobilePhone != null)
            LIMIT 2000
        ]) {
            String domain = u.Email.contains('@')
                ? u.Email.substringAfterLast('@').trim().toLowerCase()
                : '';
            if (!allowedDomains.contains(domain)) continue;

            String pDigits = AiJson.digitsOnly(u.Phone);
            String mDigits = AiJson.digitsOnly(u.MobilePhone);
            if (pDigits != null && targetDigits.contains(pDigits) && !byDigits.containsKey(pDigits)) {
                byDigits.put(pDigits, u);
            }
            if (mDigits != null && targetDigits.contains(mDigits) && !byDigits.containsKey(mDigits)) {
                byDigits.put(mDigits, u);
            }
        }
        return byDigits;
    }

    private static InboundItem buildInboundItem(
        Map<String, Object> msgMap,
        String replyTo,
        String reqKey,
        User matchedUser,
        IntakeRouter.Settings cfg
    ) {
        Map<String, Object> textMap  = (Map<String, Object>) msgMap.get('text');
        Map<String, Object> imageMap = (Map<String, Object>) msgMap.get('image');
        Map<String, Object> docMap   = (Map<String, Object>) msgMap.get('document');

        String bodyText = textMap != null ? (String) textMap.get('body') : null;
        if (String.isBlank(bodyText) && imageMap != null) {
            bodyText = (String) imageMap.get('caption');
        }
        if (String.isBlank(bodyText) && docMap != null) {
            bodyText = (String) docMap.get('caption');
        }

        InboundItem item = new InboundItem();
        item.replyTo = replyTo;
        item.shouldRoute = false;

        Service__c serv = new Service__c(
            Source_Channel__c = CHANNEL,
            Whatsapp__c       = false,
            Request_Key__c    = reqKey,
            Retry_Count__c    = 0,
            whatsappfrom__c   = String.isNotBlank(replyTo) ? replyTo.left(20) : null,
            Email_Body__c     = bodyText != null ? bodyText.left(131000) : ''
        );
        if (matchedUser != null) {
            serv.OwnerId = matchedUser.Id;
            serv.emailfrom__c = matchedUser.Email != null ? matchedUser.Email.left(80) : null;
        }

        String senderLabel = String.isNotBlank(replyTo) ? replyTo : 'unknown sender';

        if (docMap != null && String.isNotBlank((String) docMap.get('id'))) {
            String mime = (String) docMap.get('mime_type');
            String docFilename = (String) docMap.get('filename');
            String ext = parseEmail.extensionOf(docFilename, mime);
            String displayName = String.isNotBlank(docFilename)
                ? docFilename.trim()
                : ('WhatsAppDocument' + (ext == '' ? '' : '.' + ext));
            if (!displayName.contains('.') && ext != '') displayName += '.' + ext;

            if (cfg.allowedExtensions.contains(ext)) {
                // Hand off media download to async Queueable (12 MB limit) via WhatsApp_Intake_Event__e
                item.mediaId = (String) docMap.get('id');
                item.fileName = displayName;
                item.shouldRoute = true;
                serv.Name = displayName.left(80);
                serv.Status__c = IntakeRouter.STATUS_NEW;
                serv.Status_Message__c = ('Received by WhatsApp from ' + senderLabel
                    + '. Waiting to download and identify whether it is a resume or a job description.').left(32000);
                item.replyMessage = 'Thank you! We have received your document (' + displayName
                    + ') and queued it for processing.';
            } else {
                String rejectMsg = ext == 'doc'
                    ? '"' + displayName + '" is in the old Word format (.doc), which cannot be read. '
                      + 'Please save it as PDF or DOCX and send it again. Nothing was created.'
                    : '"' + displayName + '" is not a supported file type. Please send resumes and '
                      + 'job descriptions as ' + String.join(new List<String>(cfg.allowedExtensions), ' or ').toUpperCase()
                      + '. Nothing was created.';
                serv.Name = displayName.left(80);
                serv.Status__c = 'Rejected';
                serv.Detected_Type__c = 'Other';
                serv.Acknowledged__c = true;
                serv.Status_Message__c = rejectMsg.left(32000);
                item.replyMessage = buildFinalSummary(serv, null);
            }
        } else if (imageMap != null && String.isNotBlank((String) imageMap.get('id'))) {
            String rejectMsg = 'Images are not supported. Please send resumes and job descriptions as '
                + String.join(new List<String>(cfg.allowedExtensions), ' or ').toUpperCase()
                + '. Nothing was created.';
            serv.Name = firstNonBlank(replyTo, 'WhatsApp Image').left(80);
            serv.Status__c = 'Rejected';
            serv.Detected_Type__c = 'Other';
            serv.Acknowledged__c = true;
            serv.Status_Message__c = rejectMsg;
            item.replyMessage = buildFinalSummary(serv, null);
        } else {
            String trimmed = bodyText == null ? '' : bodyText.trim();
            if (trimmed.length() >= cfg.minBodyLength) {
                String baseName = 'WhatsApp - ' + senderLabel;
                Blob pdf = parseEmail.bodyAsPdf(baseName, trimmed);
                item.fileData = pdf != null ? pdf : Blob.valueOf(trimmed);
                item.fileName = pdf != null ? 'WhatsAppMessage.pdf' : 'WhatsAppMessage.txt';
                item.shouldRoute = true;
                serv.Name = item.fileName.left(80);
                serv.Status__c = IntakeRouter.STATUS_NEW;
                serv.Status_Message__c = ('Received by WhatsApp from ' + senderLabel
                    + '. Waiting to identify whether it is a resume or a job description.').left(32000);
                item.replyMessage = 'Thank you! We have received your message and queued it for processing.';
            } else {
                String rejectMsg = 'No resume or job description was found: the message has no PDF or DOCX '
                    + 'attachment and its text is too short to be a job description or a resume. '
                    + 'Please send a PDF/DOCX file or paste the full text (at least ' + cfg.minBodyLength
                    + ' characters). Nothing was created.';
                serv.Name = firstNonBlank(replyTo, 'WhatsApp Message').left(80);
                serv.Status__c = 'Rejected';
                serv.Detected_Type__c = 'Other';
                serv.Acknowledged__c = true;
                serv.Status_Message__c = rejectMsg.left(32000);
                item.replyMessage = buildFinalSummary(serv, null);
            }
        }

        item.service = serv;
        return item;
    }

    // =====================================================================
    // Final WhatsApp summary notification (called from ServiceIntakeTrigger)
    // =====================================================================

    /**
     * Trigger entry: notifies the WhatsApp sender once processing finishes
     * (Completed, Duplicate, Rejected, or permanently Failed after retries). Never throws.
     */
    public static void onServiceAfterUpdate(List<Service__c> newList, Map<Id, Service__c> oldMap) {
        try {
            if (newList == null || newList.isEmpty()) return;
            IntakeRouter.Settings cfg = IntakeRouter.getSettings();
            Set<Id> notifyIds = new Set<Id>();

            for (Service__c s : newList) {
                if (s.Source_Channel__c != CHANNEL || s.Acknowledged__c == true
                        || String.isBlank(s.whatsappfrom__c)) {
                    continue;
                }
                Service__c old = oldMap == null ? null : oldMap.get(s.Id);
                Boolean becameFinal = IntakeRouter.FINAL_STATUSES.contains(s.Status__c)
                    && (old == null || old.Status__c != s.Status__c);
                if (!becameFinal) continue;

                // Wait to notify on Failed until automatic retries are exhausted
                Decimal tries = s.Retry_Count__c == null ? 0 : s.Retry_Count__c;
                if (s.Status__c == 'Failed' && cfg.retryChannels.contains(CHANNEL) && tries < cfg.maxRetries) {
                    continue;
                }
                notifyIds.add(s.Id);
            }

            if (notifyIds.isEmpty()) return;

            List<Service__c> toMark = new List<Service__c>();
            String baseUrl = System.Url.getOrgDomainUrl().toExternalForm();

            for (Service__c s : [
                SELECT Id, Name, Status__c, Status_Message__c, Detected_Type__c, whatsappfrom__c,
                       Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name,
                       Job_Description__c, Job_Description__r.Name
                FROM Service__c
                WHERE Id IN :notifyIds
            ]) {
                toMark.add(new Service__c(Id = s.Id, Acknowledged__c = true));
                sendWhatsAppSafe(buildFinalSummary(s, baseUrl), s.whatsappfrom__c);
            }

            if (!toMark.isEmpty()) Database.update(toMark, false);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'WhatsAppWebhook', 'onServiceAfterUpdate');
        }
    }

    @TestVisible
    private static String forWhatsAppSender(String message) {
        if (message == null) return null;
        return message
            .replaceAll('\\s*Please upload it as an? [A-Za-z ]+, or choose Auto-detect\\.', '')
            .replace('upload again', 'send it again')
            .replace('upload the file again', 'send the file again')
            .replace('Please try again.', 'It will be checked by the team.');
    }

    @TestVisible
    private static String buildFinalSummary(Service__c s, String baseUrl) {
        String tag = (s.Status__c == 'Completed')
            ? '[OK]'
            : (s.Status__c == 'Duplicate' ? '[ALREADY EXISTS]' : '[NOT CREATED]');

        List<String> lines = new List<String>{
            'Your WhatsApp submission has been processed in Salesforce.',
            '',
            tag + ' ' + s.Name
        };

        if (String.isNotBlank(s.Status_Message__c)) {
            lines.add('    ' + forWhatsAppSender(s.Status_Message__c).left(500));
        }
        if (s.Account__c != null && s.Detected_Type__c == IntakeController.TYPE_RESUME) {
            lines.add('    Candidate: ' + s.Account__r.Name + ' - ' + baseUrl + '/' + s.Account__c);
        }
        if (s.Opportunity__c != null) {
            lines.add('    Opportunity: ' + s.Opportunity__r.Name + ' - ' + baseUrl + '/' + s.Opportunity__c);
        }
        lines.add('');
        lines.add('This is an automated message from Salesforce. Please do not reply.');
        return String.join(lines, '\n');
    }

    // =====================================================================
    // Helpers & signature validation
    // =====================================================================

    private static void sendWhatsAppSafe(String message, String toPhone) {
        if (String.isBlank(message) || String.isBlank(toPhone)) return;
        if (System.isFuture() || System.isBatch() || Limits.getFutureCalls() >= Limits.getLimitFutureCalls()) {
            return;
        }
        WhatsAppUtils.sendTextMessage(message, toPhone);
    }

    private static void respondSuccess(RestResponse response) {
        response.statusCode = 200;
        response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => true,
            'event'   => 'success'
        }));
    }

    private static String firstNonBlank(String a, String b) {
        return String.isNotBlank(a) ? a : (String.isNotBlank(b) ? b : null);
    }

    private static String getHeaderIgnoreCase(Map<String, String> headers, String targetKey) {
        if (headers == null || String.isBlank(targetKey)) return null;
        if (headers.containsKey(targetKey)) return headers.get(targetKey);
        for (String key : headers.keySet()) {
            if (key != null && key.equalsIgnoreCase(targetKey)) {
                return headers.get(key);
            }
        }
        return null;
    }

    private static String validateWhatsAppSignature(RestRequest request) {
        if (request == null || request.requestBody == null) {
            return SIGNATURE_NOT_VALID_MESSAGE;
        }
        String whatsAppSignature = getHeaderIgnoreCase(request.headers, 'X-Hub-Signature-256');
        String whatsAppSecret = System.Label.WHATSAPPSECRET;
        if (String.isBlank(whatsAppSignature) || String.isBlank(whatsAppSecret)) {
            return SIGNATURE_NOT_VALID_MESSAGE;
        }

        Blob signedPayload = Crypto.generateMac('hmacSHA256', request.requestBody, Blob.valueOf(whatsAppSecret.trim()));
        String encodedPayload = 'sha256=' + EncodingUtil.convertToHex(signedPayload);
        return encodedPayload.equalsIgnoreCase(whatsAppSignature.trim())
            ? SIGNATURE_VALID_MESSAGE
            : SIGNATURE_NOT_VALID_MESSAGE;
    }
}