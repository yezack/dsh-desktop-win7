<#
.SYNOPSIS
    Health check for the Windows 7 DSH Desktop installation.

.DESCRIPTION
    Read-only. Run it any time — especially after DSH Desktop auto-updates,
    because an update replaces the executables and their PE headers revert to
    declaring Windows 10, which the Windows 7 loader refuses.

    Exit code 0 = healthy, 1 = something needs re-running install.cmd.
#>
param(
    [string]$AppDir = ''
)

$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($AppDir -eq '') {
    if (Test-Path -LiteralPath (Join-Path $Here 'app')) { $AppDir = Join-Path $Here 'app' }
    else { $AppDir = $Here }
}
$AppExe = Join-Path $AppDir 'DSH Desktop.exe'
$script:Bad = 0

function Step([string]$m) { Write-Host ''; Write-Host "=== $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red; $script:Bad++ }
function Warn([string]$m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }

Step 'Operating system'
$os = [Environment]::OSVersion.Version
Ok "Windows $($os.Major).$($os.Minor) build $($os.Build)"
if ($os.Major -ne 6 -or $os.Minor -ne 1) { Warn 'this toolkit targets Windows 7 (6.1)' }
if ($os.Build -lt 7601) { Bad 'Service Pack 1 (build 7601) is required' }

Step 'VxKex NEXT'
$kexVersion = 0
try {
    $key = Get-ItemProperty -Path 'HKLM:\Software\VXsoft\VxKex' -ErrorAction Stop
    if ($key.InstalledVersion) { $kexVersion = [int]$key.InstalledVersion }
} catch { }
if ($kexVersion -ne 0) { Ok ("installed, InstalledVersion=0x{0:X8}" -f $kexVersion) }
else { Bad 'not installed (HKLM\Software\VXsoft\VxKex missing)' }

$kexDll = Join-Path $env:SystemRoot 'System32\KexDll.dll'
if (Test-Path -LiteralPath $kexDll) { Ok 'System32\KexDll.dll present' } else { Bad 'System32\KexDll.dll missing — injection will not happen' }

Step 'Per-program opt-in'
if (-not (Test-Path -LiteralPath $AppExe)) {
    Bad "app executable not found: $AppExe"
} else {
    Ok "app executable: $AppExe"
    $ifeo = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DSH Desktop.exe"
    if (Test-Path -LiteralPath $ifeo) {
        $ifo = Get-ItemProperty -Path $ifeo
        $child = Get-ChildItem -Path $ifeo -ErrorAction SilentlyContinue
        if ($ifo.UseFilter -eq 1) { Ok 'IFEO UseFilter=1' } else { Bad 'IFEO UseFilter is not 1' }
        $verifier = $null
        foreach ($c in $child) {
            try { $p = Get-ItemProperty -Path $c.PSPath -ErrorAction Stop } catch { continue }
            if ($p.VerifierDlls) { $verifier = $p.VerifierDlls }
            if ($p.FilterFullPath) { Ok "FilterFullPath pinned to $($p.FilterFullPath)" }
        }
        if ($verifier) { Ok "VerifierDlls=$verifier" } else { Bad 'no VerifierDlls value — VxKex is not enabled for this program' }
    } else {
        Bad 'no IFEO entry — run install.cmd again'
    }
}

Step 'PE header (the Windows 7 loader gate)'
if (Test-Path -LiteralPath $AppExe) {
    $bytes = [IO.File]::ReadAllBytes($AppExe)
    $peOff = [BitConverter]::ToInt32($bytes, 0x3C)
    $magic = [BitConverter]::ToUInt16($bytes, $peOff + 24)
    if ($magic -ne 0x10B -and $magic -ne 0x20B) {
        Bad 'unrecognised PE optional header'
    } else {
        $opt = $peOff + 24
        $osMajor = [BitConverter]::ToUInt16($bytes, $opt + 40)
        $osMinor = [BitConverter]::ToUInt16($bytes, $opt + 42)
        $subMajor = [BitConverter]::ToUInt16($bytes, $opt + 48)
        $subMinor = [BitConverter]::ToUInt16($bytes, $opt + 50)
        if ($osMajor -gt 6) {
            Bad "declares OS $osMajor.$osMinor (subsystem $subMajor.$subMinor) — Windows 7 will refuse to load it."
            Write-Host '        This is what a DSH Desktop auto-update looks like. Re-run install.cmd.' -ForegroundColor Yellow
        } else {
            Ok "declares OS $osMajor.$osMinor, subsystem $subMajor.$subMinor"
        }
    }
} else {
    Bad 'cannot read the app executable'
}

Step 'Electron runtime self test'
if (Test-Path -LiteralPath $AppExe) {
    $previous = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE')
    [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', '1')
    $out = & $AppExe '--version' 2>&1
    $code = $LASTEXITCODE
    [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $previous)
    $text = ($out | Out-String).Trim()
    if ($code -eq 0 -and $text -match '^v\d+\.') { Ok "node $text" }
    else { Bad "runtime self test failed (exit $code): $text" }
}

Step 'Result'
if ($script:Bad -eq 0) {
    Write-Host '  Healthy.' -ForegroundColor Green
    exit 0
}
Write-Host "  $($script:Bad) problem(s) found. Re-run install.cmd if the PE header or VxKex entry is the cause." -ForegroundColor Red
exit 1
