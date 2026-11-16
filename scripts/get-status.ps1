[CmdletBinding()]
param([ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$ServiceName='OpenLogReplicator',[switch]$Json)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$service=Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
$checkpoints=@()
Get-ChildItem (Join-Path $root 'checkpoint') -Filter '*-chkpt.json' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $value=Get-Content $_.FullName -Raw|ConvertFrom-Json
        $checkpoints+=[pscustomobject]@{database=$value.database;scn=$value.scn;index=$value.idx;last_write_utc=$_.LastWriteTimeUtc.ToString('o');age_seconds=[int]([DateTime]::UtcNow-$_.LastWriteTimeUtc).TotalSeconds}
    } catch { $checkpoints+=[pscustomobject]@{file=$_.Name;error='Checkpoint is unreadable or currently being written'} }
}
$latest=Get-ChildItem (Join-Path $root 'logs') -Filter 'cdc-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$result=[pscustomobject]@{service=$ServiceName;installed=[bool]$service;state=$service.State;pid=$service.ProcessId;startup=$service.StartMode;exit_code=$service.ExitCode;checkpoints=$checkpoints;latest_cdc_file=$latest.Name;latest_cdc_write_utc=if($latest){$latest.LastWriteTimeUtc.ToString('o')}else{$null};note='SCM Running does not prove CDC progress. Idle databases may legitimately produce no events; compare SCN and source activity.'}
if ($Json) { $result|ConvertTo-Json -Depth 6 } else {$result|Format-List}
if (!$service -or $service.State -ne 'Running') { exit 1 }
exit 0
