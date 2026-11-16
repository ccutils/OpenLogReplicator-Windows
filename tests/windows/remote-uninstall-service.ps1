. 'C:\OLR-Windows-validation-20261116\scripts\validation-common.ps1'
$name='OLRWindowsValidation'
Stop-Service $name
$controller=Get-Service $name
$controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))
$controller.Dispose()
$files=@(Get-ChildItem "$ValidationRoot\checkpoint\*.json")+@(Get-ChildItem "$ValidationRoot\logs\cdc-*.json")+@(Get-Item "$ValidationRoot\config\validation.local.json")
$before=@{}
foreach($file in $files){$before[$file.FullName]=(Get-FileHash $file.FullName).Hash}
& "$ValidationRoot\scripts\uninstall-service.ps1" -ServiceName $name
if($LASTEXITCODE){throw 'Uninstall script failed'}
Assert-Validation ($null -eq (Get-CimInstance Win32_Service -Filter "Name='$name'")) 'service uninstalled'
foreach($path in $before.Keys) {
    if(!(Test-Path -LiteralPath $path) -or (Get-FileHash $path).Hash -ne $before[$path]) {throw "Uninstall changed persistent data: $path"}
}
Assert-Validation $true 'uninstall preserved all captured config, CDC and checkpoint file hashes'
@{stage='service-uninstall';passed=$true;preserved_files=$files.Count} | ConvertTo-Json | Set-Content "$ValidationRoot\test-results\uninstall-summary.json"
