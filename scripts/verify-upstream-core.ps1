[CmdletBinding()]
param([string]$Base = 'v1.9.0')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $protected=@('src/parser','src/builder','src/locales','src/common/RedoLogRecord.h','src/common/types')
    $allowed=@('src/common/types/Types.h') # platform memory header inclusion only
    $changed=@(& git diff --name-only $Base -- $protected)
    if ($LASTEXITCODE) { throw 'Cannot compare the official baseline' }
    $added=@(& git ls-files --others --exclude-standard -- $protected)
    if ($LASTEXITCODE) { throw 'Cannot inspect untracked core files' }
    $violations=@($changed + $added | Where-Object { $_ -and $_ -notin $allowed })
    if ($violations.Count) { throw "Protected upstream core changed: $($violations -join ', ')" }
    Write-Output 'PASS: parser, opcodes, builders, character decoders, redo records and data arithmetic match official v1.9.0.'
    if ($changed -contains 'src/common/types/Types.h') {
        $diff=@(& git diff --unified=0 $Base -- src/common/types/Types.h)
        $lines=@($diff | Where-Object { $_ -match '^[+-]' -and $_ -notmatch '^(---|\+\+\+)' })
        if ($lines.Count -ne 1 -or $lines[0] -ne '+#include "../../platform/Memory.h"') { throw 'Unexpected Types.h change' }
    }
} finally { Pop-Location }
