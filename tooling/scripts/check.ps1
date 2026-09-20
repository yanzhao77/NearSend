#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the NearSend required checks: format, analyze, test.

.DESCRIPTION
    Implements the mandatory checks from AGENTS.md §7 in a fixed order. Each step
    streams its own output and the script stops at the first failure with a
    non-zero exit code, so a failing check can never be mistaken for a pass.

.PARAMETER SkipFormat
    Skip the `dart format` verification step.

.PARAMETER SkipAnalyze
    Skip the `flutter analyze` step.

.PARAMETER SkipTest
    Skip the `flutter test` step.
#>
[CmdletBinding()]
param(
    [switch]$SkipFormat,
    [switch]$SkipAnalyze,
    [switch]$SkipTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Write-Host ''
    Write-Host "===== $Name =====" -ForegroundColor Cyan
    Write-Host "> $Command $($Arguments -join ' ')" -ForegroundColor DarkGray

    & $Command @Arguments
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Write-Host "$Name FAILED (exit $code)" -ForegroundColor Red
        exit $code
    }

    Write-Host "$Name OK" -ForegroundColor Green
}

if (-not (Test-Path (Join-Path $repoRoot 'pubspec.yaml'))) {
    throw "pubspec.yaml not found in $repoRoot; run this script from the NearSend repository."
}

Push-Location $repoRoot
try {
    # Resolve dependencies from the committed pubspec.lock first, so analyze and
    # test run against a fixed resolution (AGENTS.md §3 依赖锁定).
    Invoke-Step -Name 'flutter pub get' -Command 'flutter' -Arguments @('pub', 'get')

    if (-not $SkipFormat) {
        Invoke-Step -Name 'dart format (check only)' -Command 'dart' `
            -Arguments @('format', '--output=none', '--set-exit-if-changed', '.')
    }

    if (-not $SkipAnalyze) {
        Invoke-Step -Name 'flutter analyze' -Command 'flutter' `
            -Arguments @('analyze', '--no-pub')
    }

    if (-not $SkipTest) {
        Invoke-Step -Name 'flutter test' -Command 'flutter' `
            -Arguments @('test', '--no-pub')
    }

    Write-Host ''
    Write-Host 'All requested checks passed.' -ForegroundColor Green
}
finally {
    Pop-Location
}
