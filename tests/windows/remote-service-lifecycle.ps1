. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$name='OLRWindowsValidation'
function Wait-Event([int]$Id) {
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    do {
        $events=@(Get-ValidationEvents | ForEach-Object {$_.payload} | Where-Object {$_.op -eq 'c' -and $_.after.ID -eq $Id})
        if($events.Count -gt 0){return $events}
        Start-Sleep -Milliseconds 500
    }while([DateTime]::UtcNow -lt $deadline)
    throw "No CDC event for ID=$Id"
}
$service=Get-CimInstance Win32_Service -Filter "Name='$name'"
Assert-Validation ($service.State -eq 'Running' -and $service.StartMode -eq 'Auto') 'native service running with automatic startup configured'
Assert-Validation ($service.StartName -eq "NT SERVICE\$name") 'dedicated virtual service account, not an administrator'
$row=@(Wait-Event 401)
Assert-Validation ($row.Count -eq 1 -and $row[0].after.VALUE -ceq 'missing-archive-recovery') 'service really loads OCI and resumes CDC checkpoint'
Invoke-ValidationSql "insert into OLRW_20261116_7A32.CDC_TEST values(501,'service-before-stop',null);`ncommit;" | Out-Null
$row=@(Wait-Event 501)
Assert-Validation ($row.Count -eq 1) 'live CDC under virtual service account'
Stop-Service $name
(Get-Service $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))
$service=Get-CimInstance Win32_Service -Filter "Name='$name'"
Assert-Validation ($service.State -eq 'Stopped' -and $service.ExitCode -eq 0) 'SCM stop completes cleanly'
$checkpoint=Get-Content "$ValidationRoot\checkpoint\ORCL-chkpt.json" -Raw | ConvertFrom-Json
$checkpoint|ConvertTo-Json|Set-Content "$ValidationRoot\test-results\service-stopped-checkpoint.json"
Invoke-ValidationSql "insert into OLRW_20261116_7A32.CDC_TEST values(502,'service-while-stopped',null);`ncommit;" | Out-Null
Start-Service $name
(Get-Service $name).WaitForStatus('Running',[TimeSpan]::FromSeconds(30))
$row=@(Wait-Event 502)
Assert-Validation ($row.Count -eq 1 -and $row[0].after.VALUE -ceq 'service-while-stopped') 'normal service restart resumes changes committed while stopped'
$row=@(Wait-Event 501)
Assert-Validation ($row.Count -eq 1) 'normal restart did not repeat acknowledged test event'
$service=Get-CimInstance Win32_Service -Filter "Name='$name'"
$old=[int]$service.ProcessId
$process=Get-Process -Id $old
if($process.Path -ne "$ValidationRoot\bin\OpenLogReplicator.exe"){throw 'Unexpected service image; refusing termination'}
Stop-Process -Id $old -Force
Write-Output "Crashed only service PID=$old; waiting for configured SCM recovery (up to 60 seconds plus startup)"
$deadline=[DateTime]::UtcNow.AddSeconds(95)
do {
    $service=Get-CimInstance Win32_Service -Filter "Name='$name'"
    if($service.State -eq 'Running' -and $service.ProcessId -ne $old -and $service.ProcessId -ne 0){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($service.State -eq 'Running' -and $service.ProcessId -ne $old -and $service.ProcessId -ne 0) 'SCM automatically restarts the deliberately crashed validation service'
Invoke-ValidationSql "insert into OLRW_20261116_7A32.CDC_TEST values(503,'service-after-crash',null);`ncommit;" | Out-Null
$row=@(Wait-Event 503)
Assert-Validation ($row.Count -eq 1) 'CDC continues after automatic service recovery'
$files=@(Get-ChildItem "$ValidationRoot\logs\OpenLogReplicator.log*")
Assert-Validation ($files.Count -ge 2 -and $files.Count -le 4) 'diagnostic logs rotate and obey three-archive retention'
Assert-Validation (@($files | Where-Object {$_.Length -gt 8192}).Count -eq 0) 'diagnostic log sizes stay within bounded rotation tolerance'
@{stage='service-lifecycle';passed=$true;service=$name;crashed_pid=$old;recovered_pid=$service.ProcessId;diagnostic_files=$files.Count} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\service-summary.json"
& "$ValidationRoot\scripts\get-status.ps1" -ServiceName $name -Json
