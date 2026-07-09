<#
    Installer template for Warchief Driver Updater.
    Build.ps1 replaces __PAYLOAD_B64__ with the base64-encoded app exe and
    __VERSION__ with the version, then compiles this to
    WarchiefDriverUpdater-Setup.exe via ps2exe.

    Switches:
      (none)      interactive install (detects existing installs and upgrades)
      -Silent     install without prompts (Start Menu + desktop shortcut)
      -Uninstall  remove the app (combine with -Silent for no prompts)

    Copyright (C) 2026 dontshome. GNU GPL v3 or later; see the LICENSE file.
    This program comes with ABSOLUTELY NO WARRANTY.
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
$ConfigDir  = Join-Path $env:APPDATA 'WarchiefDriverUpdater'
$StartLnk   = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName.lnk"
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
$RegKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WarchiefDriverUpdater'
$LogFile    = Join-Path $env:TEMP 'WarchiefSetup.log'

function Show-Msg([string]$Text, [string]$Title, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    if ($Silent) { return 'Yes' }
    return [Windows.MessageBox]::Show($Text, $Title, $Buttons, $Icon).ToString()
}

# stop every running copy of the app and WAIT until the processes are truly
# gone - Windows keeps the exe locked until then, which was breaking upgrades
function Stop-AppProcesses {
    $procs = @(Get-Process -Name 'WarchiefDriverUpdater' -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(10000) | Out-Null } catch {}
    }
    if ($procs) { Start-Sleep -Milliseconds 500 }   # let the loader release file handles
}

# antivirus scans, slow handle release, and Explorer previews can keep files
# locked briefly - retry writes for up to ~10 seconds before giving up
function Invoke-WithRetry([scriptblock]$Action, [string]$What) {
    for ($i = 1; $i -le 20; $i++) {
        try { & $Action; return } catch {
            if ($i -eq 20) { throw "Could not write $What (still locked after 10s): $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 500
        }
    }
}

# ---------------------------------------------------------------------------
if ($Uninstall) {
    $r = Show-Msg "Remove $AppName from this war machine?" "$AppName - Uninstall" 'YesNo' 'Question'
    if ($r -ne 'Yes') { exit 0 }

    Stop-AppProcesses
    foreach ($lnk in $StartLnk, $DesktopLnk) {
        if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $RegKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $ConfigDir -Recurse -Force -ErrorAction SilentlyContinue

    # delete everything we can right now; only this running exe has to wait.
    # the delayed cleanup removes JUST our own exe and then the folder only if
    # it is empty - so a reinstall that happens in the meantime is never nuked
    Get-ChildItem $InstallDir -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $UninstExe } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 /nobreak >nul & del /f /q `"$UninstExe`" & rmdir `"$InstallDir`""

    Show-Msg "$AppName has been removed. Farewell, champion." "$AppName - Uninstall" | Out-Null
    exit 0
}

# ---------------------------------------------------------------------------
try {
    $existing = $null
    try { $existing = (Get-ItemProperty $RegKey -ErrorAction Stop).DisplayVersion } catch {}

    $prompt = if ($existing) {
        "Lok'tar ogar!`n`nYou have $AppName v$existing.`nUpgrade to v${AppVersion}?`n`n(Your faction choice and settings are kept.)"
    } else {
        "Lok'tar ogar!`n`nInstall $AppName v${AppVersion}?`n`nIt will be placed in:`n$InstallDir`n`nNo admin rights required."
    }
    $r = Show-Msg $prompt "$AppName - Setup" 'YesNo' 'Question'
    if ($r -ne 'Yes') { exit 0 }

    Stop-AppProcesses

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Invoke-WithRetry { [IO.File]::WriteAllBytes($AppExe, [Convert]::FromBase64String('__PAYLOAD_B64__')) } 'the application'

    # keep a copy of this setup exe as the uninstaller (skipped when run as a
    # raw .ps1 during development, or when someone runs Uninstall.exe directly)
    $selfPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileNameWithoutExtension($selfPath) -notmatch '^powershell$|^pwsh$' -and $selfPath -ne $UninstExe) {
        Invoke-WithRetry { Copy-Item $selfPath $UninstExe -Force } 'the uninstaller'
    }

    # Start Menu shortcut
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($StartLnk)
    $sc.TargetPath       = $AppExe
    $sc.WorkingDirectory = $InstallDir
    $sc.IconLocation     = "$AppExe,0"
    $sc.Description      = 'Warcraft-faction-themed GPU driver updater'
    $sc.Save()

    # desktop shortcut (created by default in silent mode, asked about interactively;
    # upgrades keep whatever the user chose before)
    $wantDesktop = $true
    if ($existing) { $wantDesktop = (Test-Path $DesktopLnk) }
    elseif (-not $Silent) {
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
        $done = if ($existing) { "$AppName is upgraded to v${AppVersion}!" } else { "$AppName v$AppVersion is installed!" }
        $r = Show-Msg "$done`n`nFind it in the Start Menu any time.`n`nRide into battle now?" "$AppName - Setup" 'YesNo' 'Question'
        if ($r -eq 'Yes') { Start-Process $AppExe }
    }
    exit 0
} catch {
    $err = $_.Exception.Message
    "[$(Get-Date -Format s)] INSTALL FAILED: $err" | Add-Content $LogFile -Encoding UTF8
    if (-not $Silent) {
        [void][Windows.MessageBox]::Show(
            "The installation failed:`n`n$err`n`nClose any running copy of $AppName and try again.`n(Details logged to $LogFile)",
            "$AppName - Setup", 'OK', 'Error')
    }
    exit 1
}
