. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
Invoke-ValidationSql @'
set serveroutput on
declare n number; sidval number; serialval number;
begin
 select count(*) into n from v$session where username='OLRW_20261116_7A32' and upper(program) like 'OPENLOGREPLICATOR%' and status<>'KILLED';
 if n<>1 then raise_application_error(-20003,'Expected exactly one isolated OLR session'); end if;
 select sid,serial# into sidval,serialval from v$session where username='OLRW_20261116_7A32' and upper(program) like 'OPENLOGREPLICATOR%' and status<>'KILLED';
 dbms_output.put_line('Disconnecting only test OLR SID='||sidval||' serial='||serialval);
 execute immediate 'alter system kill session '''||sidval||','||serialval||''' immediate';
end;
/
insert into OLRW_20261116_7A32.CDC_TEST values(302,'after-oci-reconnect',null);
commit;
alter system archive log current;
'@ | Tee-Object "$ValidationRoot\test-results\reconnect-sql.txt"
$deadline=[DateTime]::UtcNow.AddSeconds(45)
do {
    $run=Get-Content "$ValidationRoot\test-results\current-run.json" -Raw | ConvertFrom-Json
    $log=Get-Content $run.log -Raw
    if($log -match 'reconnecting to the database'){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($log -match 'ORA-00028|ORA-03113|ORA-03114|ORA-01012') 'dedicated OCI session disconnect detected'
Assert-Validation ($log -match 'reconnecting to the database') 'OCI reconnect attempted'
$deadline=[DateTime]::UtcNow.AddSeconds(30)
do {
    $events=@(Get-ValidationEvents)
    $row=@($events | ForEach-Object {$_.payload} | Where-Object {$_.op -eq 'c' -and $_.after.ID -eq 302})
    if($row.Count -eq 1){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($row.Count -eq 1 -and $row[0].after.VALUE -ceq 'after-oci-reconnect') 'committed test row captured across OCI disconnect'
Invoke-ValidationSql "select sid,serial#,status,program from v`$session where username='OLRW_20261116_7A32';" | Tee-Object "$ValidationRoot\test-results\reconnected-session.txt"
@{stage='oci-reconnect';passed=$true;test_id=302} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\reconnect-summary.json"
