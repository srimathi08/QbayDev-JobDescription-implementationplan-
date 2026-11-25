/**
 * Inbound Email Service handler (Email Service "Service") for Candidate Matching email ingestion.
 *
 * Keeps the handler thin and safe: it only saves the email as intake records (one Service__c per
 * document, with its file) and returns. Identifying resume vs JD and creating candidates /
 * opportunities happens asynchronously in the shared pipeline:
 *   parseEmail (save) -> IntakeRouter (identify) -> IntakeProcessor (create)
 *
 * - Each usable attachment (PDF / DOCX by default) becomes its own Service__c with its file.
 * - Signature logos, inline images, calendar invites and similar noise are ignored.
 * - Unsupported files (.doc, .xlsx, .zip ...) get a Rejected Service__c that says why.
 * - An email with no attachment but a long body (JD or resume pasted in the mail)
 *   is turned into a PDF of the body and processed like an attachment.
 * - The same email delivered twice (same Message-Id) is ignored the second time.
 * - Optional acknowledgement email to internal senders (OFF by default).
 */
global without sharing class parseEmail implements Messaging.InboundEmailHandler {

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        Savepoint sp = Database.setSavepoint();
        try {
            receive(email, envelope);
            result.success = true;
            result.message = 'Email processed successfully';
        } catch (Exception e) {
            // all or nothing: no half-saved email records
            Database.rollback(sp);
            UtilityClass.createElog(e, 'parseEmail', 'handleInboundEmail');
            // success = false makes Salesforce reply to the sender with this message
            result.success = false;
            result.message = 'Your email could not be saved in Salesforce, so nothing was processed. '
                + 'Please send it again, or contact the Salesforce support team. Error: ' + e.getMessage();
        }
        return result;
    }

    // =====================================================================
    // Saving the email as intake records
    // =====================================================================

    public static final String CHANNEL = 'Email';
    public static final String STATUS_NEW = IntakeRouter.STATUS_NEW;
    public static final String STATUS_REJECTED = 'Rejected';
    public static final Set<String> FINAL_STATUSES = IntakeRouter.FINAL_STATUSES;

    private static final Set<String> IMAGE_EXTENSIONS = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'webp', 'heic', 'emz', 'wmz' };
    private static final Set<String> NOISE_EXTENSIONS = new Set<String>{ 'p7s', 'p7m', 'vcf', 'ics', 'eml', 'htm', 'html', 'txt', 'css', 'xml' };
    private static final Integer MAX_EMAIL_FIELD = 80;

    public class Outcome {
        public Boolean duplicateEmail = false;
        public List<Id> queued = new List<Id>();
        public List<Id> rejected = new List<Id>();
        public List<String> ignored = new List<String>();
    }

    /** One document taken from the email (an attachment or the body). */
    private class Item {
        String fileName;
        Blob data;
        String rejectReason;
        Item(String fileName, Blob data, String rejectReason) {
            this.fileName = fileName;
            this.data = data;
            this.rejectReason = rejectReason;
        }
    }

    public class IntakeException extends Exception {}
    @TestVisible private static Boolean forceErrorInTest = false;

    public static Outcome receive(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        if (Test.isRunningTest() && forceErrorInTest) throw new IntakeException('Forced test error');
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        Outcome out = new Outcome();

        String fromAddress = String.isNotBlank(email.fromAddress) ? email.fromAddress
            : (envelope != null ? envelope.fromAddress : null);
        String subject = email.subject;
        String body = bodyOf(email);
        String emailKey = emailKeyOf(email, fromAddress, subject, body);

        // Same email delivered again (mail server retry): already handled
        if ([SELECT COUNT() FROM Service__c WHERE Email_Message_Key__c = :emailKey] > 0) {
            out.duplicateEmail = true;
            return out;
        }

        // ---------- 1. Pick the documents ----------
        List<Item> items = new List<Item>();
        Integer usable = 0;
        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment att : email.binaryAttachments) {
                String name = String.isBlank(att.fileName) ? 'attachment' : att.fileName.trim();
                String ext = extensionOf(name, att.mimeTypeSubType);
                if (att.body == null || att.body.size() == 0) {
                    out.ignored.add(name + ' (empty)');
                    continue;
                }
                if (IMAGE_EXTENSIONS.contains(ext) || NOISE_EXTENSIONS.contains(ext) || isInlineImage(att)) {
                    out.ignored.add(name);
                    continue;
                }
                if (!name.contains('.') && ext != '') name = name + '.' + ext;
                if (cfg.allowedExtensions.contains(ext)) {
                    if (usable >= cfg.maxFilesPerEmail) {
                        items.add(new Item(name, att.body, '"' + name + '" was not processed: an email can carry at most '
                            + cfg.maxFilesPerEmail + ' files. Please send the remaining files in another email.'));
                    } else {
                        items.add(new Item(name, att.body, null));
                        usable++;
                    }
                } else if (ext == 'doc') {
                    items.add(new Item(name, att.body, '"' + name + '" is in the old Word format (.doc), which cannot be read. '
                        + 'Please save it as PDF or DOCX and send it again. Nothing was created.'));
                } else {
                    items.add(new Item(name, att.body, '"' + name + '" is not a supported file type. Please send resumes and '
                        + 'job descriptions as ' + String.join(new List<String>(cfg.allowedExtensions), ' or ').toUpperCase()
                        + '. Nothing was created.'));
                }
            }
        }
        if (email.textAttachments != null) {
            for (Messaging.InboundEmail.TextAttachment att : email.textAttachments) {
                out.ignored.add(String.isBlank(att.fileName) ? 'text attachment' : att.fileName);
            }
        }

        // ---------- 2. No attachment at all: the email text itself may be the JD / resume ----------
        if (items.isEmpty()) {
            String text = body == null ? '' : body.trim();
            if (text.length() >= cfg.minBodyLength) {
                String title = safeFileName(('Email - ' + (String.isBlank(subject) ? 'no subject' : subject.trim())).left(70));
                Blob pdf = bodyAsPdf(subject, text);
                items.add(pdf != null
                    ? new Item(title + '.pdf', pdf, null)
                    : new Item(title + '.txt', Blob.valueOf(text), null));
            } else {
                items.add(new Item(String.isBlank(subject) ? 'Email with no attachment' : subject, null,
                    'No resume or job description was found: the email has no PDF or DOCX attachment and its text is too short '
                    + 'to be a job description or a resume.'
                    + (out.ignored.isEmpty() ? '' : ' Ignored attachments: ' + String.join(out.ignored, ', ').left(1000) + '.')
                    + ' Nothing was created.'));
            }
        }

        // ---------- 3. Save one Service__c per document, with its file ----------
        List<Service__c> services = new List<Service__c>();
        String safeFrom = validEmailOrNull(fromAddress);
        for (Integer i = 0; i < items.size(); i++) {
            Item it = items[i];
            Boolean rejected = it.rejectReason != null;
            services.add(new Service__c(
                Name = it.fileName.left(80),
                Source_Channel__c = CHANNEL,
                EmailFrom__c = safeFrom,
                Email_Subject__c = subject == null ? null : subject.left(32000),
                Email_Body__c = body == null ? null : body.left(131000),
                Email_Message_Key__c = emailKey,
                Request_Key__c = ('E' + sha256(emailKey + '|' + i)).left(64),
                Retry_Count__c = 0,
                Status__c = rejected ? STATUS_REJECTED : STATUS_NEW,
                Detected_Type__c = rejected ? 'Other' : null,
                Status_Message__c = rejected ? it.rejectReason
                    : ('Received by email from ' + (fromAddress == null ? 'unknown sender' : fromAddress)
                        + '. Waiting to identify whether it is a resume or a job description.')
            ));
        }
        insert services;

        List<ContentVersion> versions = new List<ContentVersion>();
        Map<Integer, Integer> versionIndexByItem = new Map<Integer, Integer>();
        for (Integer i = 0; i < items.size(); i++) {
            if (items[i].data == null) continue;
            versionIndexByItem.put(i, versions.size());
            versions.add(new ContentVersion(
                Title = items[i].fileName.contains('.') ? items[i].fileName.substringBeforeLast('.').left(255) : items[i].fileName.left(255),
                PathOnClient = items[i].fileName,
                VersionData = items[i].data,
                FirstPublishLocationId = services[i].Id
            ));
        }
        if (!versions.isEmpty()) {
            insert versions;
            Map<Id, ContentVersion> saved = new Map<Id, ContentVersion>([
                SELECT Id, Checksum FROM ContentVersion WHERE Id IN :versions
            ]);
            for (Integer i : versionIndexByItem.keySet()) {
                services[i].File_Checksum__c = saved.get(versions[versionIndexByItem.get(i)].Id).Checksum;
            }
            update services;
        }

        // ---------- 4. Start processing (asynchronous) ----------
        for (Service__c s : services) {
            if (s.Status__c == STATUS_REJECTED) {
                out.rejected.add(s.Id);
                continue;
            }
            out.queued.add(s.Id);
        }
        if (cfg.enabled) IntakeRouter.start(out.queued);
        return out;
    }

    // ---------------- helpers ----------------

    @TestVisible
    private static String bodyOf(Messaging.InboundEmail email) {
        if (String.isNotBlank(email.plainTextBody)) return email.plainTextBody;
        if (String.isNotBlank(email.htmlBody)) {
            String h = email.htmlBody
                .replaceAll('(?is)<(script|style)[^>]*>.*?</\\1>', ' ')
                .replaceAll('(?i)<br\\s*/?>', '\n')
                .replaceAll('(?i)</(p|div|li|tr|h[1-6])>', '\n')
                .replaceAll('<[^>]+>', ' ');
            h = h.unescapeHtml4().replaceAll('[ \\t\\x0B\\f\\r]+', ' ').replaceAll('\\n\\s*\\n+', '\n\n');
            return h.trim();
        }
        return null;
    }

    private static String emailKeyOf(Messaging.InboundEmail email, String fromAddress, String subject, String body) {
        String seed = String.isNotBlank(email.messageId)
            ? email.messageId.trim()
            : (fromAddress + '|' + subject + '|' + (body == null ? '' : body.left(2000)) + '|' + Crypto.getRandomLong());
        return sha256(seed);
    }

    public static String sha256(String s) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(s == null ? '' : s)));
    }

    @TestVisible
    private static String extensionOf(String fileName, String mimeType) {
        if (String.isNotBlank(fileName) && fileName.contains('.')) {
            String e = fileName.substringAfterLast('.').toLowerCase().trim();
            if (e.length() > 0 && e.length() <= 5) return e;
        }
        String m = mimeType == null ? '' : mimeType.toLowerCase();
        if (m.contains('pdf')) return 'pdf';
        if (m.contains('wordprocessingml')) return 'docx';
        if (m.contains('msword')) return 'doc';
        if (m.startsWith('image/')) return m.substringAfter('image/').substringBefore(';');
        return '';
    }

    private static Boolean isInlineImage(Messaging.InboundEmail.BinaryAttachment att) {
        String m = att.mimeTypeSubType == null ? '' : att.mimeTypeSubType.toLowerCase();
        if (!m.startsWith('image/')) return false;
        if (att.headers == null) return false;
        for (Messaging.InboundEmail.Header h : att.headers) {
            if (h.name == null) continue;
            String n = h.name.toLowerCase();
            if (n == 'content-id') return true;
            if (n == 'content-disposition' && h.value != null && h.value.toLowerCase().startsWith('inline')) return true;
        }
        return false;
    }

    private static Blob bodyAsPdf(String subject, String text) {
        String html = '<html><body style="font-family:Arial,Helvetica,sans-serif;font-size:11pt;">'
            + (String.isBlank(subject) ? '' : '<h3>' + subject.escapeHtml4() + '</h3>')
            + '<div style="white-space:pre-wrap;">' + text.escapeHtml4().replace('\n', '<br/>') + '</div></body></html>';
        if (Test.isRunningTest() && !pdfInTests) return null;
        try {
            return Blob.toPdf(html);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'parseEmail', 'bodyAsPdf');
            return null;
        }
    }

    @TestVisible private static Boolean pdfInTests = false;

    private static String safeFileName(String s) {
        String v = s.replaceAll('[\\\\/:*?"<>|\\r\\n\\t]+', ' ').trim();
        return v == '' ? 'Email body' : v;
    }

    private static String validEmailOrNull(String address) {
        if (String.isBlank(address)) return null;
        String a = address.trim();
        if (a.length() > MAX_EMAIL_FIELD) return null;
        return Pattern.matches('^[A-Za-z0-9._%+\\-\']+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$', a) ? a : null;
    }



    @TestVisible private static Integer ackSentCount = 0;

    // =====================================================================
    // Optional acknowledgement email (OFF by default)
    // One summary per email to the sender, when every file of that email is final.
    // Only for senders in Intake_Setting__mdt.Default.Acknowledgement_Domains__c.
    // Called from ServiceIntakeTrigger and the hourly IntakeRouter job. Never throws.
    // =====================================================================

    /** Trigger entry: email records that just reached a final status. */
    public static void onServiceAfterUpdate(List<Service__c> newList, Map<Id, Service__c> oldMap) {
        try {
            IntakeRouter.Settings cfg = IntakeRouter.getSettings();
            if (!cfg.sendAcknowledgement) return;
            Set<String> keys = new Set<String>();
            for (Service__c s : newList) {
                if (s.Source_Channel__c != CHANNEL || s.Acknowledged__c == true
                    || String.isBlank(s.Email_Message_Key__c)) continue;
                Service__c old = oldMap == null ? null : oldMap.get(s.Id);
                Boolean becameFinal = FINAL_STATUSES.contains(s.Status__c)
                    && (old == null || old.Status__c != s.Status__c);
                if (becameFinal) keys.add(s.Email_Message_Key__c);
            }
            if (!keys.isEmpty()) notifyGroups(keys);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'parseEmail', 'onAfterUpdate');
        }
    }

    /** Catch-up from the hourly job: finished emails whose acknowledgement was not sent yet. */
    public static void sendPendingAcknowledgements(Datetime since) {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        if (!cfg.sendAcknowledgement) return;
        Set<String> keys = new Set<String>();
        for (Service__c s : [
            SELECT Email_Message_Key__c FROM Service__c
            WHERE Source_Channel__c = :CHANNEL AND Acknowledged__c = false
              AND Email_Message_Key__c != null AND CreatedDate >= :since
              AND Status__c IN :FINAL_STATUSES
            LIMIT 200
        ]) {
            keys.add(s.Email_Message_Key__c);
        }
        if (!keys.isEmpty()) notifyGroups(keys);
    }

    private static void notifyGroups(Set<String> keys) {
        IntakeRouter.Settings cfg = IntakeRouter.getSettings();
        Map<String, List<Service__c>> byKey = new Map<String, List<Service__c>>();
        for (Service__c s : [
            SELECT Id, Name, Status__c, Status_Message__c, Detected_Type__c, EmailFrom__c, Email_Subject__c,
                   Email_Message_Key__c, Acknowledged__c, CreatedDate,
                   Account__c, Account__r.Name, Opportunity__c, Opportunity__r.Name
            FROM Service__c
            WHERE Email_Message_Key__c IN :keys
            ORDER BY CreatedDate ASC, Name ASC
        ]) {
            if (!byKey.containsKey(s.Email_Message_Key__c)) byKey.put(s.Email_Message_Key__c, new List<Service__c>());
            byKey.get(s.Email_Message_Key__c).add(s);
        }

        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        List<Service__c> mark = new List<Service__c>();
        String base = System.Url.getOrgDomainUrl().toExternalForm();

        for (String key : byKey.keySet()) {
            List<Service__c> grp = byKey.get(key);
            Boolean allFinal = true;
            Boolean alreadySent = false;
            for (Service__c s : grp) {
                if (!FINAL_STATUSES.contains(s.Status__c)) allFinal = false;
                if (s.Acknowledged__c == true) alreadySent = true;
            }
            if (!allFinal || alreadySent) continue;

            for (Service__c s : grp) mark.add(new Service__c(Id = s.Id, Acknowledged__c = true));
            String to = grp[0].EmailFrom__c;
            if (!cfg.canAcknowledge(to)) continue;

            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(new List<String>{ to });
            m.setSubject(('Processed: ' + (String.isBlank(grp[0].Email_Subject__c) ? '(no subject)' : grp[0].Email_Subject__c)).left(250));
            m.setPlainTextBody(acknowledgementSummary(grp, base));
            m.setSaveAsActivity(false);
            m.setUseSignature(false);
            mails.add(m);
        }

        if (!mark.isEmpty()) Database.update(mark, false);
        if (!mails.isEmpty()) {
            if (Test.isRunningTest()) {
                ackSentCount += mails.size();
                return;
            }
            try {
                Messaging.sendEmail(mails, false);
            } catch (Exception e) {
                UtilityClass.createElog(e, 'parseEmail', 'sendEmail');
            }
        }
    }

    @TestVisible
    private static String acknowledgementSummary(List<Service__c> grp, String base) {
        List<String> lines = new List<String>();
        lines.add('Your email "' + (String.isBlank(grp[0].Email_Subject__c) ? '(no subject)' : grp[0].Email_Subject__c)
            + '" has been processed in Salesforce.');
        lines.add('');
        for (Service__c s : grp) {
            String icon = (s.Status__c == 'Completed') ? '[OK]' : (s.Status__c == 'Duplicate' ? '[ALREADY EXISTS]' : '[NOT CREATED]');
            lines.add(icon + ' ' + s.Name);
            if (String.isNotBlank(s.Status_Message__c)) lines.add('    ' + s.Status_Message__c.left(500));
            if (s.Account__c != null && s.Detected_Type__c == 'Resume') lines.add('    Candidate: ' + s.Account__r.Name + ' - ' + base + '/' + s.Account__c);
            if (s.Opportunity__c != null) lines.add('    Opportunity: ' + s.Opportunity__r.Name + ' - ' + base + '/' + s.Opportunity__c);
            lines.add('    Intake record: ' + base + '/' + s.Id);
            lines.add('');
        }
        lines.add('This is an automated message from Salesforce. Please do not reply.');
        return String.join(lines, '\n');
    }
}