. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
Stop-ValidationProcess
$path="$ValidationRoot\config\validation.local.json"
$config=Get-Content $path -Raw | ConvertFrom-Json
$config.source[0] | Add-Member -NotePropertyName arch -NotePropertyValue 'online-keep' -Force
$config.source[0] | Add-Member -NotePropertyName 'refresh-interval-us' -NotePropertyValue 1000000 -Force
$config.source[0] | Add-Member -NotePropertyName flags -NotePropertyValue 1 -Force
$config.source[0] | Add-Member -NotePropertyName 'arch-read-sleep-us' -NotePropertyValue 1000000 -Force
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
Write-Output 'Prepared upstream ARCH_ONLY plus retained OCI connection so archive polling exercises connection health'
