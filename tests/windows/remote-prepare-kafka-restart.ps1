$root='C:\OLR-Windows-validation-20261116'
$path="$root\config\kafka-validation.local.json"
$config=Get-Content $path -Raw|ConvertFrom-Json
$config.source[0].debug.'stop-transactions'=1
# The upstream splitter reserves a full transaction chunk. Use a larger
# builder limit for the short recovery probe; payloads stay tiny.
$config.target[0].writer.'max-message-mb'=10
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
Write-Output 'Prepared short recovery probe; original Kafka checkpoint preserved. The debug counter also counts replayed/rolled-back transactions.'
