# Run on the isolated Oracle validation server as its authorized DBA account.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OracleHome,
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$Schema = 'OLRW_20261116_7A32'
)
$ErrorActionPreference='Stop'
if ($Schema -cnotmatch '^[A-Z][A-Z0-9_]{0,29}$') { throw 'Invalid test schema name' }
$sqlplus=Join-Path $OracleHome 'bin/sqlplus.exe'
$env:ORACLE_HOME=$OracleHome
$env:ORACLE_SID='ORCL'
$env:PATH="$(Join-Path $OracleHome 'bin');$env:PATH"
$env:NLS_LANG='AMERICAN_AMERICA.AL32UTF8'
$password='T'+[guid]::NewGuid().ToString('N').Substring(0,22)+'9a'
# CREATE USER deliberately fails if this schema already exists. Never reuse or
# delete a pre-existing schema. SQLPlus exits immediately on any SQL error.
$grants=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'grants.sql')).Replace('<USER>', $Schema)
$sql=@"
whenever sqlerror exit failure rollback
set echo off verify off feedback on
create user $Schema identified by "$password" default tablespace USERS quota 64M on USERS;
grant create session, create table to $Schema;
$grants
create table ${Schema}.CDC_TEST (ID number primary key, VALUE varchar2(100), OPTIONAL_VALUE varchar2(100));
alter table ${Schema}.CDC_TEST add supplemental log data (all) columns;
select banner from v`$version;
select name, log_mode, supplemental_log_data_min from v`$database;
exit
"@
$result=$sql | & $sqlplus -L -s '/ as sysdba' 2>&1
if ($LASTEXITCODE -ne 0) { throw (($result -join "`n").Replace($password,'[REDACTED]')) }
$config=Get-Content (Join-Path $Root 'config/OpenLogReplicator.json') -Raw | ConvertFrom-Json
$config.source[0].reader.user=$Schema
$config.source[0].reader.password=$password
$config.source[0].filter.table[0].owner=$Schema
$config.source[0].state.'interval-s'=2
$config.source[0].format | Add-Member -NotePropertyName schema -NotePropertyValue 1 -Force
$config.source[0].format | Add-Member -NotePropertyName column -NotePropertyValue 2 -Force
$file=Join-Path $Root 'config/validation.local.json'
[IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
& icacls.exe $file /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE) { throw 'Could not restrict credential file ACL' }
Write-Output ($result -join "`n")
Write-Output "Prepared isolated validation schema $Schema and protected config. Credentials were not printed."
