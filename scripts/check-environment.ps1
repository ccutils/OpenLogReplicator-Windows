[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OracleHome, [string]$ConfigFile, [switch]$Json)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if (!$ConfigFile) { $ConfigFile=Join-Path $root 'config/OpenLogReplicator.json' }
$checks=New-Object 'Collections.Generic.List[object]'
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail) {
    $checks.Add([pscustomobject]@{name=$Name;passed=$Passed;detail=$Detail})
}
$version=[Environment]::OSVersion.Version
Add-Check 'WindowsVersion' ($version -ge [version]'6.3') $version.ToString()
Add-Check '64BitProcess' ([Environment]::Is64BitProcess) 'Use 64-bit PowerShell and OCI'
$oracleBin=if(Test-Path (Join-Path $OracleHome 'bin/oci.dll')) { Join-Path $OracleHome 'bin' } else { $OracleHome }
$oci=Join-Path $oracleBin 'oci.dll'
Add-Check 'OracleOCI' (Test-Path -LiteralPath $oci) $oci
try {
    $config=Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    Add-Check 'Configuration' ($config.version -eq '1.9.0') 'Expected schema version 1.9.0'
    $ready=$true
    foreach($source in $config.source) {
        if (!$source.reader.password -or $source.reader.password -eq 'REPLACE_WITH_DATABASE_PASSWORD') { $ready=$false }
    }
    Add-Check 'CredentialsConfigured' $ready 'Passwords are never printed by this script'
} catch { Add-Check 'Configuration' $false 'Cannot read or parse configuration JSON' }
foreach($folder in @('logs','checkpoint','swap','config')) {
    $directory=Join-Path $root $folder
    $probe=Join-Path $directory ([guid]::NewGuid().ToString('N')+'.probe')
    try {
        [IO.File]::WriteAllBytes($probe,[byte[]]@(0,10,13,26,255))
        Remove-Item -LiteralPath $probe
        Add-Check "Writable:$folder" $true $directory
    } catch { Add-Check "Writable:$folder" $false $directory }
}
$exe=Join-Path $root 'bin/OpenLogReplicator.exe'
$originalPath=$env:PATH
try {
    $env:PATH="$oracleBin;$env:PATH"
    $process=New-Object Diagnostics.Process
    $process.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName=$exe
    $process.StartInfo.Arguments='--oracle-home "'+$OracleHome+'" -v'
    $process.StartInfo.UseShellExecute=$false
    $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true
    $process.StartInfo.RedirectStandardError=$true
    if (!$process.Start()) { throw 'Process start failed' }
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(15000)) { $process.Kill(); throw 'Version command timed out' }
    $banner=$stdout.Result+$stderr.Result
    Add-Check 'ExecutableStartup' ($process.ExitCode -eq 0 -and $banner -match 'modules:.*OCI') 'Must start with OCI module; this does not validate database access or CDC'
} catch { Add-Check 'ExecutableStartup' $false 'Could not start executable' }
finally { $env:PATH=$originalPath; if($process) { $process.Dispose() } }
if ($Json) { $checks | ConvertTo-Json -Depth 4 } else { $checks | Format-Table -AutoSize }
if (@($checks | Where-Object { !$_.passed }).Count) { exit 1 }
exit 0
