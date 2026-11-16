[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ScriptFile,
    [Parameter(Mandatory=$true)][string]$KeyPath,
    [string]$Server='192.168.2.5'
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$body=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptFile))
$prefix="`$ProgressPreference='SilentlyContinue'; `$ErrorActionPreference='Stop';`n"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix+$body))
& ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes "-oUserKnownHostsFile=$root/.ssh-known-hosts" -i $KeyPath "administrator@$Server" powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
exit $LASTEXITCODE
