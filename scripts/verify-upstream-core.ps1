[CmdletBinding()]
param([string]$Base = 'v1.9.0')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $protected=@('src/parser','src/builder','src/locales','src/common/RedoLogRecord.h','src/common/types')
    $allowed=@('src/common/types/Types.h','src/builder/BuilderProtobuf.cpp')
    $changed=@(& git diff --name-only $Base -- $protected)
    if ($LASTEXITCODE) { throw 'Cannot compare the official baseline' }
    $added=@(& git ls-files --others --exclude-standard -- $protected)
    if ($LASTEXITCODE) { throw 'Cannot inspect untracked core files' }
    $violations=@($changed + $added | Where-Object { $_ -and $_ -notin $allowed })
    if ($violations.Count) { throw "Protected upstream core changed: $($violations -join ', ')" }
    if ($changed -contains 'src/common/types/Types.h') {
        $diff=@(& git diff --unified=0 $Base -- src/common/types/Types.h)
        $lines=@($diff | Where-Object { $_ -match '^[+-]' -and $_ -notmatch '^(---|\+\+\+)' })
        if ($lines.Count -ne 1 -or $lines[0] -ne '+#include "../../platform/Memory.h"') { throw 'Unexpected Types.h change' }
    }
    if ($changed -contains 'src/builder/BuilderProtobuf.cpp') {
        $diff=@(& git diff --unified=0 $Base -- src/builder/BuilderProtobuf.cpp)
        $lines=@($diff | Where-Object { $_ -match '^[+-]' -and $_ -notmatch '^(---|\+\+\+)' })
        $expected=@('-            const int64_t value = strtol(valueBuffer, &retPtr, 10);','+            const int64_t value = strtoll(valueBuffer, &retPtr, 10);')
        if (($lines -join "`n") -cne ($expected -join "`n")) { throw 'Unexpected Protobuf builder change beyond LLP64 integer conversion' }
    }
    Write-Output 'PASS: upstream Redo parser/opcodes/transactions/decoders/data arithmetic unchanged; only approved platform includes and Protobuf LLP64 strtoll conversion differ.'
} finally { Pop-Location }
