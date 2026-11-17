[CmdletBinding()]
param(
    [string]$SourceDirectory='vendor/openssl',
    [string]$BuildDirectory='build-deps/openssl',
    [string]$InstallDirectory='vendor/installed/openssl',
    [string]$Perl='vendor/perl-native/perl/bin/perl.exe'
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $source=(Resolve-Path -LiteralPath $SourceDirectory).Path
    $perlPath=(Resolve-Path -LiteralPath $Perl).Path
    $revision=& git -C $source rev-parse HEAD
    if($LASTEXITCODE -or $revision -ne '45e844fa2a14ec92d146bd8f5778ac130b6625fb'){throw 'Expected official OpenSSL 3.5.9 source commit.'}
    $prefix=[IO.Path]::GetFullPath((Join-Path $root $InstallDirectory))
    $build=[IO.Path]::GetFullPath((Join-Path $root $BuildDirectory))
    New-Item -ItemType Directory -Force $build | Out-Null
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if(!$vs){throw 'Visual Studio C++ tools are required.'}
    $batch=@"
@echo off
set "LC_ALL=C"
call "$vs\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
set "PATH=$root\vendor\perl-native\c\bin;%PATH%"
"$perlPath" "$source\Configure" VC-WIN64A no-shared no-tests no-asm no-apps no-module no-makedepend -D_WIN32_WINNT=0x0603 -DWINVER=0x0603 --prefix="$prefix" --openssldir="$prefix\ssl" --libdir=lib
if errorlevel 1 exit /b 1
nmake /NOLOGO build_libs
if errorlevel 1 exit /b 1
nmake /NOLOGO install_sw
exit /b %errorlevel%
"@
    $file=Join-Path $build 'build-sdk.cmd'
    [IO.File]::WriteAllText($file,$batch,[Text.Encoding]::ASCII)
    Push-Location $build
    try { & $env:ComSpec /d /c $file; if($LASTEXITCODE){throw 'OpenSSL SDK build failed.'} }
    finally {Pop-Location}
} finally {Pop-Location}
