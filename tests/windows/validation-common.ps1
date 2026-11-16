$script:ValidationRoot='C:\OLR-Windows-validation-20261116'
$env:ORACLE_HOME='C:\app\Administrator\product\11.2.0\dbhome_2'
$env:ORACLE_SID='ORCL'
$env:PATH="$env:ORACLE_HOME\bin;$env:PATH"
function Invoke-ValidationSql([string]$Sql) {
    $text="whenever sqlerror exit failure rollback`nset pages 100 lines 220`n$Sql`nexit`n"
    $output=$text | & "$env:ORACLE_HOME\bin\sqlplus.exe" -L -s '/ as sysdba' 2>&1
    if($LASTEXITCODE) { throw ($output -join "`n") }
    return $output
}
function Get-ValidationEvents {
    $events=@()
    Get-ChildItem "$script:ValidationRoot\logs\cdc-*.json" | Sort-Object Name | ForEach-Object {
        $stream=New-Object IO.FileStream($_.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
        try { while($null -ne ($line=$reader.ReadLine())) { if($line) { $events+=($line | ConvertFrom-Json) } } }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    return $events
}
function Assert-Validation([bool]$Condition,[string]$Message) {
    if(!$Condition){throw "FAIL: $Message"}
    Write-Output "PASS: $Message"
}
function Stop-ValidationProcess {
    $run=Get-Content "$script:ValidationRoot\test-results\current-run.json" -Raw | ConvertFrom-Json
    $process=Get-Process -Id $run.pid
    $expected=Join-Path $script:ValidationRoot 'bin\OpenLogReplicator.exe'
    if($process.Path -ne $expected){throw 'Refusing to stop a process outside the validation installation'}
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
    Write-Output "Stopped only validation OLR PID=$($process.Id) for crash-recovery test"
}
