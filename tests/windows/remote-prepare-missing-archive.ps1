. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$events=@(Get-ValidationEvents)
$scn=($events|Measure-Object c_scn -Maximum).Maximum
$deadline=[DateTime]::UtcNow.AddSeconds(30)
do {
    $checkpoint=Get-Content "$ValidationRoot\checkpoint\ORCL-chkpt.json" -Raw | ConvertFrom-Json
    if($checkpoint.scn -ge $scn){break}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow -lt $deadline)
Assert-Validation ($checkpoint.scn -ge $scn) 'checkpoint settled before isolated missing-archive fixture'
Stop-ValidationProcess
$fixture="$ValidationRoot\archive-fixture"
$state="$ValidationRoot\fault-checkpoint"
New-Item -ItemType Directory -Path $fixture,$state | Out-Null
Copy-Item "$ValidationRoot\checkpoint\*.json" -Destination $state
$path="$ValidationRoot\config\validation.local.json"
$config=Get-Content $path -Raw | ConvertFrom-Json
$config.source[0].state.path='fault-checkpoint'
$config.source[0].reader | Add-Member -NotePropertyName 'path-mapping' -NotePropertyValue @('C:\APP\ADMINISTRATOR\FLASH_RECOVERY_AREA\ORCL\ARCHIVELOG',($fixture -replace '\\','/')) -Force
$config.target[0].writer.output='logs/fault-%t.json'
[IO.File]::WriteAllText("$ValidationRoot\config\fault.local.json",($config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
& icacls.exe "$ValidationRoot\config\fault.local.json" /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if($LASTEXITCODE){throw 'Credential ACL failed'}
Invoke-ValidationSql @'
insert into OLRW_20261116_7A32.CDC_TEST values(401,'missing-archive-recovery',null);
commit;
alter system archive log current;
select sequence#,name from v$archived_log where sequence#=(select max(sequence#)-1 from v$log) and name is not null;
'@ | Tee-Object "$ValidationRoot\test-results\missing-archive-source.txt"
Write-Output 'Prepared empty mapped archive fixture; original Oracle archive files were not changed'
