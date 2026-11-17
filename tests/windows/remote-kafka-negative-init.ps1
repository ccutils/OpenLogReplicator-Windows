$root='C:\OLR-Windows-validation-20261116'
$log="$root\experimental\kafka\unsupported-scram.stderr.log"
$p=Start-Process -FilePath "$root\experimental\kafka\OpenLogReplicator.exe" -ArgumentList '--oracle-home','C:\app\Administrator\product\11.2.0\dbhome_2','-f',"$root\config\kafka-validation.local.json" -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$root\experimental\kafka\unsupported-scram.stdout.log" -PassThru
$null=$p.Handle
if(!$p.WaitForExit(30000)){$p.Kill();throw 'Unsupported SCRAM initialization did not exit'}
$text=Get-Content $log -Raw
if($p.ExitCode -ne 1 -or $text -notmatch 'SCRAM-SHA-256|sasl.mechanisms|SASL support') {throw 'Expected controlled unsupported-authentication failure'}
Write-Output 'PASS: unsupported authentication returns exit 1 without a null-producer crash'
Get-Content $log -Tail 6
