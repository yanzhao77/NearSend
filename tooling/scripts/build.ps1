#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a NearSend target and stamps the artifact with its source revision.

.DESCRIPTION
    Builds the requested platform with the Git revision injected through
    --dart-define, so an installed build can always be traced back to a commit
    (技术方案 V2.1 §17.3). The Git commit is read from the working tree at build
    time; when the tree is dirty that fact is recorded in the artifact too,
    rather than being hidden.

.PARAMETER Target
    One of: android, windows, ios.

.PARAMETER Release
    Build in release mode. Defaults to debug. Note that an Android release build
    without android/key.properties is signed with the debug key and is NOT a
    distribution artifact; release signing belongs to T10.

.PARAMETER EvidenceDir
    When provided, artifact paths and SHA-256 digests are written to
    <EvidenceDir>/artifacts-sha256.json in addition to being printed.

.PARAMETER BuildChannel
    Value stamped into the artifact as NS_BUILD_CHANNEL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('android', 'windows', 'ios')][string]$Target,
    [switch]$Release,
    [string]$EvidenceDir,
    [string]$BuildChannel = 'local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if (-not (Test-Path (Join-Path $repoRoot 'pubspec.yaml'))) {
    throw "pubspec.yaml not found in $repoRoot; run this script from the NearSend repository."
}

# An iOS build needs Xcode. Detect it by its toolchain rather than by guessing at
# the OS name, and fail loudly instead of silently producing nothing.
$xcodebuild = Get-Command xcodebuild -ErrorAction SilentlyContinue
if ($Target -eq 'ios' -and -not $xcodebuild) {
    throw "Target 'ios' requires macOS with Xcode (xcodebuild was not found). " +
          'iOS integration is tracked as B06/T09 in docs/PROJECT_LEDGER.md and is blocked on Apple hardware.'
}

function Get-GitStamp {
    Push-Location $repoRoot
    try {
        $sha = (& git rev-parse HEAD | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
            throw 'git rev-parse HEAD failed; refusing to build without a source revision.'
        }

        # Evidence logs are rewritten by the very run doing the building, so counting
        # them would mark every recorded build as dirty and make the stamp useless for
        # release traceability. Source and configuration still count.
        $statusLines = @(& git status --porcelain) |
            Where-Object { $_ -notmatch 'docs/testing/evidence/' }
        $dirty = if ($statusLines.Count -eq 0) { 'false' } else { 'true' }

        return [pscustomobject]@{ Sha = $sha; Dirty = $dirty }
    }
    finally {
        Pop-Location
    }
}

$mode = if ($Release) { 'release' } else { 'debug' }
$stamp = Get-GitStamp

$defines = @(
    "--dart-define=NS_GIT_SHA=$($stamp.Sha)",
    "--dart-define=NS_GIT_DIRTY=$($stamp.Dirty)",
    "--dart-define=NS_BUILD_CHANNEL=$BuildChannel"
)

Write-Host ''
Write-Host "Target      : $Target ($mode)" -ForegroundColor Cyan
Write-Host "Git commit  : $($stamp.Sha) (dirty=$($stamp.Dirty))"
Write-Host "Channel     : $BuildChannel"
Write-Host ''

Push-Location $repoRoot
try {
    $buildArgs = switch ($Target) {
        'android' { @('build', 'apk') }
        'windows' { @('build', 'windows') }
        'ios' { @('build', 'ios', '--no-codesign') }
    }

    if ($Release) { $buildArgs += '--release' } else { $buildArgs += '--debug' }
    $buildArgs += $defines

    Write-Host "> flutter $($buildArgs -join ' ')" -ForegroundColor DarkGray
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "flutter build failed (exit $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    # Artifact discovery. PowerShell 5.1 does not support '**' globs, so each
    # target names a search root plus a filter and recurses.
    $search = switch ($Target) {
        'android' { @{ Root = 'build\app\outputs\flutter-apk'; Filter = '*.apk' } }
        'windows' { @{ Root = 'build\windows'; Filter = '*.exe' } }
        'ios' { @{ Root = 'build\ios'; Filter = '*.app' } }
    }

    $searchRoot = Join-Path $repoRoot $search.Root
    $artifacts = @()
    if (Test-Path $searchRoot) {
        $artifacts = @(Get-ChildItem -Path $searchRoot -Filter $search.Filter -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Where-Object { $_.FullName -notmatch '\\CMakeFiles\\' })
    }

    # Android keeps debug and release APKs side by side in one directory, so the
    # search alone would attribute both files to whichever mode was just built.
    # Restrict the record to the artifact this invocation actually produced.
    if ($Target -eq 'android') {
        $expectedSuffix = if ($Release) { '-release.apk' } else { '-debug.apk' }
        $artifacts = @($artifacts | Where-Object { $_.Name.EndsWith($expectedSuffix) })
    }

    Write-Host ''
    Write-Host '===== artifacts =====' -ForegroundColor Cyan

    if ($artifacts.Count -eq 0) {
        if ($Target -eq 'ios') {
            Write-Host 'No .app bundle matched under build/ios. iOS packaging, signing and' -ForegroundColor Yellow
            Write-Host 'archiving are owned by T10 and require macOS with Xcode and signing material.' -ForegroundColor Yellow
        }
        else {
            throw "Build reported success but no artifact matched $($search.Root)\$($search.Filter)"
        }
    }

    $records = @()
    foreach ($artifact in $artifacts) {
        $hash = (Get-FileHash -Path $artifact.FullName -Algorithm SHA256).Hash
        $relative = $artifact.FullName.Substring($repoRoot.Length).TrimStart('\')
        Write-Host $relative
        Write-Host "  bytes  : $($artifact.Length)"
        Write-Host "  sha256 : $hash"

        $records += [pscustomobject]@{
            path         = $relative.Replace('\', '/')
            bytes        = $artifact.Length
            sha256       = $hash
            target       = $Target
            mode         = $mode
            gitSha       = $stamp.Sha
            gitDirty     = $stamp.Dirty
            buildChannel = $BuildChannel
        }
    }

    if ($EvidenceDir -and $records.Count -gt 0) {
        $evidencePath = Join-Path $repoRoot $EvidenceDir
        if (-not (Test-Path $evidencePath)) {
            New-Item -ItemType Directory -Force -Path $evidencePath | Out-Null
        }
        $outFile = Join-Path $evidencePath 'artifacts-sha256.json'

        # Merge with any records written by an earlier invocation in this run, so
        # that building several targets accumulates one evidence file instead of
        # each build overwriting the previous target's digests.
        $merged = @()
        if (Test-Path $outFile) {
            try {
                $existing = Get-Content -Path $outFile -Raw | ConvertFrom-Json
                foreach ($entry in @($existing)) {
                    if ($null -eq $entry) { continue }
                    if ($entry.PSObject.Properties.Name -contains 'path') {
                        $merged += $entry
                    }
                }
            }
            catch {
                Write-Host "Existing $outFile could not be parsed; rewriting it." -ForegroundColor Yellow
                $merged = @()
            }
        }

        $byPath = @{}
        foreach ($record in $merged) { $byPath[[string]$record.path] = $record }
        foreach ($record in $records) { $byPath[$record.path] = $record }

        $sorted = @($byPath.Values | Sort-Object -Property path)

        # -InputObject (not the pipeline): piping a collection into ConvertTo-Json
        # in Windows PowerShell 5.1 emits {"value":[...],"Count":n} instead of a
        # JSON array.
        $json = ConvertTo-Json -InputObject $sorted -Depth 5
        Set-Content -Path $outFile -Value $json -Encoding UTF8

        Write-Host ''
        Write-Host "Wrote $outFile ($($sorted.Count) artifact record(s))" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
