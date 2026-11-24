# End-to-end test of the Qbay Home upload intake in QbayDev.
# Calls IntakeController.submitFile (the same Apex the Add Candidate / Add Job Description tabs call),
# waits for the background job, and saves every created record to e2e\results.
#
# Notes for Windows PowerShell 5.1:
# - Apex files are written as UTF-8 WITHOUT a BOM (Set-Content -Encoding UTF8 adds a BOM, which Apex rejects).
# - The running user may not have field-level access to the new Service__c fields, so status polling goes
#   through IntakeController.getStatus (system mode) instead of an API query on Service__c.
param([string]$Org = 'QbayDevJobdes', [string]$Stamp = '', [string]$Mode = 'full')   # -Stamp reuses the request keys of an earlier run (submitFile is idempotent per key)
$ErrorActionPreference = 'Stop'
$env:SF_SKIP_NEW_VERSION_CHECK = 'true'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here 'results'; New-Item -ItemType Directory -Force -Path $out | Out-Null
$stamp = if ($Stamp) { $Stamp } else { Get-Date -Format 'yyyyMMddHHmmss' }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function WriteText($path, $text) { [IO.File]::WriteAllText($path, $text, $utf8NoBom) }

function RunApex($name, $apex) {
    $f = Join-Path $out "$name.apex"; WriteText $f $apex
    $raw = (& sf apex run --target-org $Org --file $f --json 2>$null) | Out-String
    $r = $raw | ConvertFrom-Json
    $res = if ($r.result) { $r.result } else { $r.data }
    if (-not $res -or -not $res.success) {
        return @{ error = ("$($r.message) $($res.compileProblem) $($res.exceptionMessage)").Trim() }
    }
    $line = ($res.logs -split "`n" | Where-Object { $_ -match 'USER_DEBUG.*E2E_RESULT ' } | Select-Object -First 1)
    return ($line -replace '^.*E2E_RESULT ', '') | ConvertFrom-Json
}
function Submit($key, $type, $file) {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $here $file)))
    $apex = "IntakeController.IntakeStatus s = IntakeController.submitFile('$key', '$type', '$file', '$b64');`nSystem.debug(LoggingLevel.ERROR, 'E2E_RESULT ' + JSON.serialize(s));"
    return RunApex "submit-$key" $apex
}
function GetStatus($serviceId) {
    $apex = "System.debug(LoggingLevel.ERROR, 'E2E_RESULT ' + JSON.serialize(IntakeController.getStatus(new List<Id>{ '$serviceId' })[0]));"
    return RunApex "status-$serviceId" $apex
}
function WaitFinal($submitResult) {
    $id = $submitResult.serviceId
    if (-not $id) { return @{ error = 'no serviceId returned by submitFile' } }
    $s = $null
    for ($i = 0; $i -lt 40; $i++) {
        $s = GetStatus $id
        if ($s.error -or $s.isFinal) { return $s }
        Start-Sleep -Seconds 10
    }
    return $s
}
function Dump($name, $soql) {
    $raw = (& sf data query --target-org $Org --json -q $soql 2>$null) | Out-String
    $q = $raw | ConvertFrom-Json
    if ($q.status -ne 0) {
        WriteText (Join-Path $out "$name.json") ($raw)
        return @()
    }
    WriteText (Join-Path $out "$name.json") ($q.result.records | ConvertTo-Json -Depth 6)
    return $q.result.records
}

$summary = [ordered]@{ stamp = $stamp }

if ($Mode -eq 'retest') {
    # Retest after the prompt/AiJson changes: a new resume on the Resume tab, a JD without a company on the JD tab.
    $R1 = "e2e-$stamp-arjun"; $R2 = "e2e-$stamp-nocompany-jd"
    $summary.arjun_submit = Submit $R1 'Resume' 'Arjun_Menon_Resume.pdf'
    $summary.arjun_final = WaitFinal $summary.arjun_submit
    $summary.nocompany_jd_submit = Submit $R2 'Job Description' 'No_Company_Salesforce_Admin_JD.pdf'
    $summary.nocompany_jd_final = WaitFinal $summary.nocompany_jd_submit
    Start-Sleep -Seconds 20   # let the skill queueable finish
    $svcIds = @($summary.arjun_submit.serviceId, $summary.nocompany_jd_submit.serviceId) | Where-Object { $_ }
    if ($svcIds.Count) { Dump 'service' ("SELECT FIELDS(ALL) FROM Service__c WHERE Id IN ('" + ($svcIds -join "','") + "') LIMIT 20") | Out-Null }
    $accId = $summary.arjun_final.accountId
    if ($accId) {
        Dump 'account' "SELECT FIELDS(ALL), RecordType.DeveloperName FROM Account WHERE Id = '$accId' LIMIT 1" | Out-Null
        Dump 'contact' "SELECT FIELDS(ALL) FROM Contact WHERE AccountId = '$accId' LIMIT 20" | Out-Null
        Dump 'certifications' "SELECT FIELDS(ALL) FROM Certification__c WHERE Candidate_Name__c = '$accId' LIMIT 50" | Out-Null
        Dump 'projects' "SELECT FIELDS(ALL) FROM Project_Experience__c WHERE Employee_Name__c = '$accId' LIMIT 50" | Out-Null
        Dump 'employee_skills' "SELECT Id, Skill__r.Name, Proficiency__c FROM Employee_Skill__c WHERE Employee_Name__c = '$accId'" | Out-Null
        Dump 'resume_files' "SELECT ContentDocumentId, ContentDocument.Title, LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId = '$accId'" | Out-Null
    }
    $jd = $summary.nocompany_jd_final
    if ($jd.opportunityId) { Dump 'opportunity' "SELECT FIELDS(ALL) FROM Opportunity WHERE Id = '$($jd.opportunityId)' LIMIT 1" | Out-Null }
    if ($jd.jobDescriptionId) { Dump 'job_description' "SELECT FIELDS(ALL) FROM Job_Description__c WHERE Id = '$($jd.jobDescriptionId)' LIMIT 1" | Out-Null }
    Dump 'error_logs' "SELECT Id, CreatedDate, Name, Error_Message__c FROM Error_Log__c WHERE CreatedDate = TODAY ORDER BY CreatedDate DESC LIMIT 20" | Out-Null
    WriteText (Join-Path $out 'summary.json') ($summary | ConvertTo-Json -Depth 6)
    $summary | ConvertTo-Json -Depth 6
    return
}
$K1 = "e2e-$stamp-resume"; $K2 = "e2e-$stamp-resume-again"; $K3 = "e2e-$stamp-jd"; $K4 = "e2e-$stamp-wrongtab"

# 1. Resume on the Add Candidate tab
$summary.resume_submit = Submit $K1 'Resume' 'Kavya_Ramesh_Resume.pdf'
# 2. Same click twice (same request key) -> must return the same Service__c, no second record
$summary.resume_double_click = Submit $K1 'Resume' 'Kavya_Ramesh_Resume.pdf'
$summary.resume_final = WaitFinal $summary.resume_submit
# 3. Same file uploaded again later (new key) -> Duplicate, nothing new created
$summary.resume_same_file_again = Submit $K2 'Resume' 'Kavya_Ramesh_Resume.pdf'
$summary.resume_same_file_final = WaitFinal $summary.resume_same_file_again
# 4. JD on the Add Job Description tab
$summary.jd_submit = Submit $K3 'Job Description' 'Northwind_Retail_Salesforce_Developer_JD.pdf'
$summary.jd_final = WaitFinal $summary.jd_submit
# 5. JD file uploaded on the Add Candidate tab -> Rejected
$summary.wrong_tab_submit = Submit $K4 'Resume' 'Northwind_Retail_Salesforce_Developer_JD.pdf'
$summary.wrong_tab_final = WaitFinal $summary.wrong_tab_submit
Start-Sleep -Seconds 20   # let the skill queueable finish

$summary.same_service_on_double_click = ($summary.resume_submit.serviceId -and $summary.resume_submit.serviceId -eq $summary.resume_double_click.serviceId)
$svcIds = @($summary.resume_submit.serviceId, $summary.resume_same_file_again.serviceId, $summary.jd_submit.serviceId, $summary.wrong_tab_submit.serviceId) | Where-Object { $_ } | Select-Object -Unique
if ($svcIds.Count) { Dump 'service' ("SELECT FIELDS(ALL) FROM Service__c WHERE Id IN ('" + ($svcIds -join "','") + "') LIMIT 20") | Out-Null }

$accId = $summary.resume_final.accountId
if ($accId) {
    Dump 'account' "SELECT FIELDS(ALL), RecordType.DeveloperName FROM Account WHERE Id = '$accId' LIMIT 1" | Out-Null
    Dump 'contact' "SELECT FIELDS(ALL) FROM Contact WHERE AccountId = '$accId' LIMIT 20" | Out-Null
    Dump 'certifications' "SELECT FIELDS(ALL) FROM Certification__c WHERE Candidate_Name__c = '$accId' LIMIT 50" | Out-Null
    Dump 'projects' "SELECT FIELDS(ALL) FROM Project_Experience__c WHERE Employee_Name__c = '$accId' LIMIT 50" | Out-Null
    Dump 'employee_skills' "SELECT Id, Skill__r.Name, Proficiency__c FROM Employee_Skill__c WHERE Employee_Name__c = '$accId'" | Out-Null
    Dump 'resume_files' "SELECT ContentDocumentId, ContentDocument.Title, LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId = '$accId'" | Out-Null
    $summary.accounts_with_same_email = @(Dump 'dup_check' "SELECT Id, Name FROM Account WHERE Personal_Email__c = 'kavya.ramesh.e2e@example.com'").Count
}
$jd = $summary.jd_final
if ($jd.opportunityId) {
    Dump 'opportunity' "SELECT FIELDS(ALL) FROM Opportunity WHERE Id = '$($jd.opportunityId)' LIMIT 1" | Out-Null
    Dump 'client_account' "SELECT Id, Name, RecordType.DeveloperName, Account_Type__c FROM Account WHERE Id IN (SELECT AccountId FROM Opportunity WHERE Id = '$($jd.opportunityId)')" | Out-Null
}
if ($jd.jobDescriptionId) { Dump 'job_description' "SELECT FIELDS(ALL) FROM Job_Description__c WHERE Id = '$($jd.jobDescriptionId)' LIMIT 1" | Out-Null }
Dump 'error_logs' "SELECT Id, CreatedDate, Name, Error_Message__c FROM Error_Log__c WHERE CreatedDate = TODAY ORDER BY CreatedDate DESC LIMIT 20" | Out-Null

WriteText (Join-Path $out 'summary.json') ($summary | ConvertTo-Json -Depth 6)
$summary | ConvertTo-Json -Depth 6
