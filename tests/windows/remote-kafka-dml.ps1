. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$access=Get-Content "$ValidationRoot\experimental\kafka\access.local.json" -Raw|ConvertFrom-Json
$run=Get-Content "$ValidationRoot\test-results\kafka-current-run.json" -Raw|ConvertFrom-Json
$process=Get-Process -Id $run.pid
if($process.Path -ne "$ValidationRoot\experimental\kafka\OpenLogReplicator.exe"){throw 'Unexpected Kafka validation process'}
$deadline=[DateTime]::UtcNow.AddSeconds(40)
do {
    $log=Get-Content $run.log -Raw
    if($log -match 'processing redo log: group: [1-9]'){break}
    if($process.HasExited){throw 'Kafka OLR exited before online reader was ready'}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($log -match 'processing redo log: group: [1-9]') 'isolated Kafka OLR has loaded Schema and is reading Online Redo'
$first=[long]$access.row_base+1
$second=[long]$access.row_base+2
$rolledBack=[long]$access.row_base+3
Invoke-ValidationSql @"
insert into OLRW_20261116_7A32.CDC_TEST values($first,'kafka-first',null);
commit;
update OLRW_20261116_7A32.CDC_TEST set VALUE=unistr('\4E2D\6587'),OPTIONAL_VALUE='kafka-updated' where ID=$first;
commit;
insert into OLRW_20261116_7A32.CDC_TEST values($second,'kafka-retained',null);
commit;
delete from OLRW_20261116_7A32.CDC_TEST where ID=$first;
commit;
insert into OLRW_20261116_7A32.CDC_TEST values($rolledBack,'kafka-rollback',null);
rollback;
declare n number;
begin
 select count(*) into n from OLRW_20261116_7A32.CDC_TEST where ID in ($first,$second,$rolledBack);
 if n<>1 then raise_application_error(-20101,'Unexpected Kafka test final row count'); end if;
 select count(*) into n from OLRW_20261116_7A32.CDC_TEST where ID=$second and VALUE='kafka-retained' and OPTIONAL_VALUE is null;
 if n<>1 then raise_application_error(-20102,'Kafka test final values differ'); end if;
end;
/
"@ | Tee-Object "$ValidationRoot\test-results\kafka-dml-sql.txt"
Write-Output "Committed Kafka test rows for base=$($access.row_base); rollback and final database state verified"
