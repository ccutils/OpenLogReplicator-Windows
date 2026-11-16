[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OracleSdk,
    [Parameter(Mandatory=$true)][string]$RapidJson,
    [string]$BuildDirectory = 'build',
    [string]$OutputDirectory = 'dist/OpenLogReplicator-Windows'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'Install Visual Studio with Desktop development with C++ and CMake.' }
$cmake = Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$version = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
$generator = if ([version]$version -ge [version]'18.0') { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
foreach ($file in @((Join-Path $OracleSdk 'sdk/include/oci.h'),(Join-Path $OracleSdk 'sdk/lib/msvc/oci.lib'),(Join-Path $RapidJson 'include/rapidjson/document.h'))) {
    if (!(Test-Path -LiteralPath $file)) { throw "Missing dependency: $file" }
}
Push-Location $root
try {
    & $cmake -S . -B $BuildDirectory -G $generator -A x64 "-DWITH_OCI=$OracleSdk" "-DWITH_RAPIDJSON=$RapidJson" -DWITH_PROTOBUF=OFF -DWITH_ZEROMQ=OFF -DWITH_RDKAFKA=OFF -DWITH_PROMETHEUS=OFF
    if ($LASTEXITCODE) { throw 'CMake configure failed' }
    & $cmake --build $BuildDirectory --config Release --parallel
    if ($LASTEXITCODE) { throw 'Build failed' }
    & (Join-Path (Split-Path $cmake) 'ctest.exe') --test-dir $BuildDirectory -C Release --output-on-failure
    if ($LASTEXITCODE) { throw 'OS adapter contract tests failed' }
    & $cmake --install $BuildDirectory --config Release --prefix $OutputDirectory
    if ($LASTEXITCODE) { throw 'Package creation failed' }
} finally { Pop-Location }
