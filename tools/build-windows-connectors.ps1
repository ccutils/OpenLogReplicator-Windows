[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OracleSdk,
    [Parameter(Mandatory=$true)][string]$RapidJson,
    [Parameter(Mandatory=$true)][string]$RdKafka,
    [Parameter(Mandatory=$true)][string]$OpenSSLRoot,
    [Parameter(Mandatory=$true)][string]$Protobuf,
    [Parameter(Mandatory=$true)][string]$ZeroMQ,
    [string]$BuildDirectory='build-connectors',
    [string]$OutputDirectory='dist/OpenLogReplicator-Windows-connectors'
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vs){throw 'Visual Studio C++ tools are required.'}
$version=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
$generator=if([version]$version -ge [version]'18.0'){'Visual Studio 18 2026'}else{'Visual Studio 17 2022'}
$cmake=Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
Push-Location $root
try {
    & scripts/verify-upstream-core.ps1
    & $cmake -S . -B $BuildDirectory -G $generator -A x64 "-DWITH_OCI=$OracleSdk" "-DWITH_RAPIDJSON=$RapidJson" "-DWITH_RDKAFKA=$RdKafka" "-DWITH_PROTOBUF=$Protobuf" "-DWITH_ZEROMQ=$ZeroMQ" "-DOPENSSL_ROOT_DIR=$OpenSSLRoot" -DOPENSSL_USE_STATIC_LIBS=ON -DOPENSSL_MSVC_STATIC_RT=TRUE -DOLR_WINDOWS_EXPERIMENTAL_CONNECTORS=ON -DWITH_PROMETHEUS=OFF
    if($LASTEXITCODE){throw 'Connectors configure failed'}
    & $cmake --build $BuildDirectory --config Release --parallel 4
    if($LASTEXITCODE){throw 'Connectors build failed'}
    & (Join-Path (Split-Path $cmake) 'ctest.exe') --test-dir $BuildDirectory -C Release --output-on-failure
    if($LASTEXITCODE){throw 'Windows contract tests failed'}
    & $cmake --install $BuildDirectory --config Release --prefix $OutputDirectory
    if($LASTEXITCODE){throw 'Connectors install failed'}
} finally {Pop-Location}
