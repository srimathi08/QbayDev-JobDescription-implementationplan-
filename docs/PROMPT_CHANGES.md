# Prompt template changes (Candidate_CreationFile, JD_Prompt)

Edit ONLY the active version's <content> (Candidate_CreationFile `_1`, JD_Prompt `_13`). Keep every other version,
identifier, input and data provider as is. Deploy the single template, then confirm in Prompt Builder that the edited
version is the active one. If the deploy of a GenAiPromptTemplate is refused, make the same edits in Prompt Builder
(Save As New Version -> Activate) instead.

## Candidate_CreationFile

1. Replace the first line `File ID - {!$Input:File.Id}` with:
   `Resume file: {!$Input:File.Id}`
2. Directly before `TASKS`, insert:
   ```
   DOCUMENT CHECK (do this first)
   • Decide what the file is and put it in "documentType": "Resume" for a candidate CV/resume, "Job Description" for a job description / requirement, "Other" for anything else.
   • If documentType is not "Resume", return only {"documentType":"<value>","resumes":[]} and nothing else.
   ```
3. In SCHEMA, add `"documentType": "Resume",` as the first key, before `"resumes": [`.
4. In SCHEMA, change `"filename": ""` guidance: add to STRICT RULES the line
   `• Always leave "filename" as an empty string; the system fills it.`
5. Replace the whole "Email Handling Rule" block with:
   ```
   • Email Handling Rule:
    - Copy the email address exactly as written in the resume.
    - If it is not a valid address (<text>@<domain>.<tld>), leave it empty.
    - Never add, guess or repair parts of an email.
   ```

## JD_Prompt

1. Delete the line `- Only if it is not detailed, create a detailed job description yourself.`
   and add instead: `- Never invent or expand job description content. Use only text that is present in the inputs.`
2. Directly before `TASKS`, insert:
   ```
   DOCUMENT CHECK (do this first)
   • Decide what the input is and put it in "documentType": "Job Description" for a job description / requirement, "Resume" for a candidate CV/resume, "Other" for anything else.
   • If documentType is not "Job Description", return only {"documentType":"<value>","jobs":[]} and nothing else.
   ```
3. In SCHEMA, add `"documentType": "Job Description",` as the first key, before `"jobs": [`.
4. Replace `- If the Job Description does not contain a company name, set "companyName": "Temp Holding Account".`
   with `- If the Job Description does not contain a company name, set "companyName": "".`
   (The email/WhatsApp path still falls back to "Temp Holding Account" in Apex; the Qbay Home upload rejects it.)
