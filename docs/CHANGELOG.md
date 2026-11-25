# Qbay upload intake – change log

Every change to QbayDev for the Qbay Home resume/JD upload goes through GitHub, on the
`main` branch only (no other branches). One commit per fix, deployed to QbayDev only from a
pushed commit. Baseline: full sandbox backup, commit e2840ba. Release v1 merged to main as
"v1 bugs fiex 24-11-2026" (commit b1ba796).

| # | Commit | What | Why / bug | Deployed |
|---|--------|------|-----------|----------|
| 1 | 09ea4c6 | Rebuild upload intake: intakeUploader LWC, IntakeController, IntakeProcessor, AiJson, controller rewrites, 15 fields, Error_Log_Event__e | Audit findings L1–L12, R1–R13, J1–J13 (duplicates, repeated Submit, wrong-file uploads, lost errors, blank overwrites) | 0Afe1000002PxRxCAK |
| 2 | 21e6403 | Rename `AiJson.list` to `objList` | Compile error: `list` is reserved in Apex | 0Afe1000002PxRxCAK |
| 3 | 8090834 | Rename `aiJson` variables to `rawJson` | Compile error: variable hid the AiJson class | 0Afe1000002PxRxCAK |
| 4 | 0e7561a | Cast nulls in CandidateCreationPromptTest | Test compile error: ambiguous overload | 0Afe1000002PxRxCAK |
| 5 | cbc925f | Select all JD fields before update; keep legacy contracts; Direct_Customers in JD test; PromptClassesTest | Bug: JD re-upload failed (Company_Name__c not queried); 10 test failures; coverage < 75% | 0Afe1000002PxRxCAK |
| 6 | fa30d47 | Reuse open Opportunity on matching JD text when a role is missing | Behaviour regression found by test_JDOnlyMatch | 0Afe1000002PxRxCAK |
| 7 | 1ff9d61 | Prompt edits + end-to-end test kit | Prompts invented JD text, repaired emails, defaulted Temp Holding Account | superseded by #8 |
| 8 | e73808f | Prompt edits as new active versions (_2, _14); pastCompanies example removed; "None" treated as blank | Bug: edits to published versions are ignored; AI copied the example into Past_Companies__c | 0Afe1000002PyRFCA0 |
| 9 | 553cb18 | Permission set + retest samples | Nobody could see the new fields | permission set NOT deployed (owner decision) |
| 10 | fcd1bee | System Administrator profile read/edit on the 15 fields | Owner decision: profile only, no permission set | 0Afe1000002PyZJCA0 |
| 11 | "Org metadata sync 25-11-2026 (before enhancements and bug fixes)" | Full org retrieve (manifest/full-backup.xml regenerated): v1 Intake classes/LWC/fields/prompts as deployed, new Intake_Setting__mdt, IntakeRouter, ServiceIntakeTrigger, org edits by others to parseEmail, parseEmailTest, IntakeRouter, WhatsAppUtils; profiles field perms. CustomLabels excluded (contains WhatsApp access tokens) | Org metadata snapshot before new work | n/a (retrieve only) |
| 12 | (fix 1, 25-11-2026) | Resume with a name but no contact details: look up existing Candidates by name first; status Duplicate, linked to the existing Account (CandidateCreationController, IntakeProcessor.DuplicateException) | D-012 / T-029: re-upload of an existing candidate showed "Could not find the candidate's name and an email..." instead of a duplicate message | pending |

## Open
- Project names end in " - None": flow `Project_Experience_Name_Update` appends TEXT(Project_Phase__c), default "None". Waiting for the owner's choice.

## Rules for future fixes
1. Work directly on `main`. Do not create other branches.
2. One fix = one commit, message says the bug and the fix; add a row above.
3. Validate (check-only) from the pushed commit, then deploy; record the deploy id here.
