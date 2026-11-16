. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$source='C:\APP\ADMINISTRATOR\FLASH_RECOVERY_AREA\ORCL\ARCHIVELOG\2026_11_16'
$target="$ValidationRoot\archive-fixture-v2\2026_11_16"
New-Item -ItemType Directory -Path $target -Force | Out-Null
$files=@(Get-ChildItem -LiteralPath $source -Filter '*.ARC' | Where-Object {$_.Name -match '_398[56]_'})
Assert-Validation ($files.Count -eq 2) 'two required original archives located for read-only copy'
foreach($file in $files) {
    Copy-Item -LiteralPath $file.FullName -Destination $target
    $copy=Join-Path $target $file.Name
    Assert-Validation ((Get-FileHash $copy).Hash -eq (Get-FileHash $file.FullName).Hash) 'archive fixture copy hash matches original'
}
$path="$ValidationRoot\config\fault.local.json"
$config=Get-Content $path -Raw | ConvertFrom-Json
$config.source[0] | Add-Member -NotePropertyName debug -NotePropertyValue ([pscustomobject]@{'stop-transactions'=1}) -Force
[IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
$log="$ValidationRoot\logs\fault-restored.stderr.log"
$p=Start-Process -FilePath "$ValidationRoot\bin\OpenLogReplicator.exe" -ArgumentList '-f',$path -WorkingDirectory $ValidationRoot -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$ValidationRoot\logs\fault-restored.stdout.log" -PassThru
$null=$p.Handle # Cache the native handle before exit (Windows PowerShell 5.1).
if(!$p.WaitForExit(45000)){$p.Kill();throw 'Restored archive did not complete bounded validation'}
Assert-Validation ($p.ExitCode -eq 0) 'restored archives permit clean bounded replay'
$messages=@()
Get-ChildItem "$ValidationRoot\logs\fault-v2-*.json" | ForEach-Object {
    foreach($line in [IO.File]::ReadAllLines($_.FullName,[Text.Encoding]::UTF8)) { if($line){$messages+=($line|ConvertFrom-Json)} }
}
$dml=@($messages|ForEach-Object{$_.payload}|Where-Object{$_.op -in @('c','u','d')})
Assert-Validation ($dml.Count -eq 1 -and $dml[0].after.ID -eq 401 -and $dml[0].after.VALUE -ceq 'missing-archive-recovery') 'restored archive replays exactly the unacknowledged row'
Get-Content $log -Tail 8
@{stage='missing-archive-restored';passed=$true;dml_count=$dml.Count;exit_code=$p.ExitCode} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\restored-archive-summary.json"
