# End-to-end test of the Qbay Home upload intake in QbayDev.
# Calls IntakeController.submitFile (the same Apex the Add Candidate / Add Job Description tabs call),
# waits for the background job, and saves every created record to e2e\results.
param([string]$Org = 'QbayDevJobdes')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here 'results'; New-Item -ItemType Directory -Force -Path $out | Out-Null
$stamp = Get-Date -Format 'yyyyMMddHHmmss'

function Submit($key, $type, $file) {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $here $file)))
    $apex = "IntakeController.IntakeStatus s = IntakeController.submitFile('$key', '$type', '$file', '$b64');`nSystem.debug(LoggingLevel.ERROR, 'E2E_RESULT ' + JSON.serialize(s));"
    $f = Join-Path $out "submit-$key.apex"; Set-Content -Path $f -Value $apex -Encoding UTF8
    $r = sf apex run --target-org $Org --file $f --json | ConvertFrom-Json
    $line = ($r.result.logs -split "`n" | Where-Object { $_ -match 'E2E_RESULT ' } | Select-Object -First 1)
    if (-not $r.result.success) { return @{ error = ($r.result.exceptionMessage + ' ' + $r.result.compileProblem) } }
    return ($line -replace '^.*E2E_RESULT ', '') | ConvertFrom-Json
}
function WaitFinal($key) {
    for ($i = 0; $i -lt 40; $i++) {
        $q = sf data query --target-org $Org --json -q "SELECT Id, Status__c, Status_Message__c FROM Service__c WHERE Request_Key__c = '$key'" | ConvertFrom-Json
        $s = $q.result.records[0]
        if ($s -and @('Queued','Processing','New') -notcontains $s.Status__c) { return $s }
        Start-Sleep -Seconds 10
    }
    return $s
}
function Dump($name, $soql) {
    $q = sf data query --target-org $Org --json -q $soql | ConvertFrom-Json
    $q.result.records | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $out "$name.json") -Encoding UTF8
    return $q.result.records
}

$summary = [ordered]@{}
$K1 = "e2e-$stamp-resume"; $K2 = "e2e-$stamp-resume-again"; $K3 = "e2e-$stamp-jd"; $K4 = "e2e-$stamp-wrongtab"

# 1. Resume on the Add Candidate tab
$summary.resume_submit = Submit $K1 'Resume' 'Kavya_Ramesh_Resume.pdf'
# 2. Same click twice (same request key) -> must return the same Service__c, no second record
$summary.resume_double_click = Submit $K1 'Resume' 'Kavya_Ramesh_Resume.pdf'
$summary.resume_final = WaitFinal $K1
# 3. Same file uploaded again later (new key) -> Duplicate, nothing new created
$summary.resume_same_file_again = Submit $K2 'Resume' 'Kavya_Ramesh_Resume.pdf'
$summary.resume_same_file_final = WaitFinal $K2
# 4. JD on the Add Job Description tab
$summary.jd_submit = Submit $K3 'Job Description' 'Northwind_Retail_Salesforce_Developer_JD.pdf'
$summary.jd_final = WaitFinal $K3
# 5. JD file uploaded on the Add Candidate tab -> Rejected
$summary.wrong_tab_submit = Submit $K4 'Resume' 'Northwind_Retail_Salesforce_Developer_JD.pdf'
$summary.wrong_tab_final = WaitFinal $K4
Start-Sleep -Seconds 20   # let the skill queueable finish

$svc = Dump 'service' "SELECT FIELDS(ALL) FROM Service__c WHERE Request_Key__c LIKE 'e2e-$stamp-%' LIMIT 20"
$summary.service_count_for_resume_key = @($svc | Where-Object { $_.Request_Key__c -eq $K1 }).Count
$accId = ($svc | Where-Object { $_.Request_Key__c -eq $K1 }).Account__c
if ($accId) {
    Dump 'account' "SELECT FIELDS(ALL) FROM Account WHERE Id = '$accId' LIMIT 1" | Out-Null
    Dump 'contact' "SELECT FIELDS(ALL) FROM Contact WHERE AccountId = '$accId' LIMIT 20" | Out-Null
    Dump 'certifications' "SELECT FIELDS(ALL) FROM Certification__c WHERE Candidate_Name__c = '$accId' LIMIT 50" | Out-Null
    Dump 'projects' "SELECT FIELDS(ALL) FROM Project_Experience__c WHERE Employee_Name__c = '$accId' LIMIT 50" | Out-Null
    Dump 'employee_skills' "SELECT Id, Skill__r.Name, Skill__r.Skill_Key__c, Proficiency__c FROM Employee_Skill__c WHERE Employee_Name__c = '$accId'" | Out-Null
    Dump 'resume_files' "SELECT ContentDocumentId, ContentDocument.Title, LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId = '$accId'" | Out-Null
    $summary.accounts_with_same_email = (Dump 'dup_check' "SELECT Id, Name FROM Account WHERE Personal_Email__c = 'kavya.ramesh.e2e@example.com'").Count
}
$jd = $svc | Where-Object { $_.Request_Key__c -eq $K3 }
if ($jd.Opportunity__c) {
    Dump 'opportunity' "SELECT FIELDS(ALL) FROM Opportunity WHERE Id = '$($jd.Opportunity__c)' LIMIT 1" | Out-Null
    Dump 'client_account' "SELECT Id, Name, RecordType.DeveloperName, Account_Type__c FROM Account WHERE Id IN (SELECT AccountId FROM Opportunity WHERE Id = '$($jd.Opportunity__c)')" | Out-Null
}
if ($jd.Job_Description__c) { Dump 'job_description' "SELECT FIELDS(ALL) FROM Job_Description__c WHERE Id = '$($jd.Job_Description__c)' LIMIT 1" | Out-Null }
Dump 'error_logs' "SELECT Id, CreatedDate, Name, Error_Message__c FROM Error_Log__c WHERE CreatedDate = TODAY ORDER BY CreatedDate DESC LIMIT 20" | Out-Null

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $out 'summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 6
