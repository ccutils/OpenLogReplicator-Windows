[CmdletBinding()]
param([string]$SourceDirectory='vendor/librdkafka',[string]$BuildDirectory='build-deps/kafka',[string]$InstallDirectory='vendor/installed/kafka',[switch]$EnableScram,[string]$OpenSSLRoot)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$installation){throw 'Visual Studio C++ tools are required.'}
$cmake=Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$version=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
$generator=if([version]$version -ge [version]'18.0'){'Visual Studio 18 2026'}else{'Visual Studio 17 2022'}
Push-Location $root
try {
    $source=(Resolve-Path -LiteralPath $SourceDirectory).Path
    $revision=& git -C $source rev-parse HEAD
    if($LASTEXITCODE -or $revision -ne 'b4c608570f796c18ff2211a7af876046d264d392'){throw 'Expected official librdkafka v2.8.0 source commit.'}
    $prefix=[IO.Path]::GetFullPath((Join-Path $root $InstallDirectory))
    $authentication=@('-DWITH_SSL=OFF','-DWITH_SASL=OFF')
    if($EnableScram) {
        if(!$OpenSSLRoot){throw 'SCRAM requires a static OpenSSL SDK.'}
        $ssl=(Resolve-Path -LiteralPath $OpenSSLRoot).Path
        $authentication=@('-DWITH_SSL=ON','-DWITH_SASL=ON',"-DOPENSSL_ROOT_DIR=$ssl",'-DOPENSSL_USE_STATIC_LIBS=ON','-DOPENSSL_MSVC_STATIC_RT=TRUE')
    }
    & $cmake -S $source -B $BuildDirectory -G $generator -A x64 -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded '-DCMAKE_C_FLAGS=/D_WIN32_WINNT=0x0603 /DWINVER=0x0603' '-DCMAKE_CXX_FLAGS=/D_WIN32_WINNT=0x0603 /DWINVER=0x0603' -DRDKAFKA_BUILD_STATIC=ON -DRDKAFKA_BUILD_EXAMPLES=OFF -DRDKAFKA_BUILD_TESTS=OFF -DWITH_CURL=OFF -DWITH_ZLIB=OFF -DWITH_ZSTD=OFF -DENABLE_LZ4_EXT=OFF -DWITH_PLUGINS=OFF "-DCMAKE_INSTALL_PREFIX=$prefix" @authentication
    if($LASTEXITCODE){throw 'Kafka SDK configure failed.'}
    & $cmake --build $BuildDirectory --config Release --parallel
    if($LASTEXITCODE){throw 'Kafka SDK build failed.'}
    & $cmake --install $BuildDirectory --config Release
    if($LASTEXITCODE){throw 'Kafka SDK install failed.'}
} finally {Pop-Location}
