/**
 * Inbound Email Service handler (Email Service "Service") for Candidate Matching email ingestion.
 *
 * Keeps the handler thin and safe: it only saves the email as intake records (one Service__c per
 * document, with its file) and returns. Identifying resume vs JD and creating candidates /
 * opportunities happens asynchronously in the shared pipeline:
 *   parseEmail (save) -> IntakeRouter (identify) -> IntakeProcessor (create)
 *
 * - Each usable attachment (PDF / DOCX by default) becomes its own Service__c with its file.
 * - Files inside forwarded emails (.eml attached to the email) are read as well.
 * - Signature logos, inline images, calendar invites and similar noise are ignored.
 * - Unsupported files (.doc, .msg, .xlsx, large images, oversize files ...) get a Rejected Service__c that says why.
 * - The same file attached twice in one email is processed once.
 * - An email with no usable attachment but a long text (JD or resume pasted in the mail)
 *   is turned into a PDF of the text and processed like an attachment.
 * - An email WITH attachments and a long text: the text is also checked, but only as a job description.
 * - The files of one email are processed one after another (no parallel duplicates).
 * - The same email delivered twice (same Message-Id) is ignored the second time.
 * - Optional acknowledgement email to internal senders (OFF by default) and optional failure alert.
 *
 * Email only: nothing here changes how WhatsApp or Qbay Home uploads work.
 * extensionOf() and bodyAsPdf() are also used by WhatsAppWebhook and keep their behaviour.
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
            // The technical error stays inside Salesforce (Error_Log__c); the sender only gets a reference
            String ref = errorReference();
            UtilityClass.createElog(e, 'parseEmail', 'handleInboundEmail [ref ' + ref + ']');
            // success = false makes Salesforce reply to the sender with this message
            result.success = false;
            result.message = 'Your email could not be saved in Salesforce, so nothing was processed. '
                + 'Please send it again. If it fails again, contact the Salesforce support team and quote reference ' + ref + '.';
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

    /** Name prefix of the record made from the email text when the email also has files (checked as a JD only). */
    public static final String BODY_WITH_FILES_PREFIX = 'Email text - ';
    /** Upload_Batch__c prefix for email records: the files of one email are processed one after another. */
    public static final String BATCH_PREFIX = 'EM-';

    private static final Set<String> IMAGE_EXTENSIONS = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'webp', 'heic', 'emz', 'wmz' };
    private static final Set<String> NOISE_EXTENSIONS = new Set<String>{ 'p7s', 'p7m', 'vcf', 'ics', 'htm', 'html', 'txt', 'css', 'xml' };
    /** Common document types: when the file name ends in one of these, the name decides the type. */
    private static final Set<String> DOCUMENT_EXTENSIONS = new Set<String>{
        'pdf', 'docx', 'doc', 'rtf', 'odt', 'pages', 'xlsx', 'xls', 'csv', 'pptx', 'ppt', 'zip', 'rar', '7z', 'msg', 'eml'
    };
    private static final Integer MAX_EMAIL_FIELD = 80;
    /** Images at least this big that are not inline are treated as a scanned document (rejected with a message), not as a logo. */
    @TestVisible private static Integer scannedImageMinBytes = 150 * 1024;
    /** Forwarded emails (.eml) larger than this are not opened (heap safety); the sender is asked to attach the files directly. */
    @TestVisible private static Integer forwardedEmailMaxBytes = 6 * 1024 * 1024;
    private static final Integer MAX_FORWARD_DEPTH = 3;
    private static final Integer MAX_MIME_DEPTH = 12;

    public class Outcome {
        public Boolean duplicateEmail = false;
        public List<Id> queued = new List<Id>();
        public List<Id> rejected = new List<Id>();
        public List<String> ignored = new List<String>();
    }

    /** One document taken from the email (an attachment, a file inside a forwarded email, or the text). */
    private class Item {
        String fileName;
        Blob data;
        String rejectReason;
        String checksum;        // set for the email text, whose PDF bytes change on every conversion
        String requestedType;   // 'Job Description' for the text of an email that also has files
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

        // ---------- 1. Pick the documents (attachments and files inside forwarded emails) ----------
        Collector c = new Collector(cfg, out);
        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment att : email.binaryAttachments) {
                c.addFile(att.fileName, att.mimeTypeSubType, att.body, isInlineImage(att), 0);
            }
        }
        if (email.textAttachments != null) {
            for (Messaging.InboundEmail.TextAttachment att : email.textAttachments) {
                c.addText(att.fileName, att.mimeTypeSubType, att.body, 0);
            }
        }
        List<Item> items = c.items;

        // ---------- 2. The email text (own text + text of forwarded emails) ----------
        String text = documentText(body, c.forwardedTexts);
        String title = safeFileName(('Email - ' + (String.isBlank(subject) ? 'no subject' : subject.trim())).left(70));
        if (c.usable == 0) {
            // No usable file: the text itself may be the JD / resume
            if (text.length() >= cfg.minBodyLength) {
                items.add(textItem(title, subject, text, null));
            } else if (items.isEmpty()) {
                items.add(new Item(String.isBlank(subject) ? 'Email with no attachment' : subject, null,
                    'No resume or job description was found: the email has no PDF or DOCX attachment and its text is too short '
                    + 'to be a job description or a resume.'
                    + (out.ignored.isEmpty() ? '' : ' Ignored attachments: ' + String.join(out.ignored, ', ').left(1000) + '.')
                    + ' Nothing was created.'));
            }
        } else if (cfg.minBodyLengthWithFiles > 0 && text.length() >= cfg.minBodyLengthWithFiles
                && c.usable < cfg.maxFilesPerEmail) {
            // Files attached AND a long text: the text may be a JD (for the attached resumes). Checked as a JD only.
            String withFilesTitle = safeFileName((BODY_WITH_FILES_PREFIX + (String.isBlank(subject) ? 'no subject' : subject.trim())).left(70));
            items.add(textItem(withFilesTitle, subject, text, IntakeController.TYPE_JD));
        }

        // ---------- 3. Save one Service__c per document, with its file ----------
        List<Service__c> services = new List<Service__c>();
        String safeFrom = validEmailOrNull(fromAddress);
        String batch = (BATCH_PREFIX + emailKey).left(64);
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
                Upload_Batch__c = batch,
                Retry_Count__c = 0,
                Requested_Type__c = rejected ? null : it.requestedType,
                Status__c = rejected ? STATUS_REJECTED : STATUS_NEW,
                Detected_Type__c = rejected ? 'Other' : null,
                Status_Message__c = rejected ? it.rejectReason
                    : ('Received by email from ' + (fromAddress == null ? 'unknown sender' : fromAddress)
                        + (it.requestedType == null ? '. Waiting to identify whether it is a resume or a job description.'
                            : '. The email text will be checked for a job description.'))
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
                services[i].File_Checksum__c = items[i].checksum != null
                    ? items[i].checksum
                    : saved.get(versions[versionIndexByItem.get(i)].Id).Checksum;
            }
            update services;
        }

        // ---------- 4. Start processing (asynchronous, one file after another) ----------
        for (Service__c s : services) {
            if (s.Status__c == STATUS_REJECTED) {
                out.rejected.add(s.Id);
                continue;
            }
            out.queued.add(s.Id);
        }
        if (cfg.enabled && !out.queued.isEmpty()) IntakeRouter.startEmailChain(out.queued[0]);

        // Nothing to process (every file rejected): the acknowledgement can go now
        if (out.queued.isEmpty() && cfg.sendAcknowledgement) {
            try {
                notifyGroups(new Set<String>{ emailKey });
            } catch (Exception e) {
                UtilityClass.createElog(e, 'parseEmail', 'acknowledgeRejected');
            }
        }
        return out;
    }

    private static Item textItem(String title, String subject, String text, String requestedType) {
        Blob pdf = bodyAsPdf(subject, text);
        Item it = pdf != null
            ? new Item(title + '.pdf', pdf, null)
            : new Item(title + '.txt', Blob.valueOf(text), null);
        // Same text sent again = same checksum, so the duplicate check works for text emails too
        it.checksum = textChecksum(text);
        it.requestedType = requestedType;
        return it;
    }

    /** The email's own text, followed by the text of any forwarded emails. */
    private static String documentText(String body, List<String> forwardedTexts) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(body)) parts.add(body.trim());
        for (String t : forwardedTexts) {
            if (String.isNotBlank(t)) parts.add(t.trim());
        }
        return String.join(parts, '\n\n---------- Forwarded message ----------\n\n');
    }

    // =====================================================================
    // Collecting files (attachments and files inside forwarded emails)
    // =====================================================================

    private class Collector {
        IntakeRouter.Settings cfg;
        Outcome out;
        List<Item> items = new List<Item>();
        Integer usable = 0;
        Set<String> seenFiles = new Set<String>();
        List<String> forwardedTexts = new List<String>();

        Collector(IntakeRouter.Settings cfg, Outcome out) {
            this.cfg = cfg;
            this.out = out;
        }

        void addFile(String rawName, String mime, Blob data, Boolean inline, Integer forwardDepth) {
            String name = String.isBlank(rawName) ? 'attachment' : rawName.trim();
            String ext = emailFileType(name, mime);
            if (data == null || data.size() == 0) {
                out.ignored.add(name + ' (empty)');
                return;
            }
            if (ext == 'eml' || isEmailMime(mime)) {
                addForwardedEmail(name, data, forwardDepth);
                return;
            }
            if (inline || NOISE_EXTENSIONS.contains(ext)) {
                out.ignored.add(name);
                return;
            }
            // The same file attached twice in one email is processed once
            // (two copies would otherwise both create records)
            String fileHash = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', data));
            if (seenFiles.contains(fileHash)) {
                out.ignored.add(name + ' (same file attached twice)');
                return;
            }
            seenFiles.add(fileHash);
            // "CV - J.Smith" sent as a PDF is saved as "CV - J.Smith.pdf" so the file type is kept
            if (ext != '' && !name.toLowerCase().endsWith('.' + ext)) name = name + '.' + ext;

            if (IMAGE_EXTENSIONS.contains(ext)) {
                // small images are logos / signatures; a big one is usually a photographed or scanned document
                if (data.size() < scannedImageMinBytes) {
                    out.ignored.add(name);
                } else {
                    items.add(new Item(name, data, '"' + name + '" is an image. Images (for example a photo or scan of a resume) '
                        + 'cannot be read. Please send the resume or job description as a PDF or DOCX file. Nothing was created.'));
                }
                return;
            }
            Long limitBytes = cfg.maxEmailFileMb == null || cfg.maxEmailFileMb <= 0 ? null : cfg.maxEmailFileMb * 1048576L;
            if (limitBytes != null && data.size() > limitBytes) {
                items.add(new Item(name, null, '"' + name + '" is larger than ' + cfg.maxEmailFileMb + ' MB and was not processed. '
                    + 'Please send a smaller file (for example a PDF without scanned pages). Nothing was created.'));
                return;
            }
            if (cfg.allowedExtensions.contains(ext)) {
                if (usable >= cfg.maxFilesPerEmail) {
                    items.add(new Item(name, data, '"' + name + '" was not processed: an email can carry at most '
                        + cfg.maxFilesPerEmail + ' files. Please send the remaining files in another email.'));
                } else {
                    items.add(new Item(name, data, null));
                    usable++;
                }
            } else if (ext == 'doc') {
                items.add(new Item(name, data, '"' + name + '" is in the old Word format (.doc), which cannot be read. '
                    + 'Please save it as PDF or DOCX and send it again. Nothing was created.'));
            } else if (ext == 'msg') {
                items.add(new Item(name, data, '"' + name + '" is an Outlook item (.msg), which cannot be read. '
                    + 'Please forward the email normally, or attach the resume or job description files directly. Nothing was created.'));
            } else {
                items.add(new Item(name, data, '"' + name + '" is not a supported file type. Please send resumes and '
                    + 'job descriptions as ' + String.join(new List<String>(cfg.allowedExtensions), ' or ').toUpperCase()
                    + '. Nothing was created.'));
            }
        }

        void addText(String rawName, String mime, String content, Integer forwardDepth) {
            String name = String.isBlank(rawName) ? 'text attachment' : rawName.trim();
            if (isEmailMime(mime) || name.toLowerCase().endsWith('.eml')) {
                if (String.isBlank(content)) {
                    out.ignored.add(name + ' (empty)');
                } else {
                    addForwardedEmail(name, Blob.valueOf(content), forwardDepth);
                }
                return;
            }
            out.ignored.add(name);
        }

        /** A forwarded email attached to this email: its files and its text are used as if they were in this email. */
        void addForwardedEmail(String name, Blob data, Integer forwardDepth) {
            if (forwardDepth >= MAX_FORWARD_DEPTH) {
                out.ignored.add(name + ' (forwarded too many times)');
                return;
            }
            if (data.size() > forwardedEmailMaxBytes) {
                items.add(new Item(name, null, 'The forwarded email "' + name + '" is too large to open here. '
                    + 'Please attach the resume or job description files directly. Nothing was created.'));
                return;
            }
            MimePart root;
            try {
                root = parseMime(data.toString(), 0);
            } catch (Exception e) {
                UtilityClass.createElog(e, 'parseEmail', 'parseForwardedEmail');
                items.add(new Item(name, data, 'The forwarded email "' + name + '" could not be read. '
                    + 'Please attach the resume or job description files directly. Nothing was created.'));
                return;
            }
            List<String> plain = new List<String>();
            List<String> html = new List<String>();
            walk(root, forwardDepth + 1, plain, html);
            forwardedTexts.addAll(plain.isEmpty() ? html : plain);
        }

        private void walk(MimePart p, Integer forwardDepth, List<String> plain, List<String> html) {
            if (p.contentType.startsWith('multipart/')) {
                for (MimePart child : p.children) walk(child, forwardDepth, plain, html);
                return;
            }
            String fileName = p.fileName();
            Boolean isAttachment = fileName != null || p.disposition.startsWith('attachment');
            if (p.contentType == 'message/rfc822') {
                // a forwarded email inside the forwarded email
                addForwardedEmail(fileName == null ? 'forwarded email.eml' : fileName, Blob.valueOf(p.body), forwardDepth);
                return;
            }
            if (!isAttachment && p.contentType == 'text/plain') {
                plain.add(p.decodedText());
                return;
            }
            if (!isAttachment && p.contentType == 'text/html') {
                html.add(htmlToText(p.decodedText()));
                return;
            }
            if (!isAttachment) return;
            Boolean inline = p.contentType.startsWith('image/') && (p.disposition.startsWith('inline') || p.header('content-id') != null);
            addFile(fileName == null ? 'attachment' : fileName, p.contentType, p.decodedBlob(), inline, forwardDepth);
        }
    }

    private static Boolean isEmailMime(String mime) {
        return mime != null && mime.toLowerCase().startsWith('message/rfc822');
    }

    // =====================================================================
    // Minimal MIME reader for forwarded emails (.eml)
    // =====================================================================

    @TestVisible
    private class MimePart {
        public Map<String, String> headers = new Map<String, String>();
        public String contentType = 'text/plain';
        public String disposition = '';
        public String body = '';
        public List<MimePart> children = new List<MimePart>();

        public String header(String name) {
            return headers.get(name);
        }

        /** File name from Content-Disposition (filename / filename*) or Content-Type (name). Null when none. */
        public String fileName() {
            String n = headerParam(header('content-disposition'), 'filename');
            if (String.isBlank(n)) n = headerParam(header('content-type'), 'name');
            return String.isBlank(n) ? null : decodeWords(n).trim();
        }

        public Blob decodedBlob() {
            String cte = header('content-transfer-encoding') == null ? '' : header('content-transfer-encoding').toLowerCase().trim();
            if (cte == 'base64') return EncodingUtil.base64Decode(body.replaceAll('[^A-Za-z0-9+/=]', ''));
            if (cte == 'quoted-printable') return Blob.valueOf(decodeQuotedPrintable(body, 'UTF-8'));
            return Blob.valueOf(body);
        }

        public String decodedText() {
            String cte = header('content-transfer-encoding') == null ? '' : header('content-transfer-encoding').toLowerCase().trim();
            String charset = headerParam(header('content-type'), 'charset');
            try {
                if (cte == 'base64') return EncodingUtil.base64Decode(body.replaceAll('[^A-Za-z0-9+/=]', '')).toString();
                if (cte == 'quoted-printable') return decodeQuotedPrintable(body, String.isBlank(charset) ? 'UTF-8' : charset);
            } catch (Exception e) {
                return body;
            }
            return body;
        }
    }

    @TestVisible
    private static MimePart parseMime(String raw, Integer depth) {
        if (depth > MAX_MIME_DEPTH) throw new IntakeException('The forwarded email is nested too deeply.');
        String text = raw == null ? '' : raw.replace('\r\n', '\n');
        Integer sep = text.indexOf('\n\n');
        String headerBlock = sep < 0 ? text : text.substring(0, sep);
        MimePart p = new MimePart();
        p.body = sep < 0 ? '' : text.substring(sep + 2);
        text = null;

        for (String line : headerBlock.replaceAll('\n[ \t]+', ' ').split('\n')) {
            Integer colon = line.indexOf(':');
            if (colon <= 0) continue;
            p.headers.put(line.substring(0, colon).trim().toLowerCase(), line.substring(colon + 1).trim());
        }
        String ct = p.header('content-type');
        if (String.isNotBlank(ct)) p.contentType = ct.substringBefore(';').trim().toLowerCase();
        String cd = p.header('content-disposition');
        if (String.isNotBlank(cd)) p.disposition = cd.trim().toLowerCase();

        if (p.contentType.startsWith('multipart/')) {
            String boundary = headerParam(ct, 'boundary');
            if (String.isBlank(boundary)) return p;
            String delim = '--' + boundary;
            String b = p.body;
            p.body = '';
            Integer pos = b.indexOf(delim);
            while (pos >= 0) {
                Integer start = pos + delim.length();
                if (b.substring(start, Math.min(start + 2, b.length())) == '--') break; // closing delimiter
                Integer next = b.indexOf('\n' + delim, start);
                String segment = next < 0 ? b.substring(start) : b.substring(start, next);
                Integer lineEnd = segment.indexOf('\n');
                segment = lineEnd < 0 ? '' : segment.substring(lineEnd + 1);
                p.children.add(parseMime(segment, depth + 1));
                if (next < 0) break;
                pos = next + 1;
            }
        }
        // message/rfc822 parts keep the raw inner message in body; the collector opens it as a forwarded email
        return p;
    }

    /** Value of one parameter of a MIME header, e.g. filename="CV.pdf", filename*=UTF-8''CV%20A.pdf, boundary=xyz. */
    @TestVisible
    private static String headerParam(String headerValue, String param) {
        if (String.isBlank(headerValue)) return null;
        // RFC 2231 form: param*=charset''percent-encoded
        Matcher ext = Pattern.compile('(?i)(?:^|;)\\s*' + param + '\\*=\\s*"?([^;"]*)"?').matcher(headerValue);
        if (ext.find()) {
            String v = ext.group(1);
            Integer q = v.indexOf('\'\'');
            String charset = q > 0 ? v.substring(0, q) : 'UTF-8';
            String encoded = q >= 0 ? v.substring(q + 2) : v;
            try {
                return EncodingUtil.urlDecode(encoded.replace('+', '%2B'), String.isBlank(charset) ? 'UTF-8' : charset);
            } catch (Exception e) {
                return encoded;
            }
        }
        Matcher quoted = Pattern.compile('(?i)(?:^|;)\\s*' + param + '\\s*=\\s*"([^"]*)"').matcher(headerValue);
        if (quoted.find()) return quoted.group(1);
        Matcher plain = Pattern.compile('(?i)(?:^|;)\\s*' + param + '\\s*=\\s*([^;\\s]+)').matcher(headerValue);
        if (plain.find()) return plain.group(1);
        return null;
    }

    /** Decodes RFC 2047 encoded words in a header value, e.g. =?UTF-8?B?UmVzdW1lLnBkZg==?= */
    @TestVisible
    private static String decodeWords(String value) {
        if (value == null || !value.contains('=?')) return value;
        Matcher m = Pattern.compile('=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=').matcher(value);
        String result = '';
        Integer last = 0;
        while (m.find()) {
            result += value.substring(last, m.start()).replaceAll('^\\s+$', '');
            String decoded;
            try {
                decoded = m.group(2).equalsIgnoreCase('B')
                    ? EncodingUtil.base64Decode(m.group(3)).toString()
                    : decodeQuotedPrintable(m.group(3).replace('_', ' '), m.group(1));
            } catch (Exception e) {
                decoded = m.group(0);
            }
            result += decoded;
            last = m.end();
        }
        return result + value.substring(last);
    }

    @TestVisible
    private static String decodeQuotedPrintable(String s, String charset) {
        if (String.isBlank(s)) return s;
        String v = s.replace('=\r\n', '').replace('=\n', '');
        try {
            String pct = v.replace('%', '%25').replace('+', '%2B').replaceAll('=([0-9A-Fa-f]{2})', '%$1');
            return EncodingUtil.urlDecode(pct, String.isBlank(charset) ? 'UTF-8' : charset);
        } catch (Exception e) {
            return v;
        }
    }

    // ---------------- helpers ----------------

    @TestVisible
    private static String bodyOf(Messaging.InboundEmail email) {
        if (String.isNotBlank(email.plainTextBody)) return email.plainTextBody;
        if (String.isNotBlank(email.htmlBody)) return htmlToText(email.htmlBody);
        return null;
    }

    /** Plain text from HTML. Never throws: very large HTML falls back to a simpler conversion. */
    @TestVisible
    private static String htmlToText(String htmlBody) {
        if (String.isBlank(htmlBody)) return htmlBody;
        String h;
        try {
            h = htmlBody
                .replaceAll('(?is)<(script|style)[^>]*>.*?</\\1>', ' ')
                .replaceAll('(?i)<br\\s*/?>', '\n')
                .replaceAll('(?i)</(p|div|li|tr|h[1-6])>', '\n')
                .replaceAll('<[^>]+>', ' ');
        } catch (Exception e) {
            try {
                h = htmlBody.replaceAll('<[^>]{0,2000}>', ' ');
            } catch (Exception e2) {
                return htmlBody.stripHtmlTags();
            }
        }
        try {
            h = h.unescapeHtml4().replaceAll('[ \\t\\x0B\\f\\r]+', ' ').replaceAll('\\n\\s*\\n+', '\n\n');
        } catch (Exception e) {
            h = h.unescapeHtml4();
        }
        return h.trim();
    }

    /**
     * Key that identifies one email. Uses the Message-Id; when an email has none, a key built from the
     * sender, subject, Date header and content (the same email delivered twice gets the same key).
     */
    private static String emailKeyOf(Messaging.InboundEmail email, String fromAddress, String subject, String body) {
        if (String.isNotBlank(email.messageId)) return sha256(email.messageId.trim());
        String dateHeader = '';
        if (email.headers != null) {
            for (Messaging.InboundEmail.Header h : email.headers) {
                if (h.name != null && h.name.equalsIgnoreCase('Date')) dateHeader = h.value;
            }
        }
        List<String> files = new List<String>();
        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment a : email.binaryAttachments) {
                files.add(a.fileName + ':' + (a.body == null ? 0 : a.body.size()));
            }
        }
        return sha256(fromAddress + '|' + subject + '|' + dateHeader + '|' + (body == null ? '' : body.left(5000))
            + '|' + String.join(files, ','));
    }

    public static String sha256(String s) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(s == null ? '' : s)));
    }

    /** Shared with WhatsAppWebhook: behaviour unchanged. Email uses emailFileType(). */
    public static String extensionOf(String fileName, String mimeType) {
        if (String.isNotBlank(fileName) && fileName.contains('.')) {
            String e = fileName.substringAfterLast('.').toLowerCase().trim();
            if (e.length() > 0 && e.length() <= 5) return e;
        }
        return extensionFromMime(mimeType);
    }

    /**
     * Email only: file type from the file name, or from the MIME type when the name has no real extension.
     * "CV - J.Smith" sent as application/pdf is 'pdf' (not 'smith').
     */
    @TestVisible
    private static String emailFileType(String fileName, String mimeType) {
        String fromName = '';
        if (String.isNotBlank(fileName) && fileName.contains('.')) {
            String e = fileName.substringAfterLast('.').toLowerCase().trim();
            if (e.length() > 0 && e.length() <= 5) fromName = e;
        }
        String fromMime = extensionFromMime(mimeType);
        if (fromName != '' && (fromMime == '' || isKnownExtension(fromName))) return fromName;
        if (fromMime != '') return fromMime;
        return fromName;
    }

    private static String extensionFromMime(String mimeType) {
        String m = mimeType == null ? '' : mimeType.toLowerCase();
        if (m.contains('pdf')) return 'pdf';
        if (m.contains('wordprocessingml')) return 'docx';
        if (m.contains('msword')) return 'doc';
        if (m.startsWith('image/')) return m.substringAfter('image/').substringBefore(';');
        return '';
    }

    private static Boolean isKnownExtension(String ext) {
        return DOCUMENT_EXTENSIONS.contains(ext) || IMAGE_EXTENSIONS.contains(ext) || NOISE_EXTENSIONS.contains(ext);
    }

    /** Checksum of a text document (email text): ignores spacing and letter case, so a re-sent text matches. */
    public static String textChecksum(String text) {
        String normalized = text == null ? '' : text.normalizeSpace().toLowerCase();
        return EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(normalized)));
    }

    /** Short reference given to the sender when the email could not be saved; the same reference is in Error_Log__c. */
    @TestVisible
    private static String errorReference() {
        return 'EM-' + Datetime.now().formatGmt('yyMMdd-HHmmss') + '-'
            + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(4).toUpperCase();
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

    /** Shared with WhatsAppWebhook: behaviour unchanged. */
    public static Blob bodyAsPdf(String subject, String text) {
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
    @TestVisible private static Integer alertSentCount = 0;

    // =====================================================================
    // Acknowledgement email (OFF by default) and failure alert (OFF until an address is set)
    // One summary per email to the sender, when every file of that email is final.
    // Only for senders in Intake_Setting__mdt.Default.Acknowledgement_Domains__c.
    // Called from ServiceIntakeTrigger, from receive() and from the hourly IntakeRouter job. Never throws.
    // =====================================================================

    /**
     * True when the record will not change any more. A Failed email record that the hourly job will
     * still retry is not final yet, so the sender is not told "not created" before the retry.
     */
    @TestVisible
    private static Boolean isFinal(Service__c s, IntakeRouter.Settings cfg) {
        if (!FINAL_STATUSES.contains(s.Status__c)) return false;
        if (s.Status__c != 'Failed') return true;
        Boolean retried = cfg.retryChannels.contains(s.Source_Channel__c);
        Decimal tries = s.Retry_Count__c == null ? 0 : s.Retry_Count__c;
        Boolean tooOld = s.CreatedDate != null && s.CreatedDate < Datetime.now().addDays(-IntakeRouter.LOOKBACK_DAYS);
        return !retried || tries >= cfg.maxRetries || tooOld;
    }

    /** Trigger entry: email records that just reached a final status. */
    public static void onServiceAfterUpdate(List<Service__c> newList, Map<Id, Service__c> oldMap) {
        try {
            IntakeRouter.Settings cfg = IntakeRouter.getSettings();
            Set<String> keys = new Set<String>();
            List<Service__c> failed = new List<Service__c>();
            for (Service__c s : newList) {
                if (s.Source_Channel__c != CHANNEL) continue;
                Service__c old = oldMap == null ? null : oldMap.get(s.Id);
                Boolean changed = old == null || old.Status__c != s.Status__c;
                if (!changed || !isFinal(s, cfg)) continue;
                if (cfg.sendAcknowledgement && s.Acknowledged__c != true && String.isNotBlank(s.Email_Message_Key__c)) {
                    keys.add(s.Email_Message_Key__c);
                }
                if (s.Status__c == 'Failed') failed.add(s);
            }
            if (!keys.isEmpty()) notifyGroups(keys);
            if (!failed.isEmpty()) sendFailureAlert(failed, cfg);
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
                   Email_Message_Key__c, Acknowledged__c, CreatedDate, Source_Channel__c, Retry_Count__c,
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
        Id fromAddressId = orgWideAddressId(cfg.acknowledgementFromAddress);

        for (String key : byKey.keySet()) {
            List<Service__c> grp = byKey.get(key);
            Boolean allFinal = true;
            Boolean alreadySent = false;
            for (Service__c s : grp) {
                if (!isFinal(s, cfg)) allFinal = false;
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
            if (fromAddressId != null) m.setOrgWideEmailAddressId(fromAddressId);
            mails.add(m);
        }

        if (!mark.isEmpty()) Database.update(mark, false);
        sendAll(mails, 'sendAcknowledgement');
        if (Test.isRunningTest()) ackSentCount += mails.size();
    }

    /** One alert to the team when email records finally failed (after all automatic retries). */
    private static void sendFailureAlert(List<Service__c> failed, IntakeRouter.Settings cfg) {
        if (cfg.failureAlertEmails == null || cfg.failureAlertEmails.isEmpty()) return;
        String base = System.Url.getOrgDomainUrl().toExternalForm();
        List<String> lines = new List<String>{
            'These email intake records could not be processed, even after the automatic retries.',
            'Please open each record, check the message, and re-send or process the file manually.',
            ''
        };
        for (Service__c s : failed) {
            lines.add('- ' + s.Name + ' (from ' + (s.EmailFrom__c == null ? 'unknown sender' : s.EmailFrom__c) + ')');
            if (String.isNotBlank(s.Status_Message__c)) lines.add('    ' + s.Status_Message__c.left(500));
            lines.add('    ' + base + '/' + s.Id);
        }
        lines.add('');
        lines.add('This is an automated message from Salesforce.');
        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setToAddresses(cfg.failureAlertEmails);
        m.setSubject('Email intake: ' + failed.size() + ' file(s) could not be processed');
        m.setPlainTextBody(String.join(lines, '\n'));
        m.setSaveAsActivity(false);
        m.setUseSignature(false);
        Id fromAddressId = orgWideAddressId(cfg.acknowledgementFromAddress);
        if (fromAddressId != null) m.setOrgWideEmailAddressId(fromAddressId);
        sendAll(new List<Messaging.SingleEmailMessage>{ m }, 'sendFailureAlert');
        if (Test.isRunningTest()) alertSentCount++;
    }

    private static void sendAll(List<Messaging.SingleEmailMessage> mails, String method) {
        if (mails.isEmpty() || Test.isRunningTest()) return;
        try {
            Messaging.sendEmail(mails, false);
        } catch (Exception e) {
            UtilityClass.createElog(e, 'parseEmail', method);
        }
    }

    private static Id orgWideAddressId(String address) {
        if (String.isBlank(address)) return null;
        List<OrgWideEmailAddress> found = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :address.trim() LIMIT 1];
        return found.isEmpty() ? null : found[0].Id;
    }

    /** True for the "email text" record of an email with files that turned out not to be a JD (not worth reporting). */
    private static Boolean isUnusedEmailText(Service__c s) {
        return s.Name != null && s.Name.startsWith(BODY_WITH_FILES_PREFIX)
            && s.Status__c == STATUS_REJECTED && s.Detected_Type__c == 'Other';
    }

    /** Status messages are shared with Qbay Home uploads; reword upload-screen instructions for an email sender. */
    @TestVisible
    private static String forEmailSender(String message) {
        if (message == null) return null;
        return message
            .replaceAll('\\s*Please upload it as an? [A-Za-z ]+, or choose Auto-detect\\.', '')
            .replace('upload again', 'send it again')
            .replace('upload the file again', 'send the file again')
            .replace('Please try again.', 'It will be checked by the team.');
    }

    @TestVisible
    private static String acknowledgementSummary(List<Service__c> grp, String base) {
        List<String> lines = new List<String>();
        lines.add('Your email "' + (String.isBlank(grp[0].Email_Subject__c) ? '(no subject)' : grp[0].Email_Subject__c)
            + '" has been processed in Salesforce.');
        lines.add('');
        for (Service__c s : grp) {
            if (isUnusedEmailText(s)) continue;
            String icon = (s.Status__c == 'Completed') ? '[OK]' : (s.Status__c == 'Duplicate' ? '[ALREADY EXISTS]' : '[NOT CREATED]');
            lines.add(icon + ' ' + s.Name);
            if (String.isNotBlank(s.Status_Message__c)) lines.add('    ' + forEmailSender(s.Status_Message__c).left(500));
            if (s.Account__c != null && s.Detected_Type__c == 'Resume') lines.add('    Candidate: ' + s.Account__r.Name + ' - ' + base + '/' + s.Account__c);
            if (s.Opportunity__c != null) lines.add('    Opportunity: ' + s.Opportunity__r.Name + ' - ' + base + '/' + s.Opportunity__c);
            lines.add('    Intake record: ' + base + '/' + s.Id);
            lines.add('');
        }
        lines.add('This is an automated message from Salesforce. Please do not reply.');
        return String.join(lines, '\n');
    }
}