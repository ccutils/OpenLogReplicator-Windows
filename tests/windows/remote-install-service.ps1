. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$path="$ValidationRoot\config\validation.local.json"
$config=Get-Content $path -Raw|ConvertFrom-Json
$config.source[0].flags=0
$config.source[0].arch='online-keep'
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
& "$ValidationRoot\scripts\install-service.ps1" -OracleHome $env:ORACLE_HOME -ConfigFile $path -ServiceName OLRWindowsValidation -ReadPaths @('C:\APP\ADMINISTRATOR\ORADATA\ORCL\REDO01.LOG','C:\APP\ADMINISTRATOR\ORADATA\ORCL\REDO02.LOG','C:\APP\ADMINISTRATOR\ORADATA\ORCL\REDO03.LOG','C:\APP\ADMINISTRATOR\FLASH_RECOVERY_AREA\ORCL\ARCHIVELOG') -LogMaxBytes 4096 -LogKeep 3 -Start
