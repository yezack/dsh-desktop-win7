<#
.SYNOPSIS
    Build a Windows 7 portable package for DSH Desktop.

.DESCRIPTION
    Downloads the official DSH Desktop installer and the VxKex NEXT installer,
    extracts both, applies the PE downlevel patch to the x64 binaries, then
    assembles a self-contained portable folder and zips it.

    Nothing is rebuilt: the compatibility fix is a 4-field edit of the COFF
    optional header (declared OS/subsystem version 10.0 -> 6.1) plus the VxKex
    API extension layer, which is installed on the target machine.

.EXAMPLE
    pwsh -File scripts/build-portable.ps1 -DshVersion 2.0.10

.EXAMPLE
    # reuse an installer that was already downloaded
    pwsh -File scripts/build-portable.ps1 -InstallerPath C:\cache\dsh-setup.exe

.NOTES
    Requires: Python 3 (stdlib only), 7-Zip (7z.exe or 7zr.exe; auto-downloaded).
#>
[CmdletBinding()]
param(
    [string]$DshVersion = '2.0.10',
    [string]$DshRepo = 'anywhere-labs/deepseek-harness-desktop',
    [string]$VxKexRepo = 'YuZhouRen86/VxKex-NEXT',
    [string]$VxKexTag = '',
    [string]$InstallerPath = '',
    [string]$OutDir = 'dist',
    [string]$WorkDir = 'build',
    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $RepoRoot $OutDir }
$WorkDir = if ([IO.Path]::IsPathRooted($WorkDir)) { $WorkDir } else { Join-Path $RepoRoot $WorkDir }
$PackageName = "DSH-Desktop-$DshVersion-Win7"

function Write-Step([string]$Message) { Write-Host "`n=== $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Warn2([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }

function Invoke-Download {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile)
    if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
        $existing = (Get-Item -LiteralPath $OutFile).Length
        if ($existing -gt 0) { Write-Ok "reusing $(Split-Path -Leaf $OutFile) ($([math]::Round($existing/1MB,1)) MB)"; return }
    }
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Host "  downloading $Uri"
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
            Write-Ok "$(Split-Path -Leaf $OutFile) ($([math]::Round((Get-Item -LiteralPath $OutFile).Length/1MB,1)) MB)"
            return
        } catch {
            if ($attempt -ge 4) { throw "download failed after $attempt attempts: $Uri`n$($_.Exception.Message)" }
            Write-Warn2 "attempt $attempt failed: $($_.Exception.Message) — retrying in 5s"
            Start-Sleep -Seconds 5
        }
    }
}

function Resolve-7Zip {
    $candidates = @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $local = Join-Path $WorkDir '7zr.exe'
    Invoke-Download -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $local
    return $local
}

function Get-GitHubReleaseAsset {
    param([Parameter(Mandatory)][string]$Repo, [string]$Tag = '', [Parameter(Mandatory)][string]$Pattern)
    $api = if ($Tag) { "https://api.github.com/repos/$Repo/releases/tags/$Tag" } else { "https://api.github.com/repos/$Repo/releases/latest" }
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'dsh-desktop-win7-build' }
    $asset = $release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "no asset matching '$Pattern' in $Repo release '$($release.tag_name)'" }
    return [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url; Tag = $release.tag_name }
}

function Invoke-Python {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) { throw 'python 3 not found on PATH (required for the PE patch tooling)' }
    & $python.Source @Arguments
    if ($LASTEXITCODE -ne 0) { throw "python exited with ${LASTEXITCODE}: $($Arguments -join ' ')" }
}

# ---------------------------------------------------------------- workspace
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$AppWork = Join-Path $WorkDir 'app'
$VxKexWork = Join-Path $WorkDir 'vxkex'
foreach ($d in @($AppWork, $VxKexWork)) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

Write-Step 'Resolve tooling'
$sevenZip = Resolve-7Zip
Write-Ok "7-Zip: $sevenZip"
Invoke-Python -Arguments @('--version')

# ------------------------------------------------------------ dsh installer
Write-Step "Fetch DSH Desktop $DshVersion"
if ($InstallerPath) {
    if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "installer not found: $InstallerPath" }
    $installer = $InstallerPath
    Write-Ok "using local installer $installer"
} else {
    $asset = Get-GitHubReleaseAsset -Repo $DshRepo -Tag "v$DshVersion" -Pattern '*x64-Setup.exe'
    $installer = Join-Path $WorkDir $asset.Name
    Invoke-Download -Uri $asset.Url -OutFile $installer
}

Write-Step 'Extract DSH Desktop (NSIS payload)'
& $sevenZip x $installer "-o$AppWork" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed for $installer" }
$appExe = Join-Path $AppWork 'DSH Desktop.exe'
if (-not (Test-Path -LiteralPath $appExe)) {
    throw "unexpected payload layout: '$appExe' not found. Check 7-Zip output in $AppWork"
}
Write-Ok "payload extracted to $AppWork"

# ------------------------------------------------------------------ vxkex
Write-Step 'Fetch VxKex NEXT'
$vxkexAsset = Get-GitHubReleaseAsset -Repo $VxKexRepo -Tag $VxKexTag -Pattern 'KexSetup_Release_*.exe'
$vxkexInstaller = Join-Path $WorkDir $vxkexAsset.Name
Invoke-Download -Uri $vxkexAsset.Url -OutFile $vxkexInstaller

Write-Step 'Extract VxKex NEXT'
& $sevenZip x $vxkexInstaller "-o$VxKexWork" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed for $vxkexInstaller" }
foreach ($required in @('KexSetup.exe', 'Core64\KexCfg.exe', 'Kex64\KxBase.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $VxKexWork $required))) { throw "VxKex payload missing '$required'" }
}
Write-Ok "VxKex $($vxkexAsset.Tag) extracted to $VxKexWork"

# ------------------------------------------------------------------ patch
Write-Step 'Apply PE downlevel patch (declared OS/subsystem version -> 6.1)'
$patchTool = Join-Path $RepoRoot 'tools\pe_downlevel.py'
Invoke-Python -Arguments @($patchTool, 'patchdir', $AppWork, '6', '1')

Write-Step 'Verify: no top-level image declares an OS version above 6.1'
$offenders = @()
Get-ChildItem -LiteralPath $AppWork -File | Where-Object { $_.Extension -in '.exe', '.dll', '.node' } | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    # cheap inline check so we do not depend on python output parsing
    if ($bytes.Length -gt 0x40 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {
        $peOff = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($peOff + 0x40 -lt $bytes.Length) {
            $magic = [BitConverter]::ToUInt16($bytes, $peOff + 24)
            if ($magic -eq 0x10B -or $magic -eq 0x20B) {
                $opt = $peOff + 24
                $osMajor = [BitConverter]::ToUInt16($bytes, $opt + 40)
                $osMinor = [BitConverter]::ToUInt16($bytes, $opt + 42)
                if ($osMajor -gt 6 -or ($osMajor -eq 6 -and $osMinor -gt 1)) {
                    $offenders += "$($_.Name) declares OS $osMajor.$osMinor"
                }
            }
        }
    }
}
if ($offenders.Count -gt 0) {
    $offenders | ForEach-Object { Write-Warn2 $_ }
    throw "PE downlevel patch did not cover every top-level image ($($offenders.Count) offender(s))"
}
Write-Ok 'all top-level images now declare OS 6.1'

# ---------------------------------------------------------------- assemble
Write-Step "Assemble $PackageName"
$stage = Join-Path $OutDir $PackageName
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Move-Item -LiteralPath $AppWork -Destination (Join-Path $stage 'app')
Move-Item -LiteralPath $VxKexWork -Destination (Join-Path $stage 'vxkex')
foreach ($file in @('install.cmd', 'install-portable.ps1', 'verify-win7.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stage -Force
}
Copy-Item -LiteralPath (Join-Path $RepoRoot 'NOTICE') -Destination (Join-Path $stage 'NOTICE.txt') -Force

$readmeSrc = Join-Path $RepoRoot 'docs\portable-readme.txt'
if (Test-Path -LiteralPath $readmeSrc) {
    $readme = Get-Content -LiteralPath $readmeSrc -Raw
    $readme = $readme.Replace('{{VERSION}}', $DshVersion).Replace('{{VXKEX}}', $vxkexAsset.Tag)
    Set-Content -LiteralPath (Join-Path $stage 'README-Win7.txt') -Value $readme -Encoding UTF8
}
Write-Ok "staged at $stage"

# ---------------------------------------------------------------- compress
Write-Step 'Compress'
$zipPath = Join-Path $OutDir "$PackageName-portable.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Ok "$zipPath ($([math]::Round((Get-Item -LiteralPath $zipPath).Length/1MB,1)) MB)"

if (-not $KeepWork) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nDone. Release asset: $zipPath" -ForegroundColor Green
