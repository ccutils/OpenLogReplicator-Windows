# Keeps the parent SSH session alive so OpenSSH does not clean up the child.
$root='C:\OLR-Windows-validation-20261116'
$env:ORACLE_HOME='C:\app\Administrator\product\11.2.0\dbhome_2'
$env:ORACLE_SID='ORCL'
$env:PATH="$env:ORACLE_HOME\bin;$env:PATH"
$env:NLS_LANG='AMERICAN_AMERICA.AL32UTF8'
$run=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$p=Start-Process -FilePath "$root\bin\OpenLogReplicator.exe" -ArgumentList '-f',"$root\config\validation.local.json" -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardError "$root\logs\run-$run.stderr.log" -RedirectStandardOutput "$root\logs\run-$run.stdout.log" -PassThru
$null=$p.Handle # Cache the native handle before exit (Windows PowerShell 5.1).
@{pid=$p.Id;run=$run;log="$root\logs\run-$run.stderr.log"} | ConvertTo-Json | Set-Content "$root\test-results\current-run.json"
Write-Output "Started validation OLR PID=$($p.Id) run=$run"
$p.WaitForExit()
Write-Output "Validation OLR exited with $($p.ExitCode)"
exit $p.ExitCode
