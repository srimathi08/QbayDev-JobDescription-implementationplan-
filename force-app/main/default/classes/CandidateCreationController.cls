/**
 * Turns the Candidate_CreationFile AI JSON into candidate records:
 * Account (Candidates record type), Contact, resume file link, Certification__c,
 * Project_Experience__c and (async) Skill__c / Employee_Skill__c.
 *
 * Rules
 *  - A resume needs a name AND (email OR phone OR LinkedIn), otherwise nothing is created.
 *  - Matching order: email -> normalized phone -> LinkedIn -> name + date of birth,
 *    only against Candidates record type Accounts.
 *  - An existing candidate is never renamed and never overwritten with blanks:
 *    only empty fields are filled.
 *  - An email that belongs to a non-candidate Account (Employee, Contractor...) is not touched.
 */
public without sharing class CandidateCreationController {

    public class Result {
        public Id primaryAccountId;
        public List<Account> accounts = new List<Account>();
        public Integer created = 0;
        public Integer updated = 0;
        public List<String> skipped = new List<String>();
        public String summary;
    }

    private static Id candidateRtId {
        get {
            if (candidateRtId == null) {
                candidateRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Candidates').getRecordTypeId();
            }
            return candidateRtId;
        }
        set;
    }

    private static Id contactExternalRtId {
        get {
            if (contactExternalRtId == null) {
                Schema.RecordTypeInfo rti = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName().get('External');
                contactExternalRtId = rti == null ? null : rti.getRecordTypeId();
            }
            return contactExternalRtId;
        }
        set;
    }

    // =====================================================================
    // Legacy entry point (email path): no rejection, junk resumes are skipped
    // =====================================================================
    public static List<Account> createCandidates(String pdfText, String contentDocumentId) {
        return process(pdfText, contentDocumentId, null, false).accounts;
    }

    // =====================================================================
    // Main entry point
    // strict = true (UI upload): wrong document type / no usable data -> RejectException
    // =====================================================================
    public static Result process(String rawJson, String contentDocumentId, Id serviceId, Boolean strict) {
        Result res = new Result();
        Map<String, Object> parsed = AiJson.parse(rawJson);
        if (parsed == null) {
            if (strict) throw new IntakeProcessor.RejectException('The AI response could not be read for this file. Please check the file is a readable PDF or DOCX resume.');
            res.summary = 'Unreadable AI response';
            return res;
        }

        String docType = AiJson.documentType(rawJson);
        if (strict && docType == 'Job Description') {
            throw new IntakeProcessor.RejectException('This file looks like a Job Description, not a resume. Please upload it as a Job Description, or choose Auto-detect. Nothing was created.');
        }
        if (strict && docType == 'Other') {
            throw new IntakeProcessor.RejectException('This file does not look like a resume. Nothing was created.');
        }

        List<Map<String, Object>> resumes = AiJson.objList(parsed, 'resumes');
        if (resumes.isEmpty() && parsed.containsKey('account')) resumes.add(parsed);

        String fileTitle = fileTitleOf(contentDocumentId);

        // ---------- 1. Build candidate views, apply the minimum-data rule ----------
        List<Candidate> cands = new List<Candidate>();
        List<Candidate> nameOnly = new List<Candidate>();
        for (Map<String, Object> r : resumes) {
            Candidate c = new Candidate(r, fileTitle);
            if (!c.hasMinimumData()) {
                if (String.isNotBlank(c.name)) nameOnly.add(c);
                res.skipped.add(String.isBlank(c.name) ? 'a resume with no name' : c.name);
                continue;
            }
            cands.add(c);
        }
        if (cands.isEmpty()) {
            if (strict) {
                if (resumes.size() == 1 && nameOnly.size() == 1) {
                    // The file has a name but no contact details: the person may already exist,
                    // so report the duplicate instead of the missing-data message.
                    String name = nameOnly[0].name;
                    List<Account> same = existingCandidatesByName(name);
                    if (!same.isEmpty()) throw duplicateByName(name, same);
                    IntakeProcessor.NeedsReviewException nr = new IntakeProcessor.NeedsReviewException(missingContactMessage(name));
                    nr.candidateName = name;
                    throw nr;
                }
                throw new IntakeProcessor.RejectException('Could not find the candidate\'s name and an email, phone number or LinkedIn profile in this file. Nothing was created.');
            }
            res.summary = 'No candidate with enough data';
            return res;
        }

        // ---------- 2. Load possible matches ----------
        Set<String> emails = new Set<String>();
        Set<String> phones = new Set<String>();
        Set<String> names = new Set<String>();
        for (Candidate c : cands) {
            if (c.email != null) emails.add(c.email);
            if (c.phoneKey != null) phones.add(c.phoneKey);
            if (c.name != null) names.add(c.name);
        }

        Map<String, Account> candByEmail = new Map<String, Account>();
        // A phone number can be on more than one candidate (shared or sample numbers), so keep all of them
        Map<String, List<Account>> candByPhone = new Map<String, List<Account>>();
        Map<String, Account> candByLinkedIn = new Map<String, Account>();
        Map<String, Account> candByNameDob = new Map<String, Account>();
        Map<String, Account> otherByEmail = new Map<String, Account>();

        for (Account a : [
            SELECT Id, Name, RecordTypeId, RecordType.Name, Phone, Phone_Normalized__c, Personal_Email__c,
                   Description, Designation__c, Years_of_Experience__c, Experience_Years__c,
                   Languages_Known__c, Current_Location__c, Current_Organization__c, Past_Companies__c,
                   College_Name__c, FileName__c, Degree__c, Date_of_Birth__c, LinkedIn__c,
                   (SELECT Id FROM Contacts WHERE Candidate_Contact__c = true LIMIT 1)
            FROM Account
            WHERE Personal_Email__c IN :emails
               OR (Phone_Normalized__c IN :phones AND RecordTypeId = :candidateRtId)
               OR (Name IN :names AND RecordTypeId = :candidateRtId)
            LIMIT 500
        ]) {
            String e = AiJson.normalizeEmail(a.Personal_Email__c);
            if (a.RecordTypeId != candidateRtId) {
                if (e != null) otherByEmail.put(e, a);
                continue;
            }
            if (e != null) candByEmail.put(e, a);
            String p = String.isNotBlank(a.Phone_Normalized__c) ? a.Phone_Normalized__c : AiJson.digitsOnly(a.Phone);
            if (p != null) {
                if (!candByPhone.containsKey(p)) candByPhone.put(p, new List<Account>());
                candByPhone.get(p).add(a);
            }
            String li = AiJson.normalizeUrl(a.LinkedIn__c);
            if (li != null) candByLinkedIn.put(li, a);
            if (a.Date_of_Birth__c != null) candByNameDob.put(a.Name.toLowerCase() + '|' + a.Date_of_Birth__c, a);
        }

        // ---------- 3. Match or create ----------
        List<Account> toInsert = new List<Account>();
        Map<Id, Account> toUpdate = new Map<Id, Account>();
        List<Candidate> ordered = new List<Candidate>();
        Map<String, Account> seenInThisFile = new Map<String, Account>();

        for (Candidate c : cands) {
            if (c.email != null && otherByEmail.containsKey(c.email) && !candByEmail.containsKey(c.email)) {
                Account other = otherByEmail.get(c.email);
                String msg = c.name + ' (' + c.email + ') already exists as ' + other.RecordType.Name
                    + ' Account "' + other.Name + '". It was not changed.';
                if (strict && cands.size() == 1) throw new IntakeProcessor.RejectException(msg + ' Nothing was created.');
                res.skipped.add(msg);
                continue;
            }

            Account match = null;
            if (c.email != null) match = candByEmail.get(c.email);
            if (match == null && c.phoneKey != null && candByPhone.containsKey(c.phoneKey)) {
                List<Account> samePhone = candByPhone.get(c.phoneKey);
                if (!strict) {
                    // Email / WhatsApp path: unchanged behaviour
                    match = samePhone[samePhone.size() - 1];
                } else {
                    // Qbay Home upload: a phone match counts only when the name also agrees,
                    // so a different person with the same number is never merged into another candidate
                    for (Account a : samePhone) {
                        if (sameName(a.Name, c.name)) { match = a; break; }
                    }
                    if (match == null) c.phoneConflict = samePhone[0].Name;
                }
            }
            if (match == null && c.linkedInKey != null) match = candByLinkedIn.get(c.linkedInKey);
            if (match == null && c.dob != null) match = candByNameDob.get(c.name.toLowerCase() + '|' + c.dob);
            if (match == null) match = seenInThisFile.get(c.dedupeKey());

            if (match != null) {
                if (c.fillBlanks(match)) toUpdate.put(match.Id, match);
                c.account = match;
                c.isNew = false;
            } else {
                Account a = c.toNewAccount(candidateRtId);
                toInsert.add(a);
                c.account = a;
                c.isNew = true;
                seenInThisFile.put(c.dedupeKey(), a);
            }
            ordered.add(c);
        }

        if (ordered.isEmpty()) {
            if (strict) throw new IntakeProcessor.RejectException(String.join(res.skipped, ' '));
            res.summary = String.join(res.skipped, ' ');
            return res;
        }

        // Our own matching ran above, so the standard Account duplicate rule alert must not block the save
        Database.DMLOptions accOpts = new Database.DMLOptions();
        accOpts.DuplicateRuleHeader.allowSave = true;
        if (!toInsert.isEmpty()) Database.insert(toInsert, accOpts);
        if (!toUpdate.isEmpty()) Database.update(toUpdate.values(), accOpts);

        // De-duplicate the account list (two resumes in one file may point to one Account)
        Map<Id, Account> uniqueAccounts = new Map<Id, Account>();
        Map<Id, List<Map<String, Object>>> skillsByAcc = new Map<Id, List<Map<String, Object>>>();
        Map<Id, List<Map<String, Object>>> certsByAcc = new Map<Id, List<Map<String, Object>>>();
        Map<Id, List<Map<String, Object>>> projsByAcc = new Map<Id, List<Map<String, Object>>>();
        for (Candidate c : ordered) {
            Id accId = c.account.Id;
            uniqueAccounts.put(accId, c.account);
            if (!skillsByAcc.containsKey(accId)) {
                skillsByAcc.put(accId, new List<Map<String, Object>>());
                certsByAcc.put(accId, new List<Map<String, Object>>());
                projsByAcc.put(accId, new List<Map<String, Object>>());
            }
            skillsByAcc.get(accId).addAll(AiJson.objList(c.raw, 'skills'));
            certsByAcc.get(accId).addAll(AiJson.objList(c.raw, 'certifications'));
            projsByAcc.get(accId).addAll(AiJson.objList(c.raw, 'projects'));
            if (c.isNew) res.created++; else res.updated++;
        }
        List<Account> accounts = uniqueAccounts.values();

        // ---------- 4. Link the resume file to every candidate (new or existing) ----------
        linkFile(contentDocumentId, uniqueAccounts.keySet());

        // ---------- 5. Candidate Contact (only when the Account has none) ----------
        List<Contact> contacts = new List<Contact>();
        Set<Id> withContact = new Set<Id>();
        for (Contact ct : [SELECT AccountId FROM Contact WHERE AccountId IN :uniqueAccounts.keySet() AND Candidate_Contact__c = true]) {
            withContact.add(ct.AccountId);
        }
        Set<Id> contactPlanned = new Set<Id>();
        for (Candidate c : ordered) {
            if (withContact.contains(c.account.Id) || contactPlanned.contains(c.account.Id)) continue;
            contacts.add(c.toContact(contactExternalRtId));
            contactPlanned.add(c.account.Id);
        }
        if (!contacts.isEmpty()) {
            Database.DMLOptions opts = new Database.DMLOptions();
            opts.DuplicateRuleHeader.allowSave = true;
            Database.insert(contacts, opts);
        }

        // ---------- 6. Certifications and projects (same transaction) ----------
        List<List<Map<String, Object>>> certs = new List<List<Map<String, Object>>>();
        List<List<Map<String, Object>>> projs = new List<List<Map<String, Object>>>();
        List<List<Map<String, Object>>> skills = new List<List<Map<String, Object>>>();
        for (Account a : accounts) {
            certs.add(certsByAcc.get(a.Id));
            projs.add(projsByAcc.get(a.Id));
            skills.add(skillsByAcc.get(a.Id));
        }
        handleCertifications(accounts, certs);
        handleProjects(accounts, projs);

        // ---------- 7. Skills (async, own transaction) ----------
        // (in tests a queueable cannot chain another one)
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs() && !(Test.isRunningTest() && System.isQueueable())) {
            System.enqueueJob(new CandidateSkillQueueable(accounts, skills));
        }

        res.accounts = accounts;
        res.primaryAccountId = accounts[0].Id;
        List<String> parts = new List<String>();
        for (Candidate c : ordered) {
            String line = (c.isNew ? 'Created ' : 'Updated existing ') + 'candidate ' + c.account.Name;
            if (c.isNew && c.phoneConflict != null) {
                line += ' (the phone number ' + c.phone + ' is also on the existing candidate ' + c.phoneConflict
                    + ', but the names differ, so the two were kept separate)';
            }
            parts.add(line);
        }
        if (!res.skipped.isEmpty()) parts.add('Skipped: ' + String.join(res.skipped, '; '));
        res.summary = String.join(parts, '. ') + '.';
        return res;
    }

    // ---------- duplicate by name (file has a name but no contact details) ----------

    @TestVisible
    private static List<Account> existingCandidatesByName(String name) {
        if (String.isBlank(name)) return new List<Account>();
        return [
            SELECT Id, Name, CreatedDate, CreatedBy.Name
            FROM Account
            WHERE RecordTypeId = :candidateRtId AND Name = :name
            ORDER BY CreatedDate ASC
            LIMIT 5
        ];
    }

    @TestVisible
    private static IntakeProcessor.DuplicateException duplicateByName(String name, List<Account> same) {
        Account first = same[0];
        String msg;
        if (same.size() == 1) {
            msg = 'Duplicate: a candidate named ' + first.Name + ' already exists (created on '
                + first.CreatedDate.format('dd MMM yyyy') + ' by ' + first.CreatedBy.Name + '). Nothing was created.';
        } else {
            msg = 'Duplicate: ' + same.size() + (same.size() == 5 ? ' or more' : '') + ' candidates named ' + name
                + ' already exist. The oldest one is linked to this upload. Nothing was created.';
        }
        IntakeProcessor.DuplicateException d = new IntakeProcessor.DuplicateException(msg);
        d.accountId = first.Id;
        return d;
    }

    /**
     * Adds contact details typed by the recruiter (Needs Review) to the first resume of the AI JSON,
     * so the normal matching and save can run without a new AI call.
     */
    public static String withContact(String rawJson, String email, String phone, String linkedIn) {
        Map<String, Object> parsed = AiJson.parse(rawJson);
        if (parsed == null) throw new IntakeProcessor.RejectException('The saved AI response for this file could not be read. Please upload the file again.');
        List<Map<String, Object>> resumes = AiJson.objList(parsed, 'resumes');
        Map<String, Object> acc;
        if (!resumes.isEmpty()) {
            acc = AiJson.obj(resumes[0], 'account');
            if (acc == null) {
                acc = new Map<String, Object>();
                resumes[0].put('account', acc);
            }
            parsed.put('resumes', resumes);
        } else {
            acc = AiJson.obj(parsed, 'account');
            if (acc == null) throw new IntakeProcessor.RejectException('No candidate was found in the saved AI response. Please upload the file again.');
        }
        if (String.isNotBlank(email)) acc.put('email', email.trim());
        if (String.isNotBlank(phone)) acc.put('phone', phone.trim());
        if (String.isNotBlank(linkedIn)) acc.put('linkedin', linkedIn.trim());
        return JSON.serialize(parsed);
    }

    @TestVisible
    private static String missingContactMessage(String name) {
        return 'Found the name "' + name + '" but no email, phone number or LinkedIn profile in this file. '
            + 'If the contact details are inside an image or icon, add them as plain text and upload again. Nothing was created.';
    }

    // =====================================================================
    // Candidate view of one resume in the AI JSON
    // =====================================================================
    private class Candidate {
        Map<String, Object> raw;
        Map<String, Object> acc;
        String name, email, phone, phoneKey, linkedIn, linkedInKey, fileTitle;
        String phoneConflict; // name of an existing candidate with the same phone but a different name
        Date dob;
        Account account;
        Boolean isNew;

        Candidate(Map<String, Object> resume, String fileTitle) {
            this.raw = resume;
            this.acc = AiJson.obj(resume, 'account');
            if (this.acc == null) this.acc = new Map<String, Object>();
            this.fileTitle = fileTitle;
            this.name = AiJson.str(acc, 'name');
            if (this.name == null) {
                String fn = AiJson.str(acc, 'firstName'), ln = AiJson.str(acc, 'lastName');
                if (fn != null || ln != null) this.name = ((fn == null ? '' : fn) + ' ' + (ln == null ? '' : ln)).trim();
            }
            if (this.name != null) this.name = toTitleCaseIfUpper(this.name).left(255);
            this.email = AiJson.normalizeEmail(AiJson.str(acc, 'email'));
            this.phone = AiJson.str(acc, 'phone');
            this.phoneKey = AiJson.digitsOnly(this.phone);
            this.linkedIn = AiJson.str(acc, 'linkedin');
            this.linkedInKey = AiJson.normalizeUrl(this.linkedIn);
            this.dob = AiJson.toDate(acc.get('dateofBirth'));
        }

        Boolean hasMinimumData() {
            return String.isNotBlank(name) && (email != null || phoneKey != null || linkedInKey != null);
        }

        String dedupeKey() {
            if (email != null) return 'e:' + email;
            if (phoneKey != null) return 'p:' + phoneKey;
            return 'l:' + linkedInKey;
        }

        Map<String, Object> fields() {
            List<String> past = AiJson.strList(acc, 'pastCompanies');
            Map<String, Object> f = new Map<String, Object>{
                'Phone' => phone == null ? null : phone.left(40),
                'Phone_Normalized__c' => phoneKey,
                'Personal_Email__c' => email,
                'Description' => left(AiJson.str(acc, 'summary'), 32000),
                'Designation__c' => left(AiJson.str(acc, 'designation'), 200),
                'LinkedIn__c' => left(linkedIn, 255),
                'Years_of_Experience__c' => left(AiJson.str(acc, 'experience'), 200),
                'Experience_Years__c' => AiJson.toNumber(acc.get('experience')),
                'Languages_Known__c' => left(AiJson.str(acc, 'languagesKnown'), 255),
                'Current_Organization__c' => left(AiJson.str(acc, 'currentCompany'), 200),
                'Current_Location__c' => left(AiJson.str(acc, 'currentLocation'), 200),
                'Past_Companies__c' => past.isEmpty() ? null : left(String.join(past, ', '), 50000),
                'FileName__c' => left(fileTitle, 255),
                'Degree__c' => left(AiJson.str(acc, 'degree'), 255),
                'College_Name__c' => left(AiJson.str(acc, 'college'), 255),
                'Date_of_Birth__c' => dob
            };
            Decimal ev = (Decimal) f.get('Experience_Years__c');
            if (ev != null && ev >= 1000) f.put('Experience_Years__c', null);
            return f;
        }

        Account toNewAccount(Id rtId) {
            Account a = new Account(
                RecordTypeId = rtId,
                Name = name,
                Status__c = 'Active',
                Account_Type__c = 'Candidate'
            );
            Map<String, Object> f = fields();
            for (String k : f.keySet()) {
                if (f.get(k) != null) a.put(k, f.get(k));
            }
            return a;
        }

        /** Fills only empty fields. Never renames, never blanks. Returns true if anything changed. */
        Boolean fillBlanks(Account a) {
            Boolean changed = false;
            Map<String, Object> f = fields();
            for (String k : f.keySet()) {
                Object v = f.get(k);
                if (v == null) continue;
                Object cur = a.get(k);
                if (cur == null || (cur instanceof String && String.isBlank((String) cur))) {
                    a.put(k, v);
                    changed = true;
                }
            }
            if (k_fileNameIsId(a) && fileTitle != null) { a.FileName__c = fileTitle.left(255); changed = true; }
            return changed;
        }

        Contact toContact(Id rtId) {
            String first = null, last = name;
            if (name.contains(' ')) {
                first = name.substringBeforeLast(' ').left(40);
                last = name.substringAfterLast(' ');
            }
            Contact c = new Contact(
                AccountId = account.Id,
                FirstName = first,
                LastName = last.left(80),
                Email = email,
                Personal_Email__c = email,
                Phone = phone == null ? null : phone.left(40),
                LinkedIn__c = left(linkedIn, 255),
                Candidate_Contact__c = true,
                Contact_Type__c = 'Candidates',
                Birthdate = dob
            );
            if (rtId != null) c.RecordTypeId = rtId;
            return c;
        }
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    /**
     * Lenient name check for phone matches: true when the two names share at least one word of 2+ letters
     * ("Rahul Sharma" = "RAHUL SHARMA" = "Rahul S" = "R. Sharma"; "John Smith" != "Rahul Sharma").
     */
    @TestVisible
    private static Boolean sameName(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) return false;
        Set<String> wa = nameWords(a);
        for (String w : nameWords(b)) {
            if (wa.contains(w)) return true;
        }
        return false;
    }

    private static Set<String> nameWords(String s) {
        Set<String> out = new Set<String>();
        for (String w : s.toLowerCase().replaceAll('[^a-z ]', ' ').split('\\s+')) {
            if (w.length() >= 2) out.add(w);
        }
        return out;
    }

    private static Boolean k_fileNameIsId(Account a) {
        // Earlier versions stored a ContentDocument Id (069...) in FileName__c
        return a.FileName__c != null && Pattern.matches('^069[a-zA-Z0-9]{12,15}$', a.FileName__c);
    }

    private static String left(String s, Integer n) {
        return s == null ? null : s.left(n);
    }

    private static String toTitleCaseIfUpper(String s) {
        if (s == null || s != s.toUpperCase()) return s;
        List<String> words = new List<String>();
        for (String w : s.toLowerCase().split('\\s+')) {
            words.add(w.length() > 0 ? w.substring(0, 1).toUpperCase() + w.substring(1) : w);
        }
        return String.join(words, ' ');
    }

    private static String fileTitleOf(String contentDocumentId) {
        if (String.isBlank(contentDocumentId)) return null;
        List<ContentDocument> docs = [SELECT Title, FileExtension FROM ContentDocument WHERE Id = :contentDocumentId LIMIT 1];
        if (docs.isEmpty()) return null;
        String t = docs[0].Title;
        if (docs[0].FileExtension != null && !t.toLowerCase().endsWith('.' + docs[0].FileExtension.toLowerCase())) {
            t = t + '.' + docs[0].FileExtension;
        }
        return t;
    }

    public static void linkFile(String contentDocumentId, Set<Id> accountIds) {
        if (String.isBlank(contentDocumentId) || accountIds.isEmpty()) return;
        Set<Id> already = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId IN :accountIds
        ]) {
            already.add(l.LinkedEntityId);
        }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Id accId : accountIds) {
            if (already.contains(accId)) continue;
            links.add(new ContentDocumentLink(
                ContentDocumentId = contentDocumentId,
                LinkedEntityId = accId,
                ShareType = 'V',
                Visibility = 'AllUsers'
            ));
        }
        if (!links.isEmpty()) insert links;
    }

    private static String clean(String s) {
        return s == null ? '' : s.toLowerCase().replaceAll('[^a-z0-9]', '');
    }

    /* ================= CERTIFICATIONS ================= */

    private static void handleCertifications(List<Account> accounts, List<List<Map<String, Object>>> certsByResume) {
        Map<String, Certification__c> existingMap = new Map<String, Certification__c>();
        for (Certification__c cert : [
            SELECT Id, Candidate_Name__c, Full_Certification_Name__c, Issuing_Organization__c,
                   Issue_Date__c, Expiration_Date__c
            FROM Certification__c WHERE Candidate_Name__c IN :accounts
        ]) {
            existingMap.put(cert.Candidate_Name__c + '::' + clean(cert.Full_Certification_Name__c), cert);
        }

        List<Certification__c> toInsert = new List<Certification__c>();
        Map<Id, Certification__c> toUpdate = new Map<Id, Certification__c>();
        Set<String> seen = new Set<String>();

        for (Integer i = 0; i < accounts.size(); i++) {
            for (Map<String, Object> c : certsByResume[i]) {
                String name = AiJson.str(c, 'name');
                if (name == null) continue;
                String key = accounts[i].Id + '::' + clean(name);
                if (seen.contains(key)) continue;
                seen.add(key);

                String org = AiJson.str(c, 'issuedBy');
                Date issueDate = AiJson.toDate(c.get('issueDate'));
                Date expiryDate = AiJson.toDate(c.get('expiryDate'));

                if (existingMap.containsKey(key)) {
                    Certification__c ex = existingMap.get(key);
                    Boolean ch = false;
                    if (ex.Issuing_Organization__c == null && org != null) { ex.Issuing_Organization__c = org; ch = true; }
                    if (ex.Issue_Date__c == null && issueDate != null) { ex.Issue_Date__c = issueDate; ch = true; }
                    if (expiryDate != null && ex.Expiration_Date__c != expiryDate) { ex.Expiration_Date__c = expiryDate; ch = true; }
                    if (ch) toUpdate.put(ex.Id, ex);
                } else {
                    toInsert.add(new Certification__c(
                        Name = name.left(80),
                        Full_Certification_Name__c = name,
                        Issuing_Organization__c = org,
                        Issue_Date__c = issueDate,
                        Expiration_Date__c = expiryDate,
                        Candidate_Name__c = accounts[i].Id
                    ));
                }
            }
        }
        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate.values();
    }

    /* ================= PROJECTS ================= */

    private static final List<String> PROJECT_TEXT_KEYS = new List<String>{
        'projectRole', 'situation', 'task', 'action', 'result', 'learningOutcome', 'skillsApplied',
        'toolsUsed', 'achievements', 'responsibilities', 'designationJobTitle', 'projectLocation', 'environment'
    };
    private static final Map<String, String> PROJECT_FIELD_BY_KEY = new Map<String, String>{
        'projectRole' => 'Project_Role__c', 'situation' => 'Situtation__c', 'task' => 'Task__c',
        'action' => 'Action__c', 'result' => 'Result__c', 'learningOutcome' => 'Learning_Outcome__c',
        'skillsApplied' => 'Skills_Applied__c', 'toolsUsed' => 'Tools_Used__c',
        'achievements' => 'Achievements__c', 'responsibilities' => 'Responsibilities__c',
        'designationJobTitle' => 'Designation_Job_Title__c', 'projectLocation' => 'Project_Location__c',
        'environment' => 'Environment__c'
    };

    private static void handleProjects(List<Account> accounts, List<List<Map<String, Object>>> projsByResume) {
        Map<String, Project_Experience__c> existingMap = new Map<String, Project_Experience__c>();
        for (Project_Experience__c pe : [
            SELECT Id, Employee_Name__c, Full_Project_Name__c, Client_Name__c, Project_Role__c, Situtation__c,
                   Task__c, Action__c, Result__c, Learning_Outcome__c, Skills_Applied__c, Tools_Used__c,
                   Start_Date__c, End_Date__c, Achievements__c, Responsibilities__c, Designation_Job_Title__c,
                   Project_Location__c, Environment__c
            FROM Project_Experience__c WHERE Employee_Name__c IN :accounts
        ]) {
            existingMap.put(pe.Employee_Name__c + '::' + clean(pe.Full_Project_Name__c) + '::' + clean(pe.Client_Name__c), pe);
        }

        Map<String, SObjectField> peFields = Schema.SObjectType.Project_Experience__c.fields.getMap();
        List<Project_Experience__c> toInsert = new List<Project_Experience__c>();
        Map<Id, Project_Experience__c> toUpdate = new Map<Id, Project_Experience__c>();
        Set<String> seen = new Set<String>();

        for (Integer i = 0; i < accounts.size(); i++) {
            Account acc = accounts[i];
            for (Map<String, Object> p : projsByResume[i]) {
                String projName = AiJson.str(p, 'projectName');
                if (projName == null) continue;
                String client = AiJson.str(p, 'clientName');
                String key = acc.Id + '::' + clean(projName) + '::' + clean(client);
                if (seen.contains(key)) continue;
                seen.add(key);

                Project_Experience__c rec = existingMap.containsKey(key)
                    ? existingMap.get(key)
                    : new Project_Experience__c(
                        Name = projName.left(80),
                        Full_Project_Name__c = projName,
                        Project_Name__c = projName,
                        Client_Name__c = client,
                        Employee_Name__c = acc.Id);
                Boolean changed = rec.Id == null;

                for (String k : PROJECT_TEXT_KEYS) {
                    String f = PROJECT_FIELD_BY_KEY.get(k);
                    String v = AiJson.str(p, k);
                    if (v == null) continue; // never blank an existing value
                    Integer maxLen = peFields.get(f).getDescribe().getLength();
                    if (maxLen > 0) v = v.left(maxLen);
                    if (rec.get(f) != v) { rec.put(f, v); changed = true; }
                }
                Date sd = AiJson.toDate(p.get('startDate'));
                Date ed = AiJson.toDate(p.get('endDate'));
                if (sd != null && rec.Start_Date__c != sd) { rec.Start_Date__c = sd; changed = true; }
                if (ed != null && rec.End_Date__c != ed) { rec.End_Date__c = ed; changed = true; }

                if (rec.Id == null) toInsert.add(rec);
                else if (changed) toUpdate.put(rec.Id, rec);
            }
        }
        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate.values();
    }
}