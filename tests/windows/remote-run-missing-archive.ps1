. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$run=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$log="$ValidationRoot\logs\fault-$run.stderr.log"
$p=Start-Process -FilePath "$ValidationRoot\bin\OpenLogReplicator.exe" -ArgumentList '-f',"$ValidationRoot\config\fault.local.json" -WorkingDirectory $ValidationRoot -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$ValidationRoot\logs\fault-$run.stdout.log" -PassThru
$null=$p.Handle # Cache the native handle before exit (Windows PowerShell 5.1).
if(!$p.WaitForExit(45000)){ $p.Kill(); throw 'Missing-archive test did not report failure in time' }
$text=Get-Content $log -Raw
$text | Set-Content "$ValidationRoot\test-results\missing-archive-error.txt"
Assert-Validation ($text -match 'archive-fixture' -and $text -match 'ERROR') 'missing mapped archive reported explicitly'
Assert-Validation ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) 'missing archive returns nonzero process status'
Assert-Validation (@(Get-ChildItem "$ValidationRoot\logs\fault-v2-*.json" -ErrorAction SilentlyContinue).Count -eq 0) 'missing archive produced no false CDC output'
Write-Output "Actual process exit code=$($p.ExitCode)"
@{stage='missing-archive';passed=$true;exit_code=$p.ExitCode;log=$log} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\missing-archive-summary.json"
Get-Content $log -Tail 8
