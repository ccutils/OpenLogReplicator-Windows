[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OracleHome, [string]$ConfigFile)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if (!$ConfigFile) { $ConfigFile=Join-Path $root 'config/OpenLogReplicator.json' }
$oracleBin=if(Test-Path (Join-Path $OracleHome 'bin/oci.dll')) { Join-Path $OracleHome 'bin' } else { $OracleHome }
if (!(Test-Path (Join-Path $oracleBin 'oci.dll'))) { throw 'OracleHome must contain a compatible x64 OCI runtime.' }
$env:PATH="$oracleBin;$env:PATH"
Push-Location $root
try { & (Join-Path $root 'bin/OpenLogReplicator.exe') --oracle-home $OracleHome -f $ConfigFile; $result=$LASTEXITCODE }
finally { Pop-Location }
exit $result
