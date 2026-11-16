[CmdletBinding()]
param([ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$ServiceName='OpenLogReplicator')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $root 'bin/OpenLogReplicator.exe'
$service=Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
if (!$service) { Write-Output "Service $ServiceName is not installed."; exit 0 }
$quoted=$service.PathName.StartsWith('"'+$exe+'" ',[StringComparison]::OrdinalIgnoreCase)
$legacy=$exe.IndexOf(' ') -lt 0 -and $service.PathName.StartsWith($exe+' ',[StringComparison]::OrdinalIgnoreCase)
if (!$quoted -and !$legacy) { throw 'Refusing to uninstall a service belonging to a different installation.' }
$controller=Get-Service -Name $ServiceName
if ($controller.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName
    $controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(120))
}
$controller.Dispose()
& sc.exe delete $ServiceName
if ($LASTEXITCODE) { throw 'Service removal failed.' }
Write-Output 'Service removed. Configuration, CDC files, diagnostic logs and checkpoint were preserved. Explicit service-account ACL entries remain for reinstall.'
