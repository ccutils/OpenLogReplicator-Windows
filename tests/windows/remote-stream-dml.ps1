param([long]$RowBase=8100100)
. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$run=Get-Content "$ValidationRoot\experimental\streams\current-run.json" -Raw|ConvertFrom-Json
$p=Get-Process -Id $run.pid
if($p.Path -ne "$ValidationRoot\experimental\streams\OpenLogReplicator.exe"){throw 'Unexpected stream process'}
$deadline=[DateTime]::UtcNow.AddSeconds(60)
do {
    $log=Get-Content $run.log -Raw
    if($log -match 'processing redo log: group: [1-9]'){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($log -match 'processing redo log: group: [1-9]') 'stream reader ready for online redo'
$first=$RowBase+1; $second=$RowBase+2; $rollback=$RowBase+3
Invoke-ValidationSql @"
insert into OLRW_20261116_7A32.CDC_TEST values($first,'stream-first',null);
commit;
update OLRW_20261116_7A32.CDC_TEST set VALUE=unistr('\4E2D\6587'),OPTIONAL_VALUE='stream-updated' where ID=$first;
commit;
insert into OLRW_20261116_7A32.CDC_TEST values($second,'stream-retained',null);
commit;
delete from OLRW_20261116_7A32.CDC_TEST where ID=$first;
commit;
insert into OLRW_20261116_7A32.CDC_TEST values($rollback,'stream-rollback',null);
rollback;
"@
