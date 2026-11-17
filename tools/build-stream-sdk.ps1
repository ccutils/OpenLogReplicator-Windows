[CmdletBinding()]
param()
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
    foreach($dependency in @('protobuf','libzmq')) {
        $expected=if($dependency -eq 'protobuf'){'f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c'}else{'622fc6dde99ee172ebaa9c8628d85a7a1995a21d'}
        $revision=& git -C "vendor/$dependency" rev-parse HEAD
        if($LASTEXITCODE -or $revision -ne $expected){throw "Unexpected $dependency source revision"}
        $options=if($dependency -eq 'protobuf') {
            @('-Dprotobuf_BUILD_TESTS=OFF','-Dprotobuf_BUILD_SHARED_LIBS=OFF','-Dprotobuf_MSVC_STATIC_RUNTIME=ON','-Dprotobuf_WITH_ZLIB=OFF','-Dprotobuf_BUILD_PROTOC_BINARIES=ON')
        }else{
            # libzmq calls project() before cmake_minimum_required(): also set the
            # legacy CRT flags so its OLD CMP0091 scope cannot select /MD.
            @('-DBUILD_SHARED=OFF','-DBUILD_STATIC=ON','-DBUILD_TESTS=OFF','-DWITH_DOCS=OFF','-DENABLE_CURVE=OFF','-DENABLE_DRAFTS=OFF','-DENABLE_WS=OFF','-DWITH_LIBSODIUM=OFF',
              '-DZMQ_WIN32_WINNT=0x0603','-DPOLLER=select','-DZMQ_HAVE_IPC=OFF',
              '-DCMAKE_CXX_FLAGS_RELEASE=/MT /O2 /Ob2 /DNDEBUG','-DCMAKE_C_FLAGS_RELEASE=/MT /O2 /Ob2 /DNDEBUG')
        }
        & $cmake -S "vendor/$dependency" -B "build-deps/$dependency" -G $generator -A x64 '-DCMAKE_POLICY_VERSION_MINIMUM=3.5' -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded '-DCMAKE_CXX_FLAGS=/MP4 /D_WIN32_WINNT=0x0603 /DWINVER=0x0603' "-DCMAKE_INSTALL_PREFIX=$root/vendor/installed/$dependency" @options
        if($LASTEXITCODE){throw "$dependency configure failed"}
        & $cmake --build "build-deps/$dependency" --config Release --parallel 8
        if($LASTEXITCODE){throw "$dependency build failed"}
        & $cmake --install "build-deps/$dependency" --config Release
        if($LASTEXITCODE){throw "$dependency install failed"}
    }
}finally{Pop-Location}
