. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$accessPath="$ValidationRoot\experimental\kafka\access.local.json"
& icacls.exe $accessPath /inheritance:r /grant:r '*S-1-5-32-544:(F)' '*S-1-5-18:(F)' | Out-Null
if($LASTEXITCODE){throw 'Kafka access file ACL failed'}
$access=Get-Content $accessPath -Raw|ConvertFrom-Json
if($access.topic -notmatch '^olrw_win2012_cdc_20261116_[0-9a-f]{8}$'){throw 'Refusing topic outside validation namespace'}
$config=Get-Content "$ValidationRoot\config\validation.local.json" -Raw|ConvertFrom-Json
$state="experimental/kafka/checkpoint-$($access.topic)"
New-Item -ItemType Directory -Path (Join-Path $ValidationRoot $state) | Out-Null
New-Item -ItemType Directory -Force "$ValidationRoot\experimental\kafka\swap" | Out-Null
$config.source[0].state.path=$state
$config.source[0].state.'interval-s'=1
$config.source[0].memory.'swap-path'='experimental/kafka/swap'
$config.source[0].arch='online-keep'
$config.source[0].flags=0
$config.source[0] | Add-Member -NotePropertyName debug -NotePropertyValue ([pscustomobject]@{'stop-transactions'=5}) -Force
$config.target[0].alias='KAFKA_VALIDATION'
$config.target[0].writer=[pscustomobject]@{
    type='kafka';topic=$access.topic;'max-message-mb'=1
    properties=[pscustomobject]@{
        'bootstrap.servers'=$access.brokers
        'security.protocol'=$access.protocol
        'sasl.mechanisms'=$access.mechanism
        'sasl.username'=$access.username
        'sasl.password'=$access.password
        'enable.idempotence'='true'
        'acks'='all'
        'delivery.timeout.ms'='15000'
        'request.timeout.ms'='10000'
        'allow.auto.create.topics'='false'
        'client.id'='OLR-Windows-Kafka-validation'
    }
}
$path="$ValidationRoot\config\kafka-validation.local.json"
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
& icacls.exe $path /inheritance:r /grant:r '*S-1-5-32-544:(F)' '*S-1-5-18:(F)' | Out-Null
if($LASTEXITCODE){throw 'OLR Kafka config ACL failed'}
Write-Output "Prepared independent Kafka reader checkpoint; topic=$($access.topic)"
