. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$result=Get-Content "$ValidationRoot\test-results\kafka-process-result.json" -Raw|ConvertFrom-Json
Assert-Validation ($result.exit_code -eq 0) 'Kafka OLR stopped cleanly after the bounded transaction batch'
$received=Get-Content "$ValidationRoot\test-results\kafka-consumed-verification.json" -Raw|ConvertFrom-Json
$config=Get-Content "$ValidationRoot\config\kafka-validation.local.json" -Raw|ConvertFrom-Json
$writer=$config.target[0].writer
Assert-Validation ($writer.topic -eq $received.topic -and $writer.properties.'security.protocol' -eq 'SASL_PLAINTEXT' -and $writer.properties.'sasl.mechanisms' -eq 'SCRAM-SHA-256' -and $writer.properties.'sasl.username' -eq 'app_user') 'native producer used the supplied app_user SCRAM configuration and only the isolated topic'
$checkpoint=Get-Content (Join-Path $ValidationRoot ($config.source[0].state.path+'/ORCL-chkpt.json')) -Raw|ConvertFrom-Json
$text=Get-Content $result.log -Raw
# Upstream builderBegin stores msg->lwnIdx=lwnIdx++, then JSON appendHeader
# emits the incremented lwnIdx. Disk checkpoint is zero-based, JSON is +1.
$lastInternalIdx=$received.last_c_idx-1
$exact=$checkpoint.scn -eq $received.last_c_scn -and $checkpoint.idx -eq $lastInternalIdx
$covers=$checkpoint.scn -gt $received.last_c_scn -or ($checkpoint.scn -eq $received.last_c_scn -and $checkpoint.idx -ge $lastInternalIdx)
Assert-Validation $covers 'writer checkpoint covers the final Kafka record using the upstream internal index'
# Upstream Writer also confirms non-published CHECKPOINT records locally.
# After a replay probe they can advance the on-disk watermark beyond Kafka.
$inherited='checkpoint - all confirmed till scn: '+$received.last_c_scn+', idx: '+$lastInternalIdx
Assert-Validation ($exact -or $text.Contains($inherited)) 'restart loaded the exact previously persisted Kafka acknowledgement before internal checkpoint progress'
Assert-Validation ($text -notmatch 'delivery failed|shutdown has unconfirmed messages') 'shutdown left no failed or unconfirmed Kafka deliveries'
$service=Get-CimInstance Win32_Service -Filter "Name='OLRWindowsValidation'"
Assert-Validation ($service.State -eq 'Running') 'baseline file-output service remains running'
$hash=(Get-FileHash "$ValidationRoot\bin\OpenLogReplicator.exe").Hash
Assert-Validation ($hash -eq '9F0B9D0F86EAF13872FDBC4161F3DDFF549B341B4D25A0ECCDFD594E8D0E38EE') 'baseline executable was not replaced'
@{passed=$true;topic=$writer.topic;checkpoint_scn=$checkpoint.scn;checkpoint_idx=$checkpoint.idx;exit_code=$result.exit_code;baseline_service_pid=$service.ProcessId} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\kafka-final-summary.json"
Get-Content $result.log -Tail 8
