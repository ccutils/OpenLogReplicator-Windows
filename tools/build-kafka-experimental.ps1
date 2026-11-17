[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OracleSdk,
    [Parameter(Mandatory=$true)][string]$RapidJson,
    [Parameter(Mandatory=$true)][string]$RdKafka,
    [string]$BuildDirectory='build-kafka',
    [string]$OpenSSLRoot
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if ([IO.Path]::GetFullPath((Join-Path $root $BuildDirectory)) -eq [IO.Path]::GetFullPath((Join-Path $root 'build'))) { throw 'Use a separate experimental build directory.' }
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$installation){throw 'Visual Studio C++ tools are required.'}
$cmake=Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$version=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
$generator=if([version]$version -ge [version]'18.0'){'Visual Studio 18 2026'}else{'Visual Studio 17 2022'}
Push-Location $root
try {
    $sslOptions=@()
    if($OpenSSLRoot){$sslOptions=@("-DOPENSSL_ROOT_DIR=$OpenSSLRoot",'-DOPENSSL_USE_STATIC_LIBS=ON','-DOPENSSL_MSVC_STATIC_RT=TRUE')}
    & $cmake -S . -B $BuildDirectory -G $generator -A x64 "-DWITH_OCI=$OracleSdk" "-DWITH_RAPIDJSON=$RapidJson" "-DWITH_RDKAFKA=$RdKafka" -DOLR_WINDOWS_EXPERIMENTAL_CONNECTORS=ON -DWITH_PROTOBUF=OFF -DWITH_ZEROMQ=OFF -DWITH_PROMETHEUS=OFF @sslOptions
    if($LASTEXITCODE){throw 'Experimental Kafka configure failed.'}
    & $cmake --build $BuildDirectory --config Release --parallel
    if($LASTEXITCODE){throw 'Experimental Kafka build failed.'}
    & (Join-Path (Split-Path $cmake) 'ctest.exe') --test-dir $BuildDirectory -C Release --output-on-failure
    if($LASTEXITCODE){throw 'Adapter regression failed.'}
} finally {Pop-Location}
