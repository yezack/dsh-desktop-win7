<#
.SYNOPSIS
    One-click installer: make the bundled DSH Desktop run on Windows 7.

.DESCRIPTION
    1. checks the Windows 7 prerequisites
    2. installs the VxKex NEXT API extension layer (silent, admin required)
    3. enables VxKex for the bundled "DSH Desktop.exe" with Windows 10 version spoofing
    4. self-tests the Electron runtime
    5. creates a desktop shortcut

    Written for Windows PowerShell 2.0 so it runs on a stock Windows 7.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install-portable.ps1

.EXAMPLE
    # keep the portable folder somewhere else
    powershell -NoProfile -ExecutionPolicy Bypass -File install-portable.ps1 -AppDir D:\tools\dsh\app
#>
param(
    [string]$AppDir = '',
    [string]$VxKexDir = '',
    [string]$KexDir = 'C:\Program Files\VxKex',
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$script:Problems = @()

function Say([string]$Message) { Write-Host $Message }
function Step([string]$Message) { Write-Host ''; Write-Host "=== $Message" -ForegroundColor Cyan }
function Ok([string]$Message) { Write-Host "  [ok] $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow; $script:Problems += $Message }
function Fail([string]$Message) { Write-Host "  [FAIL] $Message" -ForegroundColor Red; $script:Problems += $Message }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($AppDir -eq '') { $AppDir = Join-Path $Here 'app' }
if ($VxKexDir -eq '') { $VxKexDir = Join-Path $Here 'vxkex' }

$AppExe = Join-Path $AppDir 'DSH Desktop.exe'
$KexSetup = Join-Path $VxKexDir 'KexSetup.exe'
$KexCfg = Join-Path $VxKexDir 'Core64\KexCfg.exe'

Step 'Checking prerequisites'

# --- administrator -----------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'must run elevated. Right-click install.cmd -> Run as administrator.'
    Say ''
    Say 'Aborting.'
    exit 1
}
Ok 'running elevated'

# --- windows version ---------------------------------------------------------
$os = [Environment]::OSVersion.Version
if ($os.Major -ne 6 -or $os.Minor -ne 1) {
    Warn "this installer targets Windows 7 (6.1); detected $($os.Major).$($os.Minor). Continuing anyway."
} else {
    Ok "Windows 7 build $($os.Build)"
}
if ($os.Build -lt 7601) {
    Fail 'Windows 7 Service Pack 1 (build 7601) is required.'
}

# --- KB2533623 (AddDllDirectory / SetDefaultDllDirectories) ------------------
$kernel32 = [System.Runtime.InteropServices.Marshal]::GetModuleHandle('kernel32.dll')
$addDllDirectoryType = [Type]::GetType('System.Object')
$hasDllDirectories = $false
try {
    $sig = '[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr AddDllDirectory(string p);'
    $probe = Add-Type -MemberDefinition $sig -Name 'DshWin7Probe' -Namespace 'DshWin7' -PassThru
    $null = $probe::AddDllDirectory('C:\')
    $hasDllDirectories = $true
} catch {
    $hasDllDirectories = $false
}
if ($hasDllDirectories) {
    Ok 'KB2533623 (DllDirectories update) present'
} else {
    Warn 'KB2533623 (DllDirectories update) not detected. Install it, otherwise some programs will not run even with VxKex.'
}

# --- bundled files -----------------------------------------------------------
foreach ($required in @($AppExe, $KexSetup, $KexCfg)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Fail "missing bundled file: $required"
        Say ''
        Say 'Aborting. Did you extract the whole zip?'
        exit 1
    }
}
Ok "portable payload found at $Here"

Step 'Installing VxKex NEXT'

$installedVersion = 0
try {
    $key = Get-ItemProperty -Path 'HKLM:\Software\VXsoft\VxKex' -ErrorAction Stop
    if ($key.InstalledVersion) { $installedVersion = [int]$key.InstalledVersion }
} catch { }

if ($installedVersion -ne 0) {
    Ok ("VxKex already installed (InstalledVersion=0x{0:X8})" -f $installedVersion)
} else {
    # KexSetup refuses to run unless the "prerequisites warning" is pre-dismissed,
    # and it must be started from its own directory so it can find Core*/Kex*.
    $vxKey = 'HKCU:\Software\VXsoft\VxKex'
    if (-not (Test-Path -LiteralPath $vxKey)) { New-Item -Path $vxKey -Force | Out-Null }
    New-ItemProperty -Path $vxKey -Name 'SetupPrerequisitesDontShowAgain' -Value 1 -PropertyType DWord -Force | Out-Null

    $setupDir = Split-Path -Parent $KexSetup
    Say "  running: KexSetup.exe /SILENTUNATTEND /KEXDIR:`"$KexDir`""
    $process = Start-Process -FilePath (Join-Path $setupDir 'KexSetup.exe') `
        -ArgumentList '/SILENTUNATTEND', "/KEXDIR:`"$KexDir`"" `
        -WorkingDirectory $setupDir -Wait -PassThru
    Start-Sleep -Seconds 2

    try {
        $key = Get-ItemProperty -Path 'HKLM:\Software\VXsoft\VxKex' -ErrorAction Stop
        $installedVersion = [int]$key.InstalledVersion
    } catch { }
    if ($installedVersion -ne 0) {
        Ok ("VxKex installed (InstalledVersion=0x{0:X8})" -f $installedVersion)
    } else {
        Fail "VxKex installation did not register (KexSetup exit code $($process.ExitCode))."
        Say '  Try running vxkex\KexSetup.exe manually.'
        Say ''
        Say 'Aborting.'
        exit 1
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\KexDll.dll'))) {
    Fail 'KexDll.dll was not placed into System32 — VxKex will not inject.'
}

Step 'Enabling VxKex for DSH Desktop'

$fullAppExe = (Resolve-Path -LiteralPath $AppExe).Path
$cfg = Start-Process -FilePath $KexCfg `
    -ArgumentList "/EXE:`"$fullAppExe`"", '/ENABLE:TRUE', '/WINVERSPOOF:WIN10' `
    -WorkingDirectory (Split-Path -Parent $KexCfg) -Wait -PassThru
if ($cfg.ExitCode -eq 0) {
    Ok "VxKex enabled for $fullAppExe (WinVerSpoof=WIN10)"
} else {
    Fail "KexCfg exited with $($cfg.ExitCode)"
}

$ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DSH Desktop.exe"
if (Test-Path -LiteralPath $ifeoKey) {
    Ok 'IFEO entry present'
    $ifo = Get-ItemProperty -Path $ifeoKey
    if ($ifo.UseFilter -eq 1) { Ok 'UseFilter=1' } else { Warn 'UseFilter is not 1 — path filtering is off' }
} else {
    Fail 'IFEO entry was not created'
}

Step 'Self test (Electron runtime under node mode)'

$previous = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE')
[Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', '1')
try {
    $out = & $fullAppExe '--version' 2>&1
    $code = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $previous)
}
$text = ($out | Out-String).Trim()
if ($code -eq 0 -and $text -match '^v\d+\.') {
    Ok "Electron runtime reports node $text"
} else {
    Fail "self test failed (exit $code): $text"
}

Step 'Shortcut'

if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $link = Join-Path $desktop 'DSH Desktop.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $fullAppExe
    $shortcut.WorkingDirectory = $AppDir
    $shortcut.IconLocation = "$fullAppExe,0"
    $shortcut.Description = 'DSH Desktop (Windows 7 portable)'
    $shortcut.Save()
    if (Test-Path -LiteralPath $link) { Ok "desktop shortcut: $link" } else { Warn 'could not create desktop shortcut' }
} else {
    Ok 'shortcut skipped (-NoShortcut)'
}

Step 'Summary'
if ($script:Problems.Count -eq 0) {
    Write-Host '  Everything checks out.' -ForegroundColor Green
    Say ''
    Say '  Launch DSH Desktop from the desktop shortcut.'
    Say "  Keep this folder where it is: VxKex pins the executable path ($fullAppExe)."
    Say ''
    exit 0
} else {
    Write-Host "  $($script:Problems.Count) issue(s):" -ForegroundColor Yellow
    foreach ($p in $script:Problems) { Say "   - $p" }
    Say ''
    Say '  DSH Desktop may still start. See docs/troubleshooting.md.'
    Say ''
    exit 1
}
