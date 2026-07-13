# OneNote batch importer for omininote.
#
# Drop .onepkg files into tools\onenote_importer\inbox\ and run:
#
#   powershell -ExecutionPolicy Bypass -File tools\onenote_importer\import_all.ps1
#
# Each .onepkg becomes one notebook (named after the file) installed into the
# local omininote store and queued for sync. Processed packages are moved to
# inbox\imported\. First run bootstraps the toolchain (fetches the parser
# source, applies the required patch, builds the extractor) — needs npm, git
# and cargo once; afterwards imports run offline.
#
# Options:
#   -InboxDir <dir>   directory holding the .onepkg files (default: .\inbox)
#   -DryRun           run the whole pipeline but skip the install step and
#                     leave the packages in the inbox (for verification)

param(
    [string]$InboxDir = "$PSScriptRoot\inbox",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$toolDir = $PSScriptRoot
$repoRoot = (Resolve-Path "$toolDir\..\..").Path
$extractorExe = "$toolDir\extractor\target\release\onenote_extractor.exe"

# cargo installs to ~\.cargo\bin, which is not always on PATH.
$env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"

function Fail($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Sanitize($name) {
    return ($name -replace '[<>:"/\\|?*]', '_').Trim()
}

# ── Bootstrap (first run only) ───────────────────────────────────────────

$parserDir = "$toolDir\.cache\package"
if (-not (Test-Path "$parserDir\parser\Cargo.toml")) {
    Write-Host "Bootstrap: fetching parser source (npm)..." -ForegroundColor Cyan
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Fail "npm not found — needed once to fetch the parser source." }
    New-Item -ItemType Directory -Force "$toolDir\.cache" | Out-Null
    Push-Location "$toolDir\.cache"
    npm pack '@joplin/onenote-converter' --silent
    if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "npm pack failed." }
    $tgz = Get-ChildItem "joplin-onenote-converter-*.tgz" | Select-Object -First 1
    tar -xzf $tgz.Name
    if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "tar extract failed." }
    Pop-Location

    Write-Host "Bootstrap: applying parser patch..." -ForegroundColor Cyan
    Push-Location $parserDir
    git apply "$toolDir\patches\parser-current-revision.patch"
    if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "parser patch failed to apply." }
    Pop-Location
}

if (-not (Test-Path $extractorExe)) {
    Write-Host "Bootstrap: building extractor (cargo, ~3 min)..." -ForegroundColor Cyan
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Fail "cargo (Rust) not found — needed once to build the extractor." }
    Push-Location "$toolDir\extractor"
    cargo build --release
    $ok = $LASTEXITCODE
    Pop-Location
    if ($ok -ne 0) { Fail "extractor build failed." }
}

# ── Collect packages ─────────────────────────────────────────────────────

if (-not (Test-Path $InboxDir)) {
    New-Item -ItemType Directory -Force $InboxDir | Out-Null
    Write-Host "Created inbox: $InboxDir"
    Write-Host "Drop your .onepkg files there and run this script again."
    exit 0
}

$packages = @(Get-ChildItem "$InboxDir\*.onepkg" -ErrorAction SilentlyContinue)
if ($packages.Count -eq 0) {
    Write-Host "No .onepkg files in $InboxDir — drop them there and run again."
    exit 0
}

# The install step must not race the app's own writes.
if (-not $DryRun) {
    $app = Get-Process omininote -ErrorAction SilentlyContinue
    if ($app) {
        Write-Host "Closing the running omininote app (installs must not race it)..." -ForegroundColor Yellow
        $app | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
}

# ── Import each package ──────────────────────────────────────────────────

$done = @()
$failed = @()

foreach ($pkg in $packages) {
    $name = [IO.Path]::GetFileNameWithoutExtension($pkg.Name)
    $safe = Sanitize $name
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $inDir = "$toolDir\input\$safe-$stamp"
    $outDir = "$toolDir\output\$safe-$stamp"
    Write-Host ""
    Write-Host ("=== " + $pkg.Name + " ===") -ForegroundColor Cyan

    try {
        New-Item -ItemType Directory -Force $inDir | Out-Null
        & "$env:SystemRoot\System32\expand.exe" $pkg.FullName -F:* $inDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "expand.exe failed (is this a valid .onepkg?)" }

        & $extractorExe $outDir $inDir
        if ($LASTEXITCODE -eq 1) { throw "extractor failed" }
        if ($LASTEXITCODE -eq 2) { Write-Host "  (some sections had parse errors — imported what parsed; see messages above)" -ForegroundColor Yellow }

        Copy-Item "$toolDir\preview\preview.html" $outDir -Force

        $convertArgs = @("run", "$toolDir\convert.dart", $outDir, "--name", $name)
        if (-not $DryRun) { $convertArgs += "--install" }
        Push-Location $repoRoot
        & dart @convertArgs
        $ok = $LASTEXITCODE
        Pop-Location
        if ($ok -ne 0) { throw "converter failed" }

        if (-not $DryRun) {
            New-Item -ItemType Directory -Force "$InboxDir\imported" | Out-Null
            Move-Item $pkg.FullName "$InboxDir\imported\" -Force
        }
        $done += $name
        Write-Host ("  OK — preview: " + $outDir + "\preview.html") -ForegroundColor Green
    } catch {
        $failed += "$name  ($($_.Exception.Message))"
        Write-Host ("  FAILED: " + $_.Exception.Message) -ForegroundColor Red
    }
}

# ── Summary ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host ("Dry run: " + $done.Count + " package(s) converted, nothing installed.")
} else {
    Write-Host ("Imported " + $done.Count + " notebook(s): " + ($done -join ', '))
}
if ($failed.Count -gt 0) {
    Write-Host ("Failed: " + ($failed -join '; ')) -ForegroundColor Red
}
if (-not $DryRun -and $done.Count -gt 0) {
    Write-Host "Processed packages moved to $InboxDir\imported"
    Write-Host "Start omininote now — it uploads the imported notebooks to Drive automatically."
}
