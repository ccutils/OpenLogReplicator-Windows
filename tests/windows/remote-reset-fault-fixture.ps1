. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
# Reset only a copied test checkpoint and use fresh output/fixture directories.
$state="$ValidationRoot\fault-checkpoint-v2"
$fixture="$ValidationRoot\archive-fixture-v2"
New-Item -ItemType Directory -Path $state,$fixture | Out-Null
Copy-Item "$ValidationRoot\checkpoint\*.json" -Destination $state
$path="$ValidationRoot\config\fault.local.json"
$config=Get-Content $path -Raw|ConvertFrom-Json
$config.source[0].state.path='fault-checkpoint-v2'
$config.source[0].reader.'path-mapping'[1]=$fixture -replace '\\','/'
$config.target[0].writer.output='logs/fault-v2-%t.json'
$config.source[0].PSObject.Properties.Remove('debug')
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
Write-Output 'Fresh fixture and copied checkpoint prepared; no database changes'
