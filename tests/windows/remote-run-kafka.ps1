$root='C:\OLR-Windows-validation-20261116'
$env:ORACLE_HOME='C:\app\Administrator\product\11.2.0\dbhome_2'
$env:ORACLE_SID='ORCL'
$run=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$log="$root\experimental\kafka\run-$run.stderr.log"
$p=Start-Process -FilePath "$root\experimental\kafka\OpenLogReplicator.exe" -ArgumentList '--oracle-home',$env:ORACLE_HOME,'-f',"$root\config\kafka-validation.local.json" -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$root\experimental\kafka\run-$run.stdout.log" -PassThru
$null=$p.Handle
@{pid=$p.Id;log=$log;run=$run}|ConvertTo-Json|Set-Content "$root\test-results\kafka-current-run.json"
Write-Output "Started isolated Kafka validation OLR PID=$($p.Id)"
$p.WaitForExit()
@{exit_code=$p.ExitCode;pid=$p.Id;log=$log}|ConvertTo-Json|Set-Content "$root\test-results\kafka-process-result.json"
Write-Output "Kafka validation OLR exit code=$($p.ExitCode)"
exit $p.ExitCode
