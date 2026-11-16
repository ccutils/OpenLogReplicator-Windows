. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$name='OLRWindowsValidation'
$service=Get-CimInstance Win32_Service -Filter "Name='$name'"
Assert-Validation ($service.PathName.StartsWith('"'+"$ValidationRoot\bin\OpenLogReplicator.exe"+'" ')) 'service binary path quotes preserved through native installation API'
Stop-Service $name
$controller=Get-Service $name
$controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60));$controller.Dispose()
Start-Service $name
Stop-Service $name
$controller=Get-Service $name
$controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60));$controller.Dispose()
Assert-Validation ((Get-Service $name).Status -eq 'Stopped') 'immediate stop during service startup completes without lost wakeup'
Invoke-ValidationSql @'
insert into OLRW_20261116_7A32.CDC_TEST values(504,'after-service-reinstall',null);
commit;
alter system archive log current;
'@ | Out-Null
Start-Service $name
$deadline=[DateTime]::UtcNow.AddSeconds(40)
do {
    $rows=@(Get-ValidationEvents|ForEach-Object{$_.payload}|Where-Object{$_.op -eq 'c' -and $_.after.ID -eq 504})
    if($rows.Count -eq 1){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($rows.Count -eq 1 -and $rows[0].after.VALUE -ceq 'after-service-reinstall') 'reinstalled service captures new archive created while stopped'
$service=Get-CimInstance Win32_Service -Filter "Name='$name'"
Assert-Validation ($service.State -eq 'Running' -and $service.StartName -eq "NT SERVICE\$name" -and $service.StartMode -eq 'Auto') 'final deployed service is running as virtual account with automatic startup'
@{stage='service-reinstall-and-startup-stop';passed=$true;pid=$service.ProcessId;test_id=504} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\service-final-summary.json"
& "$ValidationRoot\scripts\get-status.ps1" -ServiceName $name -Json
