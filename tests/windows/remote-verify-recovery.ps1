. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$deadline=[DateTime]::UtcNow.AddSeconds(40)
do {
    $events=@(Get-ValidationEvents)
    $dml=@($events | ForEach-Object {$_.payload} | Where-Object {$_.schema.owner -eq 'OLRW_20261116_7A32' -and $_.op -in @('c','u','d')})
    if($dml.Count -ge 6){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($dml.Count -eq 6) 'checkpoint crash restart recovered two offline changes without replaying acknowledged baseline'
Assert-Validation ($dml[4].op -eq 'c' -and $dml[4].after.ID -eq 201 -and $dml[4].after.VALUE -ceq 'while-stopped') 'archived INSERT recovered'
Assert-Validation ($dml[5].op -eq 'u' -and $dml[5].after.ID -eq 102 -and $dml[5].after.VALUE -ceq 'retained-after-restart') 'archived UPDATE recovered'
$identities=@($events | ForEach-Object {"$($_.c_scn):$($_.c_idx)"})
Assert-Validation (@($identities | Select-Object -Unique).Count -eq $identities.Count) 'no duplicated output checkpoint identities in this settled-checkpoint test'
$run=Get-Content "$ValidationRoot\test-results\current-run.json" -Raw | ConvertFrom-Json
$log=Get-Content $run.log -Raw
Assert-Validation ($log -match 'processing redo log: group: 0.*3983.*\.ARC') 'actual archived redo file processed'
Assert-Validation ($log -match 'processing redo log: group: [1-9].*seq: 3984') 'reader resumed current online sequence after archive'
Invoke-ValidationSql @'
declare n number;
begin
 select count(*) into n from OLRW_20261116_7A32.CDC_TEST;
 if n<>2 then raise_application_error(-20001,'Unexpected final row count'); end if;
 select count(*) into n from OLRW_20261116_7A32.CDC_TEST where (ID=102 and VALUE='retained-after-restart' and OPTIONAL_VALUE is null) or (ID=201 and VALUE='while-stopped' and OPTIONAL_VALUE is null);
 if n<>2 then raise_application_error(-20002,'Final row values differ'); end if;
end;
/
select ID,VALUE,OPTIONAL_VALUE from OLRW_20261116_7A32.CDC_TEST order by ID;
'@ | Tee-Object "$ValidationRoot\test-results\recovery-database-result.txt"
Write-Output 'PASS: final Oracle rows agree with replayed CDC state'
@{stage='checkpoint-and-archive';passed=$true;dml_count=$dml.Count;message_count=$events.Count;archive_sequence=3983;online_sequence=3984} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\recovery-summary.json"
