param([string]$Transport='network',[string]$Format='json',[int]$Port=15081)
. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$name="$Transport-$Format"
$directory="$ValidationRoot\experimental\streams"
$config=Get-Content "$ValidationRoot\config\validation.local.json" -Raw|ConvertFrom-Json
$state="experimental/streams/checkpoint-$name"
if(Test-Path (Join-Path $ValidationRoot $state)){throw 'Use a fresh stream validation state directory'}
New-Item -ItemType Directory (Join-Path $ValidationRoot $state) | Out-Null
New-Item -ItemType Directory -Force "$directory\swap-$name" | Out-Null
$config.source[0].state.path=$state
$config.source[0].state.'interval-s'=1
$config.source[0].memory.'swap-path'="experimental/streams/swap-$name"
$config.source[0].arch='online-keep'
$config.source[0].flags=0
$config.source[0].PSObject.Properties.Remove('debug')
$config.source[0].format.type=$Format
$uri=if($Transport -eq 'network'){"127.0.0.1:$Port"}else{"tcp://127.0.0.1:$Port"}
$config.target[0].writer=[pscustomobject]@{type=$Transport;uri=$uri;'max-message-mb'=10}
$path="$ValidationRoot\config\stream-$name.local.json"
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
& icacls.exe $path /inheritance:r /grant:r '*S-1-5-32-544:(F)' '*S-1-5-18:(F)' | Out-Null
if($LASTEXITCODE){throw 'Stream config ACL failed'}
$p=Start-Process -FilePath "$directory\OpenLogReplicator.exe" -ArgumentList '--oracle-home',$env:ORACLE_HOME,'-f',$path -WorkingDirectory $ValidationRoot -WindowStyle Hidden -RedirectStandardError "$directory\$name.stderr.log" -RedirectStandardOutput "$directory\$name.stdout.log" -PassThru
$null=$p.Handle
@{pid=$p.Id;log="$directory\$name.stderr.log";name=$name;state=$state}|ConvertTo-Json|Set-Content "$directory\current-run.json"
Write-Output "Isolated stream validation PID=$($p.Id) transport=$Transport format=$Format port=$Port"
$p.WaitForExit()
Write-Output "Stream process exit=$($p.ExitCode)"
exit $p.ExitCode
