<#
    Installer template for Warchief Driver Updater.
    Build.ps1 replaces __PAYLOAD_B64__ with the base64-encoded app exe and
    __VERSION__ with the version, then compiles this to
    WarchiefDriverUpdater-Setup.exe via ps2exe.

    Switches:
      (none)      interactive install
      -Silent     install without prompts (Start Menu shortcut only)
      -Uninstall  remove the app (combine with -Silent for no prompts)
#>
param(
    [switch]$Uninstall,
    [switch]$Silent
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

$AppName    = 'Warchief Driver Updater'
$AppVersion = '__VERSION__'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Warchief Driver Updater'
$AppExe     = Join-Path $InstallDir 'WarchiefDriverUpdater.exe'
$UninstExe  = Join-Path $InstallDir 'Uninstall.exe'
$StartLnk   = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName.lnk"
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
$RegKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WarchiefDriverUpdater'

function Show-Msg([string]$Text, [string]$Title, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    if ($Silent) { return 'Yes' }
    return [Windows.MessageBox]::Show($Text, $Title, $Buttons, $Icon).ToString()
}

# ---------------------------------------------------------------------------
if ($Uninstall) {
    $r = Show-Msg "Remove $AppName from this war machine?" "$AppName - Uninstall" 'YesNo' 'Question'
    if ($r -ne 'Yes') { exit 0 }

    Get-Process -Name 'WarchiefDriverUpdater' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($lnk in $StartLnk, $DesktopLnk) {
        if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $RegKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:APPDATA 'WarchiefDriverUpdater') -Recurse -Force -ErrorAction SilentlyContinue

    # this exe lives inside $InstallDir, so delete the folder after we exit
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$InstallDir`""
    Show-Msg "$AppName has been removed. Farewell, champion." "$AppName - Uninstall" | Out-Null
    exit 0
}

# ---------------------------------------------------------------------------
$r = Show-Msg "Lok'tar ogar!`n`nInstall $AppName v${AppVersion}?`n`nIt will be placed in:`n$InstallDir`n`nNo admin rights required." "$AppName - Setup" 'YesNo' 'Question'
if ($r -ne 'Yes') { exit 0 }

# stop a running copy before overwriting (upgrade path)
Get-Process -Name 'WarchiefDriverUpdater' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
[IO.File]::WriteAllBytes($AppExe, [Convert]::FromBase64String('__PAYLOAD_B64__'))

# keep a copy of this setup exe as the uninstaller (skipped when run as a raw .ps1 during development)
$selfPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([IO.Path]::GetFileNameWithoutExtension($selfPath) -notmatch '^powershell|^pwsh') {
    Copy-Item $selfPath $UninstExe -Force
}

# Start Menu shortcut
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($StartLnk)
$sc.TargetPath       = $AppExe
$sc.WorkingDirectory = $InstallDir
$sc.IconLocation     = "$AppExe,0"
$sc.Description      = 'Horde-themed GPU driver updater'
$sc.Save()

# desktop shortcut (created by default in silent mode, asked about interactively)
$wantDesktop = $true
if (-not $Silent) {
    $wantDesktop = (Show-Msg 'Add a desktop shortcut as well?' "$AppName - Setup" 'YesNo' 'Question') -eq 'Yes'
}
if ($wantDesktop) {
    $sc = $ws.CreateShortcut($DesktopLnk)
    $sc.TargetPath       = $AppExe
    $sc.WorkingDirectory = $InstallDir
    $sc.IconLocation     = "$AppExe,0"
    $sc.Description      = 'Warcraft-faction-themed GPU driver updater'
    $sc.Save()
}

# register in Windows "Installed apps" so it can be uninstalled from Settings
$sizeKB = [int]((Get-Item $AppExe).Length / 1KB) + $(if (Test-Path $UninstExe) { [int]((Get-Item $UninstExe).Length / 1KB) } else { 0 })
New-Item -Path $RegKey -Force | Out-Null
Set-ItemProperty $RegKey -Name 'DisplayName'          -Value $AppName
Set-ItemProperty $RegKey -Name 'DisplayVersion'       -Value $AppVersion
Set-ItemProperty $RegKey -Name 'Publisher'            -Value 'Warchief Driver Updater contributors'
Set-ItemProperty $RegKey -Name 'DisplayIcon'          -Value $AppExe
Set-ItemProperty $RegKey -Name 'InstallLocation'      -Value $InstallDir
Set-ItemProperty $RegKey -Name 'UninstallString'      -Value "`"$UninstExe`" -Uninstall"
Set-ItemProperty $RegKey -Name 'QuietUninstallString' -Value "`"$UninstExe`" -Uninstall -Silent"
Set-ItemProperty $RegKey -Name 'NoModify'             -Value 1 -Type DWord
Set-ItemProperty $RegKey -Name 'NoRepair'             -Value 1 -Type DWord
Set-ItemProperty $RegKey -Name 'EstimatedSize'        -Value $sizeKB -Type DWord

if (-not $Silent) {
    $r = Show-Msg "$AppName v$AppVersion is installed!`n`nFind it in the Start Menu any time.`n`nRide into battle now?" "$AppName - Setup" 'YesNo' 'Question'
    if ($r -eq 'Yes') { Start-Process $AppExe }
}
exit 0
