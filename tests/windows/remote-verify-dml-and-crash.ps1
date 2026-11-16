. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$events=@(Get-ValidationEvents)
$dml=@($events | ForEach-Object {$_.payload} | Where-Object {$_.schema.owner -eq 'OLRW_20261116_7A32' -and $_.op -in @('c','u','d')})
Assert-Validation ($dml.Count -eq 4) 'exactly four committed DML events recovered after writer filename failure'
Assert-Validation (($dml.op -join ',') -eq 'c,u,c,d') 'INSERT UPDATE INSERT DELETE order'
Assert-Validation ($dml[0].after.ID -eq 101 -and $dml[0].after.VALUE -ceq 'first' -and $null -eq $dml[0].after.OPTIONAL_VALUE) 'INSERT values and NULL'
$expected=([char]0x4e2d).ToString()+([char]0x6587).ToString()
Assert-Validation ($dml[1].before.VALUE -ceq 'first' -and $dml[1].after.VALUE -ceq $expected -and $dml[1].after.OPTIONAL_VALUE -ceq 'changed') 'UPDATE before/after and exact Chinese Unicode code points'
Assert-Validation ($dml[3].before.ID -eq 101 -and $dml[3].before.VALUE -ceq $expected) 'DELETE before image'
Assert-Validation (@($dml | Where-Object {$_.after.ID -eq 103 -or $_.before.ID -eq 103}).Count -eq 0) 'rolled-back row is absent'
$lastScn=($events | Measure-Object -Property c_scn -Maximum).Maximum
$deadline=[DateTime]::UtcNow.AddSeconds(30)
do {
    $checkpoint=Get-Content "$ValidationRoot\checkpoint\ORCL-chkpt.json" -Raw | ConvertFrom-Json
    if($checkpoint.scn -ge $lastScn){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($checkpoint.scn -ge $lastScn) 'writer checkpoint has acknowledged all baseline events'
$checkpoint | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\checkpoint-before-crash.json"
Stop-ValidationProcess
Invoke-ValidationSql @'
insert into OLRW_20261116_7A32.CDC_TEST values (201,'while-stopped',null);
update OLRW_20261116_7A32.CDC_TEST set VALUE='retained-after-restart' where ID=102;
commit;
alter system archive log current;
select sequence#,archived,status from v$log order by sequence#;
select sequence#,name from v$archived_log where sequence# >= (select min(sequence#) from v$log) and name is not null order by sequence#;
'@ | Tee-Object "$ValidationRoot\test-results\crash-and-archive-sql.txt"
