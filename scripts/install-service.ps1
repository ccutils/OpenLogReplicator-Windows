[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OracleHome,
    [string]$ConfigFile,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$ServiceName='OpenLogReplicator',
    [string[]]$ReadPaths=@(),
    [ValidateRange(1024,1073741824)][long]$LogMaxBytes=10485760,
    [ValidateRange(1,100)][int]$LogKeep=5,
    [switch]$Start
)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if (!(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated 64-bit PowerShell.' }
$root=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $root 'bin/OpenLogReplicator.exe'
if (!$ConfigFile) { $ConfigFile=Join-Path $root 'config/OpenLogReplicator.json' }
$ConfigFile=(Resolve-Path -LiteralPath $ConfigFile).Path
$OracleHome=(Resolve-Path -LiteralPath $OracleHome).Path
$configDirectory=(Join-Path $root 'config')+[IO.Path]::DirectorySeparatorChar
if (!$ConfigFile.StartsWith($configDirectory,[StringComparison]::OrdinalIgnoreCase)) { throw 'Service configuration must be inside the product config directory.' }
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { throw "Service $ServiceName already exists; refusing to overwrite." }
if (!(Test-Path -LiteralPath $exe)) { throw 'Product executable is missing.' }
$accessPaths=@($OracleHome)+@($ReadPaths | ForEach-Object {(Resolve-Path -LiteralPath $_).Path})
foreach($path in $accessPaths) {
    if ($path.TrimEnd('\') -eq [IO.Path]::GetPathRoot($path).TrimEnd('\')) { throw 'Refusing a read permission grant on an entire drive.' }
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'check-environment.ps1') -OracleHome $OracleHome -ConfigFile $ConfigFile
if ($LASTEXITCODE) { throw 'Environment checks failed; no service was created.' }
$command='"{0}" --service --service-name {1} --oracle-home "{2}" --log-max-bytes {3} --log-keep {4} -f "{5}"' -f $exe,$ServiceName,$OracleHome,$LogMaxBytes,$LogKeep,$ConfigFile
# Native API preserves quotes and passes a NULL password for a virtual account.
# Windows PowerShell 5.1 New-Service's PSCredential path rejects that account.
if (-not ('OLR.WindowsServiceSetup' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace OLR {
 public static class WindowsServiceSetup {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateServiceW(IntPtr manager, string name, string display, uint access,
   uint type, uint start, uint error, string binary, string group, IntPtr tag,
   string dependencies, string account, string password);
  [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr service);
  public static void Create(string name, string command) {
   IntPtr manager=OpenSCManagerW(null,null,2);
   if(manager==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    IntPtr service=CreateServiceW(manager,name,"OpenLogReplicator Windows ("+name+")",0xF01FF,
     0x10,2,1,command,null,IntPtr.Zero,null,"NT SERVICE\\"+name,null);
    if(service==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    CloseServiceHandle(service);
   } finally { CloseServiceHandle(manager); }
  }
 }
}
'@
}
[OLR.WindowsServiceSetup]::Create($ServiceName,$command)
try {
    & sc.exe sidtype $ServiceName unrestricted
    if ($LASTEXITCODE) { throw 'Service SID configuration failed.' }
    $account=New-Object Security.Principal.NTAccount('NT SERVICE',$ServiceName)
    $sid=$account.Translate([Security.Principal.SecurityIdentifier]).Value
    & icacls.exe $root /grant "*${sid}:(OI)(CI)(RX)" | Out-Null
    if ($LASTEXITCODE) { throw 'Product read permission failed.' }
    foreach($directory in @('config','logs','checkpoint','swap')) {
        & icacls.exe (Join-Path $root $directory) /grant "*${sid}:(OI)(CI)(M)" /T /Q | Out-Null
        if ($LASTEXITCODE) { throw "Runtime directory permission failed: $directory" }
    }
    # A credential file can deliberately disable inherited ACLs. Grant this
    # exact protected file read access rather than relaxing its protection.
    & icacls.exe $ConfigFile /grant "*${sid}:(R)" | Out-Null
    if ($LASTEXITCODE) { throw 'Protected configuration read permission failed.' }
    foreach($path in $accessPaths | Select-Object -Unique) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            & icacls.exe $path /grant "*${sid}:(OI)(CI)(RX)" /Q | Out-Null
            if ($LASTEXITCODE) { throw "Oracle directory inheritance permission failed: $path" }
            # Non-inheriting files need a direct ACE without inheritance flags.
            & icacls.exe $path /grant "*${sid}:(RX)" /T /Q | Out-Null
        } else {
            & icacls.exe $path /grant "*${sid}:(R)" /Q | Out-Null
        }
        if ($LASTEXITCODE) { throw "Oracle/redo read permission failed: $path" }
    }
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/60000
    if ($LASTEXITCODE) { throw 'Service recovery configuration failed.' }
    & sc.exe failureflag $ServiceName 1
    if ($LASTEXITCODE) { throw 'Failure exit recovery configuration failed.' }
    & sc.exe description $ServiceName 'Oracle redo CDC; preserve checkpoint and verify CDC progress separately from SCM status.'
    if ($LASTEXITCODE) { throw 'Service description configuration failed.' }
    @{service=$ServiceName;account="NT SERVICE\$ServiceName";sid=$sid;oracle_home=$OracleHome;config=$ConfigFile;read_paths=$accessPaths;log_max_bytes=$LogMaxBytes;log_keep=$LogKeep} | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $root "config/$ServiceName.installation.json")
} catch {
    & sc.exe delete $ServiceName | Out-Null
    throw
}
if ($Start) {
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(30))
}
Get-Service -Name $ServiceName
