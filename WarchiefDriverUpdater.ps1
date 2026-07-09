<#
    ⚔  WARCHIEF DRIVER UPDATER  ⚔
    A Warcraft-faction-themed GPU driver checker & downloader for Windows.
    Detects NVIDIA / AMD / Intel GPUs, checks the vendors' own servers for
    the newest driver, and downloads it with one click. Pick your side:
    Horde or Alliance. Lok'tar ogar!

    "Slim NVIDIA install" unpacks NVIDIA's driver package and installs the
    display driver WITHOUT the NVIDIA App / GeForce Experience / telemetry.

    Unofficial fan project. Not affiliated with Blizzard, NVIDIA, AMD or Intel.

    Copyright (C) 2026 dontshome  <https://github.com/dontshome/Warchief-Driver-Updater>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program (see the LICENSE file).  If not, see
    <https://www.gnu.org/licenses/>.
#>
param(
    [switch]$SelfTest,  # run headless diagnostics (no GUI) and exit
    [switch]$Scout      # headless: check for new drivers, toast if found, exit (used by the Sentinel scheduled task)
)

$ErrorActionPreference = 'Stop'
# Tls13 only exists on .NET Framework 4.8+; referencing it on older frameworks
# throws at startup, so add it opportunistically after locking in Tls12
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch {}

# ---------------------------------------------------------------------------
#  Shared constants & config
# ---------------------------------------------------------------------------
$script:AppVersion = '2.1.0'   # single source of truth - Build.ps1 reads this to version the exe
$script:GitHubRepo = 'dontshome/Warchief-Driver-Updater'
$script:UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$script:OsBuild  = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$script:NvOsId   = if ($script:OsBuild -ge 22000) { 135 } else { 57 }   # 135 = Win11, 57 = Win10 x64
$script:AmdOsTag = if ($script:OsBuild -ge 22000) { 'win11' } else { 'win10' }

$script:ConfigDir  = Join-Path $env:APPDATA 'WarchiefDriverUpdater'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'

function Get-AppConfig {
    $cfg = @{ Theme = 'horde'; SlimInstall = $true; NvidiaStudio = $false
              RestorePoint = $true; AutoScout = $false; ScoutFreq = 'Daily'; MinimizeToTray = $false }
    try {
        if (Test-Path $script:ConfigPath) {
            $saved = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if ($saved.Theme -in 'horde', 'alliance') { $cfg.Theme = $saved.Theme }
            if ($null -ne $saved.SlimInstall) { $cfg.SlimInstall = [bool]$saved.SlimInstall }
            elseif ($null -ne $saved.SlimNvidia) { $cfg.SlimInstall = [bool]$saved.SlimNvidia }  # pre-1.2 config
            if ($null -ne $saved.NvidiaStudio)   { $cfg.NvidiaStudio   = [bool]$saved.NvidiaStudio }
            if ($null -ne $saved.RestorePoint)   { $cfg.RestorePoint   = [bool]$saved.RestorePoint }
            if ($null -ne $saved.AutoScout)      { $cfg.AutoScout      = [bool]$saved.AutoScout }
            if ($saved.ScoutFreq -in 'Daily','Weekly') { $cfg.ScoutFreq = $saved.ScoutFreq }
            if ($null -ne $saved.MinimizeToTray) { $cfg.MinimizeToTray = [bool]$saved.MinimizeToTray }
        }
    } catch {}
    return $cfg
}
function Save-AppConfig {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null }
        $script:Config | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch {}
}
$script:Config = Get-AppConfig

# ---------------------------------------------------------------------------
#  Faction themes
# ---------------------------------------------------------------------------
$script:Themes = @{
    horde = @{
        WindowBg   = '#0B0705'; TitleBg  = '#160D08'; PanelBg = '#14100B'
        PanelBorder= '#5A2214'; InnerBorder = '#3D2B12'; AccentBorder = '#A67C2E'
        Gold = '#E5A93D'; GoldBright = '#FFC94A'; Parchment = '#D8C9A8'; Dim = '#8A7A5C'
        BtnTop = '#6E1710'; BtnBottom = '#3D0C08'; BtnHoverTop = '#A32418'; BtnHoverBottom = '#5A120B'
        BtnDisabledBg = '#1A120C'; BtnDisabledBorder = '#4A3A22'; BtnDisabledFg = '#6B5B3E'
        BannerTop = '#3A0F08'; BarTop = '#D93A25'; BarBottom = '#7A130A'; BarTrack = '#1A0E08'
        TitleBarText = '⚔ WARCHIEF DRIVER UPDATER'
        Title    = "⚔  THE WARCHIEF'S ARMORY  ⚔"
        Tagline  = "Lok'tar ogar! Keep your war machine battle-ready."
        ScoutLabel  = '🐺 SCOUT AGAIN'
        SwitchLabel = '🦁 ALLIANCE'
        ScanDone = 'Scouting complete. For the Horde!'
        UpToDate = '✔ BATTLE READY — your armament is the finest in the Horde.'
    }
    alliance = @{
        WindowBg   = '#060A12'; TitleBg  = '#0A101C'; PanelBg = '#0C1220'
        PanelBorder= '#1E3A5F'; InnerBorder = '#22304A'; AccentBorder = '#B89B4E'
        Gold = '#D8B24A'; GoldBright = '#FFD766'; Parchment = '#C9D4E8'; Dim = '#6E7FA0'
        BtnTop = '#1D4E89'; BtnBottom = '#0D2440'; BtnHoverTop = '#2E6DB4'; BtnHoverBottom = '#12335C'
        BtnDisabledBg = '#0C1420'; BtnDisabledBorder = '#243550'; BtnDisabledFg = '#4E5F7E'
        BannerTop = '#122A4D'; BarTop = '#2E86DE'; BarBottom = '#123B66'; BarTrack = '#081018'
        TitleBarText = '🦁 ALLIANCE DRIVER UPDATER'
        Title    = '🦁  THE ALLIANCE ARMORY  🦁'
        Tagline  = 'For the Alliance! Keep your war machine battle-ready.'
        ScoutLabel  = '🦅 SCOUT AGAIN'
        SwitchLabel = '⚔ HORDE'
        ScanDone = 'Scouting complete. For the Alliance!'
        UpToDate = '✔ BATTLE READY — your armament shines with the Light.'
    }
}

# semantic status colors (faction-independent)
$script:ColGood = '#7FB347'; $script:ColUpdate = '#FF6B35'; $script:ColWarn = '#E5A93D'; $script:ColErr = '#B3261A'

# ---------------------------------------------------------------------------
#  GPU detection (local, fast)
# ---------------------------------------------------------------------------
function Get-GpuInventory {
    $gpus = @()
    $i = 0
    foreach ($vc in (Get-CimInstance Win32_VideoController)) {
        $name = $vc.Name
        if (-not $name) { continue }
        if ($name -match 'Microsoft|Virtual|Remote|Parsec|DisplayLink|Meta ') { continue }

        $vendor = $null
        if ($name -match 'NVIDIA' -or $vc.AdapterCompatibility -match 'NVIDIA') { $vendor = 'NVIDIA' }
        elseif ($name -match 'AMD|Radeon' -or $vc.AdapterCompatibility -match 'AMD|Advanced Micro') { $vendor = 'AMD' }
        elseif ($name -match 'Intel') { $vendor = 'Intel' }
        if (-not $vendor) { continue }

        $installed = $null
        if ($vendor -eq 'NVIDIA') {
            $installed = Convert-NvidiaWmiVersion $vc.DriverVersion
        } elseif ($vendor -eq 'AMD') {
            $installed = Get-AmdInstalledVersion
            if (-not $installed) { $installed = $vc.DriverVersion }
        } else {
            $installed = $vc.DriverVersion
        }

        $gpus += [pscustomobject]@{
            Index     = $i
            Name      = $name
            Vendor    = $vendor
            Installed = $installed
        }
        $i++
    }
    return ,$gpus
}

# "32.0.15.6094" -> "560.94"  (NVIDIA packs the friendly version into the WMI one)
function Convert-NvidiaWmiVersion([string]$wmiVersion) {
    try {
        $digits = $wmiVersion -replace '\.', ''
        if ($digits.Length -lt 5) { return $wmiVersion }
        return $digits.Substring($digits.Length - 5).Insert(3, '.')
    } catch { return $wmiVersion }
}

# Radeon Software (Adrenalin) version lives in the registry, e.g. "25.5.1"
function Get-AmdInstalledVersion {
    try {
        (Get-ItemProperty 'HKLM:\SOFTWARE\AMD\CN' -ErrorAction Stop).RadeonSoftwareVersion
    } catch { $null }
}

# ---------------------------------------------------------------------------
#  Network / worker functions. Kept in a single string so the same definitions
#  can be injected into background runspaces (the GUI never blocks on them).
# ---------------------------------------------------------------------------
$script:NetFunctions = @'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Web([string]$Url, [string]$Referer) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = $UA
    $req.Timeout   = 30000
    if ($Referer) { $req.Referer = $Referer }
    $resp = $req.GetResponse()
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        return $sr.ReadToEnd()
    } finally { $resp.Close() }
}

# --- Self-update check --------------------------------------------------------
# Asks GitHub's public API for the newest release tag/assets. Never installs
# anything on its own - it only reports what it found so the UI can ask you.
function Get-LatestReleaseInfo([string]$Repo) {
    $req = [Net.HttpWebRequest]::Create("https://api.github.com/repos/$Repo/releases/latest")
    $req.UserAgent = $UA
    $req.Accept    = 'application/vnd.github+json'
    $req.Timeout   = 15000
    $resp = $req.GetResponse()
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $json = $sr.ReadToEnd() | ConvertFrom-Json
    } finally { $resp.Close() }

    $tag = $json.tag_name -replace '^v', ''
    $setupAsset = $json.assets | Where-Object { $_.name -match 'Setup\.exe$' } | Select-Object -First 1
    return @{
        Version    = $tag
        HtmlUrl    = $json.html_url
        SetupUrl   = $(if ($setupAsset) { $setupAsset.browser_download_url })
        SetupName  = $(if ($setupAsset) { $setupAsset.name })
    }
}

# --- NVIDIA -----------------------------------------------------------------
# 1) map GPU name -> psid/pfid via NVIDIA's public lookup XML
# 2) query the AjaxDriverService for the newest Game Ready (or Studio) driver
#    Studio drivers need upCRD=1&isWHQL=0 (they are WHQL-certified, but the
#    API only returns them with that combination).
function Get-NvidiaLatest([string]$GpuName, [int]$OsId, [bool]$Studio = $false) {
    $xmlText = Get-Web 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3'
    [xml]$xml = $xmlText
    $entries  = $xml.LookupValueSearch.LookupValues.LookupValue

    $clean = ($GpuName -replace '(?i)^NVIDIA\s+', '').Trim()
    $match = $entries | Where-Object { $_.Name -ieq $clean } | Select-Object -First 1
    if (-not $match) {
        $match = $entries | Where-Object { $_.Name -and $clean -like "*$($_.Name)*" } |
                 Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1
    }
    if (-not $match) { return @{ Error = "GPU '$clean' not found in NVIDIA's product list." } }

    $psid = $match.ParentID; $pfid = $match.Value
    $flavor = if ($Studio) { 'upCRD=1&isWHQL=0' } else { 'upCRD=0&isWHQL=1' }
    $api  = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php" +
            "?func=DriverManualLookup&psid=$psid&pfid=$pfid&osID=$OsId&languageCode=1033" +
            "&beta=0&dltype=-1&dch=1&qnf=0&sort1=0&numberOfResults=1&$flavor"
    $json = (Get-Web $api) | ConvertFrom-Json
    if ($json.Success -ne '1' -or -not $json.IDS) { return @{ Error = 'NVIDIA returned no driver for this GPU/OS.' } }

    $d = $json.IDS[0].downloadInfo
    return @{
        Version = $d.Version
        Url     = $d.DownloadURL
        Notes   = $d.DetailsURL
        Size    = $d.DownloadURLFileSize
        Date    = $d.ReleaseDateTime
        Title   = [uri]::UnescapeDataString($d.Name)
    }
}

# --- AMD --------------------------------------------------------------------
# AMD's per-product driver pages are server-rendered and contain direct
# drivers.amd.com installer links. We derive candidate page URLs from the
# GPU name and scrape the first one that answers.
function Get-AmdLatest([string]$GpuName, [string]$OsTag) {
    $manualUrl = 'https://www.amd.com/en/support/download/drivers.html'
    if ($GpuName -notmatch '(?i)Radeon') {
        return @{ Error = 'Could not map this AMD GPU to a driver page. Use the AMD site button.'; Notes = $manualUrl }
    }

    $candidates = @()
    $m = [regex]::Match($GpuName, '(?i)RX\s*(\d{3,4})\s*(XTX|XT|GRE|M|S)?')
    if ($m.Success) {
        $model  = $m.Groups[1].Value
        $suffix = $m.Groups[2].Value.ToLower()
        $series = if ($model.Length -eq 4) { "$($model.Substring(0,1))000" } else { "$($model.Substring(0,1))00" }
        $slug   = "amd-radeon-rx-$model"; if ($suffix) { $slug += "-$suffix" }
        $candidates += @(
            "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-$series-series/$slug.html",
            "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-$series-series/amd-radeon-rx-$model$suffix.html",
            "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-$series-series/radeon-rx-$model$(if($suffix){"-$suffix"}).html"
        )
    }
    # AMD ships ONE unified Adrenalin package for all supported Radeon dGPUs
    # and Ryzen APU graphics, so if the card-specific page can't be found
    # (renamed page, APU, layout change) any current product page yields the
    # right installer. These act as evergreen fallbacks.
    $candidates += @(
        'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7900-xtx.html',
        'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7600.html'
    )

    foreach ($url in ($candidates | Select-Object -Unique)) {
        try { $html = Get-Web $url } catch { continue }

        $links = [regex]::Matches($html, 'href="(https://drivers\.amd\.com/drivers/[^"]+\.exe)"') |
                 ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        if (-not $links) { continue }

        # prefer the full offline WHQL installer for this OS, fall back to the web setup
        $dl = $links | Where-Object { $_ -match 'whql-amd-software' -and $_ -match $OsTag } | Select-Object -First 1
        if (-not $dl) { $dl = $links | Where-Object { $_ -match 'minimalsetup' } | Select-Object -First 1 }
        if (-not $dl) { $dl = $links | Select-Object -First 1 }

        $ver = ''
        $vm = [regex]::Match($dl, 'adrenalin-edition-([\d\.]+\d)')
        if (-not $vm.Success) { $vm = [regex]::Match(($links -join ' '), 'adrenalin-edition-([\d\.]+\d)') }
        if ($vm.Success) { $ver = $vm.Groups[1].Value }

        return @{
            Version = $ver
            Url     = $dl
            Notes   = $url
            Referer = $url
            Title   = "AMD Software: Adrenalin Edition $ver"
        }
    }
    return @{ Error = 'AMD driver page not found for this GPU. Use the AMD site button.'; Notes = $manualUrl }
}

# --- Intel ------------------------------------------------------------------
# Intel ships one unified driver for Arc / Iris Xe / UHD (11th gen+). The US
# download page sits behind bot protection, but intel.cn serves the identical
# page server-rendered, including the direct downloadmirror.intel.com link.
function Get-IntelLatest([string]$GpuName) {
    $notesUrl = 'https://www.intel.com/content/www/us/en/download/785597/intel-arc-iris-xe-graphics-windows.html'
    if ($GpuName -notmatch '(?i)Arc|Iris|UHD') {
        return @{ Error = 'Legacy Intel graphics use per-generation drivers. Use the Intel site button.'
                  Notes = 'https://www.intel.com/content/www/us/en/support/detect.html' }
    }
    $pages = @(
        $notesUrl,
        'https://www.intel.cn/content/www/cn/zh/download/785597/intel-arc-iris-xe-graphics-windows.html'
    )
    foreach ($url in $pages) {
        try { $html = Get-Web $url } catch { continue }
        $dl = [regex]::Match($html, '(https://downloadmirror\.intel\.com/[^"''\s<>]+\.exe)')
        if (-not $dl.Success) { continue }
        $ver = [regex]::Match($html, '(\d+\.\d+\.101\.\d+)')
        return @{
            Version = $(if ($ver.Success) { $ver.Groups[1].Value } else { '' })
            Url     = $dl.Groups[1].Value
            Notes   = $notesUrl
            Title   = 'Intel Arc & Iris Xe Graphics Driver'
        }
    }
    return @{ Error = 'Intel driver page not reachable. Use the Intel site button.'; Notes = $notesUrl }
}

# --- Download with progress ---------------------------------------------------
function Invoke-FileDownload([string]$Url, [string]$Dest, $Sync, [string]$Referer, [string]$Prefix = '') {
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UA
        if ($Referer) { $req.Referer = $Referer }
        $resp = $req.GetResponse()
        $Sync["${Prefix}DlTotal"] = $resp.ContentLength
        $in  = $resp.GetResponseStream()
        $out = [IO.File]::Create($Dest)
        try {
            $buf = New-Object byte[] 262144
            $done = 0L
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                $Sync["${Prefix}DlBytes"] = $done
            }
        } finally { $out.Close(); $in.Close(); $resp.Close() }
        $Sync["${Prefix}DlPath"] = $Dest
    } catch {
        $Sync["${Prefix}DlError"] = $_.Exception.Message
        try { if (Test-Path $Dest) { Remove-Item $Dest -Force } } catch {}
    }
    $Sync["${Prefix}DlDone"] = $true
}

# --- Slim NVIDIA install ------------------------------------------------------
# NVIDIA's driver .exe is a 7-Zip self-extracting archive. We unpack it while
# EXCLUDING the NVIDIA App / GeForce Experience / telemetry components, patch
# setup.cfg so the installer doesn't look for the removed pieces, then run a
# quiet driver-only install. Same technique as NVCleanstall / NVSlimmer.
function Get-SevenZip([string]$ToolDir) {
    foreach ($p in "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") {
        if (Test-Path $p) { return $p }
    }
    $local = Join-Path $ToolDir '7zr.exe'
    if (Test-Path $local) { return $local }
    # fetch the official standalone console version (~600 KB) from 7-zip.org
    if (-not (Test-Path $ToolDir)) { New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null }
    $req = [Net.HttpWebRequest]::Create('https://www.7-zip.org/a/7zr.exe')
    $req.UserAgent = $UA
    $resp = $req.GetResponse()
    $in  = $resp.GetResponseStream()
    $out = [IO.File]::Create($local)
    try {
        $buf = New-Object byte[] 65536
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
    } finally { $out.Close(); $in.Close(); $resp.Close() }
    return $local
}

# Sum the uncompressed bytes of every archive entry whose path contains one of
# the given folder names - i.e. how much disk the slim install skips. Uses
# 7-Zip's technical listing (-slt) so parsing is robust across versions.
function Measure-SkippedBytes([string]$SevenZip, [string]$ExePath, [string[]]$Folders) {
    try {
        $total = 0L; $curSize = 0L; $isMatch = $false
        foreach ($line in (& $SevenZip l -slt $ExePath)) {
            if ($line -like 'Path = *') {
                $p = $line.Substring(7)
                $segs = $p -split '[\\/]'
                $isMatch = @($segs | Where-Object { $Folders -contains $_ }).Count -gt 0
            } elseif ($isMatch -and $line -like 'Size = *') {
                $curSize = 0L
                [void][long]::TryParse($line.Substring(7).Trim(), [ref]$curSize)
                $total += $curSize
                $isMatch = $false
            }
        }
        return $total
    } catch { return 0L }
}

# --- Restore point (elevated one-liner; Windows throttles to one per 24h) ----
function New-WarchiefRestorePoint([string]$Desc, $Sync) {
    try {
        $cmd = "Checkpoint-Computer -Description '$($Desc -replace "'", '')' -RestorePointType MODIFY_SETTINGS"
        $p = Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
             -ArgumentList '-NoProfile', '-Command', $cmd
        $Sync.RpExit = $p.ExitCode
    } catch { $Sync.RpError = $_.Exception.Message }
    $Sync.RpDone = $true
}

# --- Slim AMD install ---------------------------------------------------------
# AMD's installer is also an archive. Per AMD's own Command Line Installation
# guide, "Setup.exe -INSTALL -USE <path>" silently installs only the packages
# under <path>. The Adrenalin app lives in Packages\Apps, the actual display /
# audio drivers live in Packages\Drivers — so we extract without the Apps
# payload and point -USE at the Drivers folder. Driver only, no Adrenalin.
function Invoke-AmdSlimInstall([string]$ExePath, [string]$WorkDir, $Sync, [string]$ToolDir) {
    try {
        $Sync.SlimStatus = 'Locating extraction tool...'
        $sz = Get-SevenZip $ToolDir

        if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }

        $Sync.SlimStatus = 'Measuring how much bloat we can skip...'
        $Sync.SlimSaved = Measure-SkippedBytes $sz $ExePath @('Apps')

        $Sync.SlimStatus = 'Unpacking AMD package without the Adrenalin app (takes a few minutes)...'
        & $sz x $ExePath "-o$WorkDir" '-y' '-xr!Apps' | Out-Null
        if ($LASTEXITCODE -gt 1) { throw "7-Zip failed with exit code $LASTEXITCODE." }

        # the package holds two Setup.exe files (root + Bin64) — take the one
        # that has the Packages\Drivers payload next to it
        $setup = Get-ChildItem $WorkDir -Filter 'Setup.exe' -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { Test-Path (Join-Path $_.DirectoryName 'Packages\Drivers') } |
                 Select-Object -First 1
        if (-not $setup) { throw 'Setup.exe with Packages\Drivers not found after extraction.' }
        $drivers = Join-Path $setup.DirectoryName 'Packages\Drivers'

        $Sync.SlimStatus = 'Approve the admin prompt, then hold the line — installing driver...'
        $p = Start-Process $setup.FullName -ArgumentList '-INSTALL', '-USE', $drivers -Verb RunAs -Wait -PassThru
        $Sync.SlimExit = $p.ExitCode
    } catch {
        $Sync.SlimError = $_.Exception.Message
    }
    $Sync.SlimDone = $true
}

function Invoke-NvidiaSlimInstall([string]$ExePath, [string]$WorkDir, $Sync, [string]$ToolDir) {
    try {
        $Sync.SlimStatus = 'Locating extraction tool...'
        $sz = Get-SevenZip $ToolDir

        if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }

        $Sync.SlimStatus = 'Unpacking driver & stripping the bloat (can take a minute)...'
        # Only strip the top-level component FOLDERS that are genuinely
        # separable (the NVIDIA App / GeForce Experience suite). Do NOT use
        # recursive (-xr!) name globs: modern drivers ship NvTelemetry64.dll
        # and other bits INSIDE Display.Driver, and excluding them by name
        # anywhere breaks the driver install (manifest "file missing" -> abort).
        $bloat = @('GFExperience', 'GFExperience.NvStreamSrv', 'NvApp', 'NVApp', 'NvApp.MessageBus',
                   'GfeSDK', 'ShadowPlay', 'ShieldWirelessController', 'Update.Core', 'NvBackend', 'nodejs')
        $Sync.SlimSaved = Measure-SkippedBytes $sz $ExePath $bloat
        $szArgs = @('x', $ExePath, "-o$WorkDir", '-y') + ($bloat | ForEach-Object { "-x!$_" })
        & $sz @szArgs | Out-Null
        if ($LASTEXITCODE -gt 1) { throw "7-Zip failed with exit code $LASTEXITCODE." }
        if (-not (Test-Path (Join-Path $WorkDir 'setup.exe'))) { throw 'setup.exe not found after extraction.' }

        # remove ONLY the <file> presence-check entries for files that lived in
        # the stripped folders. The <string> definitions must stay - other lines
        # reference them, and the installer aborts on undefined variables.
        $cfg = Join-Path $WorkDir 'setup.cfg'
        if (Test-Path $cfg) {
            $txt = [IO.File]::ReadAllText($cfg)
            $txt = [regex]::Replace($txt, '(?m)^\s*<file name="\$\{\{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile|GDPR[^}]*)\}\}"\s*/>\s*\r?\n', '')
            [IO.File]::WriteAllText($cfg, $txt)
        }

        $Sync.SlimStatus = 'Installing driver (NVIDIA progress window is open)...'
        $p = Start-Process (Join-Path $WorkDir 'setup.exe') -ArgumentList '-passive', '-noreboot', '-nofinish', '-noeula' -Wait -PassThru
        $Sync.SlimExit = $p.ExitCode
    } catch {
        $Sync.SlimError = $_.Exception.Message
    }
    $Sync.SlimDone = $true
}
'@

# make the functions available in THIS scope too
. ([scriptblock]::Create($script:NetFunctions))

# ===========================================================================
#  2.0 feature engine  (all built on tools already on the machine - no bloat)
# ===========================================================================
$script:WarChestPath = Join-Path $script:ConfigDir 'warchest.json'

# --- War Chest: remember installed drivers so you can re-equip an old one ----
function Get-WarChest {
    try { if (Test-Path $script:WarChestPath) { return @(Get-Content $script:WarChestPath -Raw | ConvertFrom-Json) } } catch {}
    return @()
}
function Add-WarChestEntry([string]$Vendor, [string]$Gpu, [string]$Version, [string]$Url, [string]$LocalPath) {
    $list = @(Get-WarChest | Where-Object { -not ($_.Vendor -eq $Vendor -and $_.Version -eq $Version) })
    $entry = [pscustomobject]@{ Vendor = $Vendor; Gpu = $Gpu; Version = $Version; Url = $Url
                               LocalPath = $LocalPath; Date = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $list = @($entry) + $list
    if ($list.Count -gt 20) { $list = $list[0..19] }
    try { $list | ConvertTo-Json | Set-Content $script:WarChestPath -Encoding UTF8 } catch {}
}

# --- Restore points ----------------------------------------------------------
function Get-AppRestorePoints {
    try {
        return @(Get-ComputerRestorePoint -ErrorAction Stop |
                 Where-Object { $_.Description -like 'Warchief*' } |
                 Sort-Object SequenceNumber -Descending)
    } catch { return @() }
}

# --- Installed games (Steam manifests + known launcher publishers) -----------
function Get-InstalledGames {
    $games = New-Object System.Collections.Generic.List[object]
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($steam) {
            $steam = $steam -replace '/', '\'
            $libs = @(Join-Path $steam 'steamapps')
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s*"([^"]+)"')) {
                    $libs += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps')
                }
            }
            foreach ($lib in ($libs | Select-Object -Unique)) {
                if (Test-Path $lib) {
                    foreach ($acf in Get-ChildItem $lib -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
                        $nm = [regex]::Match((Get-Content $acf.FullName -Raw -Encoding UTF8), '"name"\s*"([^"]+)"')
                        if ($nm.Success) { $games.Add([pscustomobject]@{ Name = $nm.Groups[1].Value; Platform = 'Steam' }) }
                    }
                }
            }
        }
    } catch {}
    try {
        foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.Publisher -match 'Blizzard|Riot|Epic Games|Ubisoft|Electronic Arts|Rockstar|Bethesda|CD Projekt' } |
                ForEach-Object { $games.Add([pscustomobject]@{ Name = $_.DisplayName; Platform = $_.Publisher }) }
        }
    } catch {}
    # drop launchers/runtimes that aren't actually games
    $games = @($games | Where-Object { $_.Name -notmatch 'Redistributable|Steamworks Common|Proton|Steam Linux|^Battle\.net$|Launcher$' })
    return @($games | Sort-Object Name -Unique)
}

# strip a release-notes web page down to readable text for game matching
function Get-DriverNotesText([string]$Url) {
    if (-not $Url) { return '' }
    try {
        $html = Get-Web $Url
        $t = [regex]::Replace($html, '(?is)<script.*?</script>', ' ')
        $t = [regex]::Replace($t, '(?is)<style.*?</style>', ' ')
        $t = [regex]::Replace($t, '<[^>]+>', ' ')
        return [System.Net.WebUtility]::HtmlDecode($t)
    } catch { return '' }
}

# --- Live GPU stats (nvidia-smi for NVIDIA; perf counters elsewhere) ---------
function Get-NvSmiStats {
    $exe = $null
    foreach ($p in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
        if (Test-Path $p) { $exe = $p; break }
    }
    if (-not $exe) { return $null }
    try {
        $q = & $exe '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,clocks.gr,power.draw,fan.speed' '--format=csv,noheader,nounits' 2>$null
        $rows = @()
        foreach ($line in @($q)) {
            if (-not "$line".Trim()) { continue }
            $f = $line -split '\s*,\s*'
            $rows += [pscustomobject]@{
                Name = $f[0]; Temp = $f[1]; Util = $f[2]; MemUsed = $f[3]
                MemTotal = $f[4]; Clock = $f[5]; Power = $f[6]; Fan = $f[7]
            }
        }
        return $rows
    } catch { return $null }
}
# --- WDDM telemetry: temp/clock/power/fan for ANY vendor ---------------------
# The same hidden gdi32 API Task Manager uses (D3DKMTQueryAdapterInfo with
# ADAPTERPERFDATA=62 / NODEPERFDATA=61). Every WDDM 2.4+ driver feeds it, so
# AMD and Intel get real sensor readings with zero extra software. Units were
# calibrated against nvidia-smi: Temperature is deci-Celsius, Power is tenths
# of a percent of the card's max, frequencies are Hz, FanRPM is literal RPM.
$script:KmtCs = @'
using System;
using System.Runtime.InteropServices;
public static class WduKmt {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct AI { public uint h; public LUID luid; public uint n; public uint b; }
    [StructLayout(LayoutKind.Sequential)] public struct EA2 { public uint N; public IntPtr p; }
    [StructLayout(LayoutKind.Sequential)] public struct QAI { public uint h; public uint T; public IntPtr p; public uint s; }
    [StructLayout(LayoutKind.Sequential)] public struct PERF {
        public uint PhysIdx; public ulong MemF, MaxMemF, MaxMemFOC, MemBW, PcieBW;
        public uint Fan, Power, Temp; public byte Ovr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct NODE {
        public uint Ord; public uint PhysIdx; public ulong Freq, MaxF, MaxFOC;
        public uint V, VMax, VMaxOC; public ulong Lat;
    }
    [StructLayout(LayoutKind.Sequential)] public struct CA { public uint h; }
    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref EA2 e);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QAI q);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CA c);
    public static string[] Read() {
        var list = new System.Collections.Generic.List<string>();
        var e = new EA2();
        if (D3DKMTEnumAdapters2(ref e) != 0) return list.ToArray();
        int sz = Marshal.SizeOf(typeof(AI));
        e.p = Marshal.AllocHGlobal(sz * (int)e.N);
        if (D3DKMTEnumAdapters2(ref e) != 0) { Marshal.FreeHGlobal(e.p); return list.ToArray(); }
        for (int i = 0; i < (int)e.N; i++) {
            var ai = (AI)Marshal.PtrToStructure(IntPtr.Add(e.p, i * sz), typeof(AI));
            ulong memHz = 0, coreHz = 0, maxCoreHz = 0; uint fan = 0, pow = 0, temp = 0;
            int psz = Marshal.SizeOf(typeof(PERF));
            IntPtr buf = Marshal.AllocHGlobal(psz);
            var pd = new PERF(); Marshal.StructureToPtr(pd, buf, false);
            var q = new QAI(); q.h = ai.h; q.T = 62; q.p = buf; q.s = (uint)psz;
            if (D3DKMTQueryAdapterInfo(ref q) == 0) {
                pd = (PERF)Marshal.PtrToStructure(buf, typeof(PERF));
                memHz = pd.MemF; fan = pd.Fan; pow = pd.Power; temp = pd.Temp;
            }
            Marshal.FreeHGlobal(buf);
            int nsz = Marshal.SizeOf(typeof(NODE));
            IntPtr nb = Marshal.AllocHGlobal(nsz);
            var nd = new NODE(); nd.Ord = 0; Marshal.StructureToPtr(nd, nb, false);
            var nq = new QAI(); nq.h = ai.h; nq.T = 61; nq.p = nb; nq.s = (uint)nsz;
            if (D3DKMTQueryAdapterInfo(ref nq) == 0) {
                nd = (NODE)Marshal.PtrToStructure(nb, typeof(NODE));
                coreHz = nd.Freq; maxCoreHz = nd.MaxF;
            }
            Marshal.FreeHGlobal(nb);
            var ca = new CA(); ca.h = ai.h; D3DKMTCloseAdapter(ref ca);
            if (temp > 0 || fan > 0 || pow > 0 || memHz > 0 || coreHz > 0) {
                list.Add(string.Format("{0}|{1}|{2}|{3}|{4}|{5}", temp, fan, pow, memHz, coreHz, maxCoreHz));
            }
        }
        Marshal.FreeHGlobal(e.p);
        return list.ToArray();
    }
}
'@
function Get-KmtStats {
    if ($null -eq $script:KmtReady) {
        try { Add-Type -TypeDefinition $script:KmtCs; $script:KmtReady = $true } catch { $script:KmtReady = $false }
    }
    if (-not $script:KmtReady) { return @() }
    $rows = @()
    try {
        foreach ($line in [WduKmt]::Read()) {
            $p = $line -split '\|'
            $tC = [double]$p[0] / 10
            if ($tC -gt 200) { $tC -= 273.15 }   # defensive: some drivers report deci-Kelvin
            $rows += [pscustomobject]@{
                Temp = [math]::Round($tC, 0)
                Fan  = [int]$p[1]
                Power = [math]::Round([double]$p[2] / 10, 0)
                MemMHz  = [math]::Round([double]$p[3] / 1e6, 0)
                CoreMHz = [math]::Round([double]$p[4] / 1e6, 0)
                MaxCoreMHz = [math]::Round([double]$p[5] / 1e6, 0)
            }
        }
    } catch {}
    return ,$rows
}

# Universal live stats - works for NVIDIA, AMD and Intel alike using only
# what Windows already has: GPU perf counters (usage, VRAM in use), the
# display-class registry (true total VRAM; WMI's AdapterRAM caps at 4 GB)
# and WMI (driver version/date). NVIDIA rows get extra depth from nvidia-smi.
function Get-GpuLiveStats {
    $gpus = @(Get-CimInstance Win32_VideoController |
              Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft|Virtual|Remote|Parsec|DisplayLink' })

    # note: counter PATHS are localized on non-English Windows; if these two
    # lookups fail there, usage/VRAM-in-use rows are simply omitted (the WDDM
    # telemetry below still provides temp/clocks/power/fan)
    $util = $null; $vramUsed = $null
    try {
        $s = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $util = [math]::Round([math]::Min((($s | Measure-Object CookedValue -Sum).Sum), 100), 0)
    } catch {}
    try {
        $m = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        $vramUsed = [long](($m | Measure-Object CookedValue -Sum).Sum)
    } catch {}

    $totals = @{}
    try {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($p.DriverDesc -and $p.'HardwareInformation.qwMemorySize') {
                    $totals[$p.DriverDesc] = [long]$p.'HardwareInformation.qwMemorySize'
                }
            }
    } catch {}

    $smi = @()
    if ($gpus | Where-Object { $_.Name -match 'NVIDIA' }) { $smi = @(Get-NvSmiStats) }
    $kmt = @(Get-KmtStats)   # WDDM telemetry: any vendor, no extra software
    $kmtIdx = 0

    $out = @()
    foreach ($g in $gpus) {
        $smiRow = $smi | Where-Object { $g.Name -like "*$($_.Name)*" -or $_.Name -like "*$($g.Name)*" } | Select-Object -First 1
        $kd = $null
        if (-not $smiRow -and $kmtIdx -lt $kmt.Count) { $kd = $kmt[$kmtIdx]; $kmtIdx++ }
        $age = $null; try { $age = [int]((Get-Date) - $g.DriverDate).TotalDays } catch {}
        $total = $totals[$g.Name]
        $vendor = if ($g.Name -match 'NVIDIA') { 'NVIDIA' } elseif ($g.Name -match 'AMD|Radeon') { 'AMD' } elseif ($g.Name -match 'Intel') { 'Intel' } else { '' }

        $vramTxt = $null
        if ($smiRow) { $vramTxt = "$($smiRow.MemUsed) / $($smiRow.MemTotal) MB" }
        elseif ($null -ne $vramUsed -and $total) { $vramTxt = "{0:N0} / {1:N0} MB" -f ($vramUsed/1MB), ($total/1MB) }
        elseif ($total) { $vramTxt = "{0:N0} MB total" -f ($total/1MB) }

        $out += [pscustomobject]@{
            Name = $g.Name; Vendor = $vendor
            Util = if ($smiRow) { "$($smiRow.Util) %" } elseif ($null -ne $util) { "$util %" } else { $null }
            Vram = $vramTxt
            Temp  = if ($smiRow) { "$($smiRow.Temp) °C" } elseif ($kd -and $kd.Temp -gt 0) { "$($kd.Temp) °C" } else { $null }
            Clock = if ($smiRow) { "$($smiRow.Clock) MHz" } elseif ($kd -and $kd.CoreMHz -gt 0) { "$($kd.CoreMHz) MHz (max $($kd.MaxCoreMHz))" } else { $null }
            MemClock = if ($kd -and $kd.MemMHz -gt 0) { "$($kd.MemMHz) MHz" } else { $null }
            Power = if ($smiRow) { "$($smiRow.Power) W" } elseif ($kd -and $kd.Power -gt 0) { "$($kd.Power) % of max" } else { $null }
            Fan   = if ($smiRow) { "$($smiRow.Fan) %" } elseif ($kd) { "$($kd.Fan) RPM" } else { $null }
            DriverAge = $age
            HasDeep = ([bool]$smiRow -or [bool]$kd)
        }
    }
    return ,$out
}

# --- Sentinel: scheduled background scout ------------------------------------
function Set-SentinelTask([bool]$Enabled, [string]$Freq) {
    $name = 'WarchiefDriverSentinel'
    try {
        if (-not $Enabled) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            return $true
        }
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -match 'powershell|pwsh') {
            $inst = Join-Path $env:LOCALAPPDATA 'Programs\Warchief Driver Updater\WarchiefDriverUpdater.exe'
            if (Test-Path $inst) { $exe = $inst }
        }
        $action   = New-ScheduledTaskAction -Execute $exe -Argument '-Scout'
        $at       = [datetime]::Today.AddHours(12)
        $trigger  = if ($Freq -eq 'Weekly') { New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $at }
                    else                     { New-ScheduledTaskTrigger -Daily -At $at }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        return $true
    } catch { return $false }
}
function Test-SentinelTask {
    try { return [bool](Get-ScheduledTask -TaskName 'WarchiefDriverSentinel' -ErrorAction SilentlyContinue) } catch { return $false }
}

# --- Toast notification (tray balloon) ---------------------------------------
function Show-Toast([string]$Title, [string]$Text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ico = Join-Path $script:ConfigDir "$($script:Config.Theme).ico"
        if (Test-Path $ico) { $ni.Icon = New-Object System.Drawing.Icon $ico }
        else { $ni.Icon = [System.Drawing.SystemIcons]::Information }
        $ni.Visible = $true
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText  = $Text
        $ni.ShowBalloonTip(10000)
        $end = (Get-Date).AddSeconds(9)
        while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
        $ni.Visible = $false; $ni.Dispose()
    } catch {}
}

# ===========================================================================
#  Headless Sentinel scout:  .\WarchiefDriverUpdater.ps1 -Scout
# ===========================================================================
if ($Scout) {
    $gpus = @(Get-GpuInventory | Where-Object { $_.Vendor -in 'NVIDIA', 'AMD', 'Intel' })
    $updates = @()
    foreach ($g in $gpus) {
        try {
            $r = if ($g.Vendor -eq 'NVIDIA') { Get-NvidiaLatest $g.Name $script:NvOsId ([bool]$script:Config.NvidiaStudio) }
                 elseif ($g.Vendor -eq 'Intel') { Get-IntelLatest $g.Name }
                 else { Get-AmdLatest $g.Name $script:AmdOsTag }
            if (-not $r.Error -and $r.Version) {
                $newer = $false; try { $newer = [version]$r.Version -gt [version]$g.Installed } catch {}
                if ($newer) { $updates += "$($g.Vendor) $($g.Name): v$($r.Version)" }
            }
        } catch {}
    }
    if ($updates) {
        Show-Toast 'New war gear available! ⚔' (($updates -join "`n") + "`n`nOpen Warchief Driver Updater to equip it.")
    }
    exit 0
}

# ---------------------------------------------------------------------------
#  Self-test mode:  .\WarchiefDriverUpdater.ps1 -SelfTest
# ---------------------------------------------------------------------------
if ($SelfTest) {
    Write-Host "== Warchief Driver Updater self-test (v$script:AppVersion) ==" -ForegroundColor Yellow
    Write-Host "OS build $script:OsBuild -> NVIDIA osID $script:NvOsId / AMD tag $script:AmdOsTag"
    Write-Host "Config: theme=$($script:Config.Theme) slimInstall=$($script:Config.SlimInstall) nvidiaStudio=$($script:Config.NvidiaStudio)"
    Write-Host "`n[Self-update] checking GitHub for the latest release..." -ForegroundColor Cyan
    try {
        $rel = Get-LatestReleaseInfo $script:GitHubRepo
        Write-Host "  Latest release: v$($rel.Version)  $(if ([version]$rel.Version -gt [version]$script:AppVersion) { '(NEWER - update available)' } else { '(up to date)' })"
        Write-Host "  Setup asset   : $($rel.SetupName)"
    } catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    $gpus = Get-GpuInventory
    if (-not $gpus) { Write-Host 'No supported GPUs found.'; exit 1 }
    foreach ($g in $gpus) {
        Write-Host "`n[$($g.Vendor)] $($g.Name)  (installed: $($g.Installed))" -ForegroundColor Cyan
        try {
            $r = if ($g.Vendor -eq 'NVIDIA') { Get-NvidiaLatest $g.Name $script:NvOsId $false }
                 elseif ($g.Vendor -eq 'AMD') { Get-AmdLatest $g.Name $script:AmdOsTag }
                 else { Get-IntelLatest $g.Name }
            if ($r.Error) { Write-Host "  ERROR: $($r.Error)" -ForegroundColor Red }
            else {
                Write-Host "  Latest : $($r.Version)  $(if($r.Date){"($($r.Date))"})"
                Write-Host "  URL    : $($r.Url)"
                Write-Host "  Notes  : $($r.Notes)"
            }
        } catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    }
    # sample lookups so every vendor path is exercised regardless of this rig
    $samples = @(
        @{ Label = 'AMD Radeon RX 7900 XTX (dGPU)';   Run = { Get-AmdLatest 'AMD Radeon RX 7900 XTX' $script:AmdOsTag } },
        @{ Label = 'AMD Radeon(TM) Graphics (APU)';    Run = { Get-AmdLatest 'AMD Radeon(TM) Graphics' $script:AmdOsTag } },
        @{ Label = 'Intel Arc A770';                   Run = { Get-IntelLatest 'Intel(R) Arc(TM) A770 Graphics' } },
        @{ Label = 'NVIDIA RTX 3060 (Studio driver)';  Run = { Get-NvidiaLatest 'NVIDIA GeForce RTX 3060' $script:NvOsId $true } }
    )
    foreach ($s in $samples) {
        Write-Host "`n[sample] $($s.Label)" -ForegroundColor Cyan
        try {
            $r = & $s.Run
            if ($r.Error) { Write-Host "  ERROR: $($r.Error)" -ForegroundColor Red }
            else { Write-Host "  Latest : $($r.Version) $(if($r.Title){"[$($r.Title)]"})"; Write-Host "  URL    : $($r.Url)" }
        } catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host "`n[7-Zip] resolver check" -ForegroundColor Cyan
    try { Write-Host "  Tool: $(Get-SevenZip $script:ConfigDir)" } catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    exit 0
}

# ---------------------------------------------------------------------------
#  GUI
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Wdu -Name NativeShell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);'

# ---------------------------------------------------------------------------
#  Faction icons: generated on first run, applied to the window/taskbar and to
#  the Start Menu / desktop shortcuts whenever the faction changes.
# ---------------------------------------------------------------------------
function New-FactionIcon([string]$Path, [string]$TopHex, [string]$BottomHex, [string]$BorderHex, [string]$GlyphHex, [int]$GlyphCode) {
    $sizes = 256, 64, 48, 32, 16
    $pngs  = @()
    foreach ($s in $sizes) {
        $bmp = New-Object Drawing.Bitmap($s, $s)
        $g   = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode     = 'AntiAlias'
        $g.TextRenderingHint = 'AntiAliasGridFit'

        $pad  = [Math]::Max(1, [int]($s * 0.03))
        $w    = $s - 2 * $pad - 1
        $rad  = [Math]::Max(2, [int]($s * 0.2))
        $rect = New-Object Drawing.Rectangle($pad, $pad, $w, $w)

        $gp = New-Object Drawing.Drawing2D.GraphicsPath
        $d  = $rad * 2
        $gp.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
        $gp.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
        $gp.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
        $gp.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
        $gp.CloseFigure()

        $fill = New-Object Drawing.Drawing2D.LinearGradientBrush(
            $rect,
            [Drawing.ColorTranslator]::FromHtml($TopHex),
            [Drawing.ColorTranslator]::FromHtml($BottomHex),
            [Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $g.FillPath($fill, $gp)

        $penW = [Math]::Max(1.0, $s * 0.045)
        $pen  = New-Object Drawing.Pen([Drawing.ColorTranslator]::FromHtml($BorderHex), $penW)
        $g.DrawPath($pen, $gp)

        $font  = New-Object Drawing.Font('Segoe UI Symbol', [float]($s * 0.62), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($GlyphHex))
        $sf    = New-Object Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $rf = New-Object Drawing.RectangleF(0, ($s * 0.02), $s, $s)
        $g.DrawString([string][char]$GlyphCode, $font, $brush, $rf, $sf)

        $g.Dispose(); $fill.Dispose(); $pen.Dispose(); $font.Dispose(); $brush.Dispose()

        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()
    }
    $fs = [IO.File]::Create($Path)
    $bw = New-Object IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Close(); $fs.Close()
}

$script:IconPaths = @{
    horde    = Join-Path $script:ConfigDir 'horde.ico'
    alliance = Join-Path $script:ConfigDir 'alliance.ico'
}
try {
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null }
    if (-not (Test-Path $script:IconPaths.horde))    { New-FactionIcon $script:IconPaths.horde    '#5C160C' '#120906' '#E5A93D' '#FFC94A' 0x2694 }  # crossed swords
    if (-not (Test-Path $script:IconPaths.alliance)) { New-FactionIcon $script:IconPaths.alliance '#16406E' '#060D18' '#E5C558' '#FFD766' 0x269C }  # fleur-de-lis
} catch {}

function Update-ShortcutIcons([string]$icoPath) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnks = @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Warchief Driver Updater.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Warchief Driver Updater.lnk')
        )
        $changed = $false
        foreach ($l in $lnks) {
            if (Test-Path $l) {
                $sc = $ws.CreateShortcut($l)
                $sc.IconLocation = "$icoPath,0"
                $sc.Save()
                $changed = $true
            }
        }
        # tell Explorer to refresh so the new sigil shows up right away
        if ($changed) { [Wdu.NativeShell]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero) }
    } catch {}
}

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Warchief Driver Updater"
        Width="780" Height="700" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanMinimize"
        Background="{DynamicResource WindowBg}" FontFamily="Palatino Linotype">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource GoldBright}"/>
      <Setter Property="FontFamily" Value="Palatino Linotype"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" BorderBrush="{DynamicResource AccentBorder}" BorderThickness="1"
                    Background="{DynamicResource BtnBg}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnBgHover}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource GoldBright}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource BtnDisabledFg}"/>
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnDisabledBg}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource BtnDisabledBorder}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="16"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border BorderBrush="{DynamicResource AccentBorder}" BorderThickness="1" Background="{DynamicResource BarTrack}">
              <Grid x:Name="PART_Track">
                <Rectangle x:Name="PART_Indicator" HorizontalAlignment="Left" Fill="{DynamicResource BarFill}"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Parchment}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>

  <Border BorderBrush="{DynamicResource AccentBorder}" BorderThickness="2">
    <DockPanel>
      <!-- title bar -->
      <Border DockPanel.Dock="Top" x:Name="TitleBar" Height="34" Background="{DynamicResource TitleBg}"
              BorderBrush="{DynamicResource PanelBorder}" BorderThickness="0,0,0,1">
        <DockPanel>
          <TextBlock x:Name="TitleBarText" Text="⚔ WARCHIEF DRIVER UPDATER" Foreground="{DynamicResource Gold}"
                     FontWeight="Bold" FontSize="13" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnUpdate" Content="⚡ UPDATE AVAILABLE" FontSize="11" Padding="10,4" Margin="0,0,8,0" Visibility="Collapsed"/>
            <Button x:Name="BtnFaction" Content="🦁 ALLIANCE" FontSize="11" Padding="10,4" Margin="0"/>
            <Button x:Name="BtnAbout" Content="ⓘ" Width="30" Padding="0,4" Margin="8,0,0,0" ToolTip="About &amp; license"/>
            <Button x:Name="BtnMin"   Content="—" Width="38" Padding="0,4" Margin="0"/>
            <Button x:Name="BtnClose" Content="✕" Width="38" Padding="0,4" Margin="0"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- banner -->
      <Border DockPanel.Dock="Top" Padding="20,14,20,8" Background="{DynamicResource BannerBg}">
        <StackPanel>
          <TextBlock x:Name="BannerTitle" Text="⚔  THE WARCHIEF'S ARMORY  ⚔" Foreground="{DynamicResource GoldBright}"
                     FontSize="24" FontWeight="Bold" HorizontalAlignment="Center"/>
          <TextBlock x:Name="BannerTagline" Text="Lok'tar ogar!" Foreground="{DynamicResource Dim}"
                     FontSize="13" FontStyle="Italic" HorizontalAlignment="Center" Margin="0,3,0,0"/>
        </StackPanel>
      </Border>

      <!-- nav bar -->
      <Border DockPanel.Dock="Top" Background="{DynamicResource TitleBg}" BorderBrush="{DynamicResource PanelBorder}"
              BorderThickness="0,1,0,1" Padding="10,5">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <Button x:Name="BtnNavArmory"   Content="⚔ ARMORY"   FontSize="12" Padding="12,5"/>
          <Button x:Name="BtnNavChest"    Content="🛡 WAR CHEST" FontSize="12" Padding="12,5"/>
          <Button x:Name="BtnNavRadar"    Content="🎮 RADAR"    FontSize="12" Padding="12,5"/>
          <Button x:Name="BtnNavCommand"  Content="📊 COMMAND"  FontSize="12" Padding="12,5"/>
          <Button x:Name="BtnNavSentinel" Content="📡 SENTINEL" FontSize="12" Padding="12,5" Margin="0"/>
        </StackPanel>
      </Border>

      <!-- footer -->
      <Border DockPanel.Dock="Bottom" Background="{DynamicResource TitleBg}"
              BorderBrush="{DynamicResource PanelBorder}" BorderThickness="0,1,0,0" Padding="16,10">
        <DockPanel>
          <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="🐺 SCOUT AGAIN" Margin="10,0,0,0"/>
          <CheckBox x:Name="ChkStudio" DockPanel.Dock="Right" Content="Studio driver" Margin="10,0,0,0"
                    ToolTip="NVIDIA only: fetch the Studio driver (for creative apps) instead of Game Ready"/>
          <CheckBox x:Name="ChkSlim" DockPanel.Dock="Right" Content="Slim install (no vendor apps)" Margin="10,0,0,0">
            <CheckBox.ToolTip>
              <ToolTip>
                <StackPanel MaxWidth="340">
                  <TextBlock FontWeight="Bold" Text="Driver-only install — skips the vendor app suite"/>
                  <TextBlock TextWrapping="Wrap" Margin="0,4,0,0"
                    Text="Installs ONLY the display driver + control panel, leaving out the NVIDIA App / GeForce Experience (or AMD Adrenalin) software."/>
                  <TextBlock FontWeight="Bold" Margin="0,6,0,0" Text="Why it helps:"/>
                  <TextBlock TextWrapping="Wrap" Text="• Saves disk space — often 500 MB to 1 GB+"/>
                  <TextBlock TextWrapping="Wrap" Text="• No background telemetry or account login"/>
                  <TextBlock TextWrapping="Wrap" Text="• Fewer auto-start services = less RAM, faster boot"/>
                  <TextBlock TextWrapping="Wrap" Text="• You still get the full driver and its control panel"/>
                  <TextBlock TextWrapping="Wrap" Text="• Intel packages are already lean, so they use the stock installer"/>
                  <TextBlock TextWrapping="Wrap" FontStyle="Italic" Margin="0,6,0,0"
                    Text="The exact amount saved is shown after install. Untick for the vendor's normal installer."/>
                </StackPanel>
              </ToolTip>
            </CheckBox.ToolTip>
          </CheckBox>
          <TextBlock x:Name="StatusBar" Text="Scouting the battlefield for war machines..."
                     Foreground="{DynamicResource Parchment}" FontSize="13" VerticalAlignment="Center"/>
        </DockPanel>
      </Border>

      <!-- content: five switchable views -->
      <Grid>
        <!-- ARMORY (drivers) -->
        <ScrollViewer x:Name="ViewArmory" VerticalScrollBarVisibility="Auto" Padding="20,12">
          <StackPanel x:Name="CardPanel"/>
        </ScrollViewer>

        <!-- WAR CHEST (backup + rollback) -->
        <ScrollViewer x:Name="ViewChest" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="20,12">
          <StackPanel>
            <TextBlock Text="🛡 THE WAR CHEST" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource GoldBright}"/>
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Dim}" Margin="0,4,0,10"
                       Text="Your saved war gear. If a new driver betrays you in battle, re-equip a proven one — or roll the whole rig back to a restore point."/>
            <CheckBox x:Name="ChkRestorePoint" Foreground="{DynamicResource Parchment}"
                      Content="Create a system restore point before each driver install (recommended)"
                      ToolTip="Uses Windows' built-in System Restore — one admin prompt before the install. Windows only allows one restore point per 24h, so repeat installs may skip it."/>
            <TextBlock Text="⚔ Saved drivers" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource Gold}" Margin="0,14,0,4"/>
            <TextBlock x:Name="ChestEmpty" Text="No saved drivers yet — install one and it'll be kept here so you can revert."
                       Foreground="{DynamicResource Dim}" FontStyle="Italic" TextWrapping="Wrap"/>
            <StackPanel x:Name="ChestList"/>
            <TextBlock Text="🕮 Restore points made by this app" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource Gold}" Margin="0,16,0,4"/>
            <StackPanel x:Name="RestoreList"/>
            <Button x:Name="BtnOpenRestore" Content="Open Windows System Restore" HorizontalAlignment="Left" Margin="0,8,0,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- RADAR (game ready) -->
        <ScrollViewer x:Name="ViewRadar" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="20,12">
          <StackPanel>
            <TextBlock Text="🎮 GAME READY RADAR" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource GoldBright}"/>
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Dim}" Margin="0,4,0,10"
                       Text="Which of your installed games the newest driver tunes up. The radar reads the library files your launchers already keep on disk (Steam's manifests, plus games registered by Battle.net, Epic, Ubisoft, EA, Riot and friends) — nothing new is installed — and cross-checks them against the vendor's official release notes."/>
            <Button x:Name="BtnScanGames" Content="🔍 SWEEP THE BATTLEFIELD (SCAN GAMES)" HorizontalAlignment="Left"/>
            <TextBlock x:Name="RadarSummary" TextWrapping="Wrap" Foreground="{DynamicResource Parchment}" Margin="0,10,0,6"/>
            <StackPanel x:Name="RadarList"/>
          </StackPanel>
        </ScrollViewer>

        <!-- COMMAND CENTER (live stats) -->
        <ScrollViewer x:Name="ViewCommand" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="20,12">
          <StackPanel>
            <TextBlock Text="📊 RIG COMMAND CENTER" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource GoldBright}"/>
            <TextBlock x:Name="CmdHint" TextWrapping="Wrap" Foreground="{DynamicResource Dim}" Margin="0,4,0,10"
                       Text="Live readings from your war machines. Updates every couple of seconds while this page is open."/>
            <StackPanel x:Name="StatPanel"/>
          </StackPanel>
        </ScrollViewer>

        <!-- SENTINEL (auto-scout + tray) -->
        <ScrollViewer x:Name="ViewSentinel" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="20,12">
          <StackPanel>
            <TextBlock Text="📡 THE SENTINEL" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource GoldBright}"/>
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Dim}" Margin="0,4,0,10"
                       Text="Stand a watch so you never miss new war gear. The Sentinel quietly checks for new drivers on your schedule and sounds the horn when one drops."/>
            <CheckBox x:Name="ChkAutoScout" Foreground="{DynamicResource Parchment}"
                      Content="Let the Sentinel scout for new drivers automatically"/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <TextBlock Text="How often:" Foreground="{DynamicResource Parchment}" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <ComboBox x:Name="CmbFreq" Width="130">
                <ComboBoxItem Content="Every day"/>
                <ComboBoxItem Content="Every week"/>
              </ComboBox>
            </StackPanel>
            <CheckBox x:Name="ChkTray" Foreground="{DynamicResource Parchment}" Margin="0,12,0,0"
                      Content="Keep a sentinel in the system tray while running (minimize to tray instead of closing)"/>
            <TextBlock x:Name="SentinelStatus" TextWrapping="Wrap" Foreground="{DynamicResource Dim}" Margin="0,14,0,0"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>
    </DockPanel>
  </Border>
</Window>
'@

$cardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Margin="0,0,0,16" BorderBrush="{DynamicResource PanelBorder}" BorderThickness="2"
        Background="{DynamicResource PanelBg}">
  <Border BorderBrush="{DynamicResource InnerBorder}" BorderThickness="1" Padding="16,14">
    <StackPanel>
      <DockPanel>
        <Border x:Name="VendorBadge" DockPanel.Dock="Right" BorderThickness="1" Padding="8,2" VerticalAlignment="Center">
          <TextBlock x:Name="VendorText" FontSize="11" FontWeight="Bold"/>
        </Border>
        <TextBlock x:Name="GpuName" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource GoldBright}"/>
      </DockPanel>
      <Grid Margin="0,10,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="170"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition/><RowDefinition/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Grid.Column="0" Text="Equipped driver:" Foreground="{DynamicResource Dim}" FontSize="13"/>
        <TextBlock Grid.Row="0" Grid.Column="1" x:Name="InstalledText" Foreground="{DynamicResource Parchment}" FontSize="13" FontWeight="Bold"/>
        <TextBlock Grid.Row="1" Grid.Column="0" Text="Newest from the forge:" Foreground="{DynamicResource Dim}" FontSize="13" Margin="0,4,0,0"/>
        <TextBlock Grid.Row="1" Grid.Column="1" x:Name="LatestText" Text="scouting..." Foreground="{DynamicResource Parchment}" FontSize="13" FontWeight="Bold" Margin="0,4,0,0"/>
      </Grid>
      <TextBlock x:Name="StatusText" Margin="0,10,0,0" FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Dim}" Text="⏳ Scouts are riding..." TextWrapping="Wrap"/>
      <ProgressBar x:Name="Bar" Margin="0,10,0,0" Minimum="0" Maximum="100" Visibility="Collapsed"/>
      <TextBlock x:Name="DlInfo" Margin="0,4,0,0" FontSize="12" Foreground="{DynamicResource Dim}" Visibility="Collapsed"/>
      <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
        <Button x:Name="BtnAction" Content="⚒ FORGE (DOWNLOAD)" IsEnabled="False"/>
        <Button x:Name="BtnNotes"  Content="📜 WAR SCROLLS (NOTES)" IsEnabled="False"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Border>
'@

$window = [Windows.Markup.XamlReader]::Parse($mainXaml)
foreach ($n in 'TitleBar','TitleBarText','BannerTitle','BannerTagline','BtnUpdate','BtnFaction','BtnAbout','BtnMin','BtnClose','BtnRefresh','ChkSlim','ChkStudio','StatusBar','CardPanel',
                'BtnNavArmory','BtnNavChest','BtnNavRadar','BtnNavCommand','BtnNavSentinel',
                'ViewArmory','ViewChest','ViewRadar','ViewCommand','ViewSentinel',
                'ChkRestorePoint','ChestEmpty','ChestList','RestoreList','BtnOpenRestore',
                'BtnScanGames','RadarSummary','RadarList','CmdHint','StatPanel',
                'ChkAutoScout','CmbFreq','ChkTray','SentinelStatus') {
    Set-Variable -Name $n -Value $window.FindName($n)
}

$TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnClose.Add_Click({ $window.Close() })

# minimize-to-tray (opt-in via the Sentinel page)
Add-Type -AssemblyName System.Windows.Forms
$script:TrayIcon = $null
function Show-TrayIcon {
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $true; return }
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ico = Join-Path $script:ConfigDir "$($script:Config.Theme).ico"
    $ni.Icon = if (Test-Path $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Application }
    $ni.Text = 'Warchief Driver Updater — the sentinel stands watch'
    $ni.Add_MouseDoubleClick({
        $window.Show(); $window.WindowState = 'Normal'; $window.Activate()
        if ($script:TrayIcon) { $script:TrayIcon.Visible = $false }
    })
    $ni.Visible = $true
    $script:TrayIcon = $ni
}
$window.Add_StateChanged({
    if ($window.WindowState -eq 'Minimized' -and $script:Config.MinimizeToTray) {
        $window.Hide()
        Show-TrayIcon
    }
})

# GPL "Appropriate Legal Notices": copyright + no-warranty + license link
$BtnAbout.Add_Click({
    $msg = "Warchief Driver Updater  v$script:AppVersion`n`n" +
           "Copyright (C) 2026 dontshome`n`n" +
           "This program comes with ABSOLUTELY NO WARRANTY.`n" +
           "It is free software, and you are welcome to redistribute it under " +
           "the terms of the GNU General Public License v3 or later.`n`n" +
           "If you reuse this code, the GPL requires your project to remain " +
           "open source and to credit this original work.`n`n" +
           "Source & license:`nhttps://github.com/$script:GitHubRepo`n`n" +
           "Open the project page now?"
    $r = [Windows.MessageBox]::Show($msg, 'About Warchief Driver Updater', 'YesNo', 'Information')
    if ($r -eq 'Yes') { Start-Process "https://github.com/$script:GitHubRepo" }
})

# ---------------------------------------------------------------------------
#  Theming
# ---------------------------------------------------------------------------
$script:BrushConv = New-Object Windows.Media.BrushConverter
function New-SolidBrush([string]$hex) {
    $b = $script:BrushConv.ConvertFromString($hex); $b.Freeze(); return $b
}
function New-VerticalGradient([string]$topHex, [string]$bottomHex) {
    $b = New-Object Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object Windows.Point 0, 0
    $b.EndPoint   = New-Object Windows.Point 0, 1
    $s1 = New-Object Windows.Media.GradientStop
    $s1.Color = [Windows.Media.ColorConverter]::ConvertFromString($topHex); $s1.Offset = 0.0
    $s2 = New-Object Windows.Media.GradientStop
    $s2.Color = [Windows.Media.ColorConverter]::ConvertFromString($bottomHex); $s2.Offset = 1.0
    $b.GradientStops.Add($s1); $b.GradientStops.Add($s2)
    $b.Freeze(); return $b
}

function Set-Theme([string]$name) {
    $t = $script:Themes[$name]
    $script:T = $t
    $script:Config.Theme = $name
    Save-AppConfig

    # note: the [Windows.Media.Brush] casts matter — PowerShell wraps function
    # return values in PSObject, which WPF rejects when resolving the resource
    $R = $window.Resources
    foreach ($k in 'WindowBg','TitleBg','PanelBg','PanelBorder','InnerBorder','AccentBorder','Gold','GoldBright','Parchment','Dim','BtnDisabledBg','BtnDisabledBorder','BtnDisabledFg','BarTrack') {
        $R[$k] = [Windows.Media.Brush](New-SolidBrush $t[$k])
    }
    $R['BtnBg']      = [Windows.Media.Brush](New-VerticalGradient $t.BtnTop $t.BtnBottom)
    $R['BtnBgHover'] = [Windows.Media.Brush](New-VerticalGradient $t.BtnHoverTop $t.BtnHoverBottom)
    $R['BarFill']    = [Windows.Media.Brush](New-VerticalGradient $t.BarTop $t.BarBottom)
    $R['BannerBg']   = [Windows.Media.Brush](New-VerticalGradient $t.BannerTop $t.WindowBg)

    $TitleBarText.Text  = $t.TitleBarText
    $BannerTitle.Text   = $t.Title
    $BannerTagline.Text = $t.Tagline
    $BtnRefresh.Content = $t.ScoutLabel
    $BtnFaction.Content = $t.SwitchLabel

    # swap the window/taskbar icon and repaint the Start Menu / desktop shortcuts
    $ico = $script:IconPaths[$name]
    if ($ico -and (Test-Path $ico)) {
        try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ico) } catch {}
        Update-ShortcutIcons $ico
    }

    # re-word any "up to date" cards so they don't keep praising the other faction
    if ($script:Cards) {
        foreach ($c in $script:Cards.Values) {
            if ($c.IsUpToDate) { $c.StatusText.Text = $t.UpToDate }
        }
    }
}

$BtnFaction.Add_Click({
    $next = if ($script:Config.Theme -eq 'horde') { 'alliance' } else { 'horde' }
    Set-Theme $next
    $StatusBar.Text = if ($next -eq 'horde') { 'You have joined the Horde. Lok''tar ogar!' } else { 'You have joined the Alliance. For the King!' }
})

$ChkSlim.IsChecked = [bool]$script:Config.SlimInstall
$ChkSlim.Add_Click({
    $script:Config.SlimInstall = [bool]$ChkSlim.IsChecked
    Save-AppConfig
})

$ChkStudio.IsChecked = [bool]$script:Config.NvidiaStudio
$ChkStudio.Add_Click({
    $script:Config.NvidiaStudio = [bool]$ChkStudio.IsChecked
    Save-AppConfig
    Start-Scan   # Game Ready vs Studio changes the answer — scout again
})

# ---------------------------------------------------------------------------
#  Navigation between the five views
# ---------------------------------------------------------------------------
$script:Views = @{
    Armory   = @{ View = $ViewArmory;   Btn = $BtnNavArmory }
    Chest    = @{ View = $ViewChest;    Btn = $BtnNavChest }
    Radar    = @{ View = $ViewRadar;    Btn = $BtnNavRadar }
    Command  = @{ View = $ViewCommand;  Btn = $BtnNavCommand }
    Sentinel = @{ View = $ViewSentinel; Btn = $BtnNavSentinel }
}
$script:CurrentView = 'Armory'
function Show-View([string]$name) {
    foreach ($k in $script:Views.Keys) {
        $script:Views[$k].View.Visibility = if ($k -eq $name) { 'Visible' } else { 'Collapsed' }
        $script:Views[$k].Btn.Opacity     = if ($k -eq $name) { 1.0 } else { 0.55 }
    }
    $script:CurrentView = $name
    # driver-specific footer controls only make sense on the Armory page
    $footerVis = if ($name -eq 'Armory') { 'Visible' } else { 'Collapsed' }
    $ChkSlim.Visibility = $footerVis; $ChkStudio.Visibility = $footerVis; $BtnRefresh.Visibility = $footerVis
    switch ($name) {
        'Chest'    { Update-WarChestView }
        'Command'  { Update-CommandView }
        'Sentinel' { Update-SentinelStatus }
    }
}
$BtnNavArmory.Add_Click({ Show-View 'Armory' })
$BtnNavChest.Add_Click({ Show-View 'Chest' })
$BtnNavRadar.Add_Click({ Show-View 'Radar' })
$BtnNavCommand.Add_Click({ Show-View 'Command' })
$BtnNavSentinel.Add_Click({ Show-View 'Sentinel' })

# ---------------------------------------------------------------------------
#  War Chest view
# ---------------------------------------------------------------------------
$ChkRestorePoint.IsChecked = [bool]$script:Config.RestorePoint
$ChkRestorePoint.Add_Click({ $script:Config.RestorePoint = [bool]$ChkRestorePoint.IsChecked; Save-AppConfig })
$BtnOpenRestore.Add_Click({ try { Start-Process 'rstrui.exe' } catch {} })

function New-ChestRow($entry) {
    $b = New-Object Windows.Controls.Border
    $b.BorderBrush = $window.Resources['PanelBorder']; $b.BorderThickness = 1
    $b.Background = $window.Resources['PanelBg']; $b.Margin = '0,0,0,8'; $b.Padding = '12,8'
    $dp = New-Object Windows.Controls.DockPanel
    $btn = New-Object Windows.Controls.Button
    $btn.Content = '⚔ RE-EQUIP'; $btn.Margin = '10,0,0,0'; $btn.Tag = $entry
    [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
    $btn.Add_Click({ param($s,$e) Invoke-Reequip $s.Tag })
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Foreground = $window.Resources['Parchment']; $tb.VerticalAlignment = 'Center'; $tb.TextWrapping = 'Wrap'
    $tb.Inlines.Add((New-Object Windows.Documents.Run("$($entry.Vendor)  v$($entry.Version)") -Property @{ FontWeight='Bold'; Foreground=$window.Resources['GoldBright'] }))
    $tb.Inlines.Add("   $($entry.Gpu)   ·   installed $($entry.Date)")
    [void]$dp.Children.Add($btn); [void]$dp.Children.Add($tb)
    $b.Child = $dp; return $b
}

function Update-WarChestView {
    $ChestList.Children.Clear()
    $chest = @(Get-WarChest)
    $ChestEmpty.Visibility = if ($chest.Count) { 'Collapsed' } else { 'Visible' }
    foreach ($e in $chest) { [void]$ChestList.Children.Add((New-ChestRow $e)) }

    $RestoreList.Children.Clear()
    $rps = @(Get-AppRestorePoints)
    if (-not $rps.Count) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = 'None to show — one is made automatically before each install (if enabled above). Note: Windows only lets elevated apps LIST restore points, so this stays empty unless you run the app as administrator; the points themselves are still created and usable from System Restore.'
        $t.Foreground = $window.Resources['Dim']; $t.FontStyle = 'Italic'; $t.TextWrapping = 'Wrap'
        [void]$RestoreList.Children.Add($t)
    } else {
        foreach ($rp in $rps) {
            $when = ''
            try { $when = [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime).ToString('yyyy-MM-dd HH:mm') } catch {}
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = "• $($rp.Description)   $when"
            $t.Foreground = $window.Resources['Parchment']; $t.Margin = '0,0,0,3'
            [void]$RestoreList.Children.Add($t)
        }
    }
}

function Invoke-Reequip($entry) {
    $r = [Windows.MessageBox]::Show(
        "Re-equip $($entry.Vendor) driver v$($entry.Version)?`n`nThis re-runs that version's installer so you can roll back from a driver that's giving you trouble.",
        'War Chest — Re-equip', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    if ($entry.LocalPath -and (Test-Path $entry.LocalPath)) {
        try { Start-Process $entry.LocalPath; $StatusBar.Text = "Re-equipping v$($entry.Version)..." } catch { $StatusBar.Text = "Couldn't launch installer: $($_.Exception.Message)" }
    } elseif ($entry.Url) {
        $StatusBar.Text = "Re-downloading v$($entry.Version) to re-equip..."
        $script:Sync.ReUrl = $entry.Url
        $script:Sync.ReDest = Join-Path (Get-DownloadFolder) ([IO.Path]::GetFileName(([uri]$entry.Url).AbsolutePath))
        $script:Sync.ReActive = $true
        $script:Sync.ReDlDone = $false; $script:Sync.ReDlError = $null
        $script:Sync.ReDlBytes = 0L; $script:Sync.ReDlTotal = 0L
        $ref = if ($entry.Vendor -eq 'AMD') { 'https://www.amd.com/' } else { $null }
        $script:Sync.ReRef = $ref
        Start-BackgroundScript 'Invoke-FileDownload $sync.ReUrl $sync.ReDest $sync $sync.ReRef "Re"'
    } else {
        [void][Windows.MessageBox]::Show('That saved driver has no installer or download link on record.', 'War Chest', 'OK', 'Warning')
    }
}

# ---------------------------------------------------------------------------
#  Radar view
# ---------------------------------------------------------------------------
$BtnScanGames.Add_Click({ Invoke-GameScan })
function Invoke-GameScan {
    $RadarList.Children.Clear()
    $RadarSummary.Text = 'Sweeping your libraries and reading the vendor release notes...'
    $BtnScanGames.IsEnabled = $false
    $window.Dispatcher.Invoke([action]{}, 'Background')

    $games = @(Get-InstalledGames)
    # use the first card of ANY vendor that has a release-notes URL
    $notesUrl = $null
    foreach ($c in $script:Cards.Values) {
        if ($c.NotesUrl) { $notesUrl = $c.NotesUrl; break }
    }
    $notes = (Get-DriverNotesText $notesUrl).ToLower()

    $matched = @()
    foreach ($g in $games) {
        $isOpt = $false
        if ($notes) {
            $key = ($g.Name -replace '[^\w ]', '').Trim().ToLower()
            if ($key.Length -ge 4 -and $notes.Contains($key)) { $isOpt = $true }
        }
        if ($isOpt) { $matched += $g.Name }
        [void]$RadarList.Children.Add((New-RadarRow $g.Name $g.Platform $isOpt))
    }
    $BtnScanGames.IsEnabled = $true
    if (-not $games.Count) {
        $RadarSummary.Text = "No installed games detected (I look at Steam + major launchers). Install a game or check Steam is set up."
    } elseif (-not $notes) {
        $RadarSummary.Text = "Found $($games.Count) installed game(s). Couldn't read this driver's release notes to match optimizations — showing your library."
    } elseif ($matched.Count) {
        $RadarSummary.Text = "⚔ The newest driver's notes call out $($matched.Count) game(s) you have installed: $($matched -join ', ')."
    } else {
        $RadarSummary.Text = "Found $($games.Count) installed game(s). The newest driver's notes don't specifically mention any of them (still worth updating for general fixes)."
    }
}
function New-RadarRow([string]$name, [string]$platform, [bool]$optimized) {
    $b = New-Object Windows.Controls.Border
    $b.BorderBrush = $window.Resources['PanelBorder']; $b.BorderThickness = 1
    $b.Background = $window.Resources['PanelBg']; $b.Margin = '0,0,0,6'; $b.Padding = '12,7'
    $dp = New-Object Windows.Controls.DockPanel
    $badge = New-Object Windows.Controls.TextBlock
    [Windows.Controls.DockPanel]::SetDock($badge, 'Right'); $badge.VerticalAlignment = 'Center'; $badge.FontWeight = 'Bold'; $badge.FontSize = 12
    if ($optimized) { $badge.Text = '🔥 TUNED BY LATEST'; $badge.Foreground = ($script:BrushConv.ConvertFromString($script:ColUpdate)) }
    else            { $badge.Text = $platform;            $badge.Foreground = $window.Resources['Dim'] }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $name; $tb.Foreground = $window.Resources['Parchment']; $tb.VerticalAlignment = 'Center'; $tb.TextTrimming = 'CharacterEllipsis'
    [void]$dp.Children.Add($badge); [void]$dp.Children.Add($tb)
    $b.Child = $dp; return $b
}

# ---------------------------------------------------------------------------
#  Command Center view (live stats; updated by the main pump when visible)
# ---------------------------------------------------------------------------
function Update-CommandView {
    $rows = @(Get-GpuLiveStats)
    $StatPanel.Children.Clear()
    if (-not $rows.Count) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = 'No GPUs detected.'; $t.Foreground = $window.Resources['Dim']
        [void]$StatPanel.Children.Add($t)
        return
    }
    foreach ($r in $rows) { [void]$StatPanel.Children.Add((New-StatCard $r)) }
    $CmdHint.Text = 'All readings come from Windows itself: GPU perf counters plus the same WDDM telemetry Task Manager uses (temp/clock/power/fan, any vendor with a WDDM 2.4+ driver). NVIDIA cards get extra precision via nvidia-smi. Updates every few seconds.'
}
function New-StatCard($r) {
    $b = New-Object Windows.Controls.Border
    $b.BorderBrush = $window.Resources['PanelBorder']; $b.BorderThickness = 2
    $b.Background = $window.Resources['PanelBg']; $b.Margin = '0,0,0,12'; $b.Padding = '16,12'
    $sp = New-Object Windows.Controls.StackPanel
    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $r.Name; $title.FontWeight = 'Bold'; $title.FontSize = 16; $title.Foreground = $window.Resources['GoldBright']; $title.Margin = '0,0,0,8'
    [void]$sp.Children.Add($title)
    $ageTxt = if ($null -ne $r.DriverAge) { "$($r.DriverAge) day$(if ($r.DriverAge -ne 1) {'s'}) old" } else { $null }
    $stats = @(
        @('📈 GPU usage',  $r.Util),
        @('🧠 VRAM',       $r.Vram),
        @('🌡 Temperature',$r.Temp),
        @('🎛 Core clock', $r.Clock),
        @('📼 Memory clock', $r.MemClock),
        @('⚡ Power draw', $r.Power),
        @('🌀 Fan',        $r.Fan),
        @('🗓 Driver age', $ageTxt)
    )
    foreach ($s in $stats) {
        if (-not $s[1]) { continue }   # only show what this vendor actually exposes
        $g = New-Object Windows.Controls.Grid
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '150'
        $c2 = New-Object Windows.Controls.ColumnDefinition
        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
        $l = New-Object Windows.Controls.TextBlock; $l.Text = $s[0]; $l.Foreground = $window.Resources['Dim']; $l.FontSize = 13; $l.Margin = '0,2,0,2'
        $v = New-Object Windows.Controls.TextBlock; $v.Text = $s[1]; $v.Foreground = $window.Resources['Parchment']; $v.FontSize = 13; $v.FontWeight = 'Bold'; $v.Margin = '0,2,0,2'
        [Windows.Controls.Grid]::SetColumn($v, 1)
        [void]$g.Children.Add($l); [void]$g.Children.Add($v)
        [void]$sp.Children.Add($g)
    }
    if (-not $r.HasDeep) {
        $note = New-Object Windows.Controls.TextBlock
        $note.TextWrapping = 'Wrap'; $note.FontStyle = 'Italic'; $note.FontSize = 11.5
        $note.Foreground = $window.Resources['Dim']; $note.Margin = '0,6,0,0'
        $note.Text = "This GPU's driver doesn't report sensor telemetry to Windows (needs a WDDM 2.4+ driver, Win10 1803+). Usage, VRAM and driver age are shown instead."
        [void]$sp.Children.Add($note)
    }
    $b.Child = $sp; return $b
}

# ---------------------------------------------------------------------------
#  Sentinel view
# ---------------------------------------------------------------------------
$ChkAutoScout.IsChecked = [bool]$script:Config.AutoScout
$CmbFreq.SelectedIndex  = if ($script:Config.ScoutFreq -eq 'Weekly') { 1 } else { 0 }
$ChkTray.IsChecked      = [bool]$script:Config.MinimizeToTray
function Apply-SentinelTask {
    $freq = if ($CmbFreq.SelectedIndex -eq 1) { 'Weekly' } else { 'Daily' }
    $script:Config.AutoScout = [bool]$ChkAutoScout.IsChecked
    $script:Config.ScoutFreq = $freq
    Save-AppConfig
    $ok = Set-SentinelTask ([bool]$ChkAutoScout.IsChecked) $freq
    if (-not $ok) {
        [void][Windows.MessageBox]::Show("Couldn't update the scheduled task. You can still scout manually.", 'Sentinel', 'OK', 'Warning')
    }
    Update-SentinelStatus
}
$ChkAutoScout.Add_Click({ Apply-SentinelTask })
$CmbFreq.Add_SelectionChanged({ if ($ChkAutoScout.IsChecked) { Apply-SentinelTask } else { $script:Config.ScoutFreq = $(if ($CmbFreq.SelectedIndex -eq 1) {'Weekly'} else {'Daily'}); Save-AppConfig } })
$ChkTray.Add_Click({ $script:Config.MinimizeToTray = [bool]$ChkTray.IsChecked; Save-AppConfig })
function Update-SentinelStatus {
    $on = Test-SentinelTask
    $freq = if ($script:Config.ScoutFreq -eq 'Weekly') { 'every Monday' } else { 'every day' }
    $SentinelStatus.Text = if ($on) {
        "🟢 Sentinel is standing watch — scouting $freq around noon. You'll get a tray notification when new war gear drops."
    } else {
        "⚪ Sentinel is off. Enable it above to be alerted automatically when a new driver is released."
    }
}

Set-Theme $script:Config.Theme
Show-View 'Armory'

# ---------------------------------------------------------------------------
#  App state
# ---------------------------------------------------------------------------
$script:Cards = @{}                                   # index -> UI refs + state
$script:Sync  = [hashtable]::Synchronized(@{})        # cross-runspace mailbox
$script:Runspaces = New-Object Collections.ArrayList  # keep-alive references

function Start-BackgroundScript([string]$ScriptText) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:NetFunctions + "`n" + $ScriptText)
    [void]$ps.BeginInvoke()
    [void]$script:Runspaces.Add(@{ PS = $ps; RS = $rs })
}

function Get-DownloadFolder {
    $p = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path $p) { return $p }
    return $env:TEMP
}

function New-GpuCard($gpu) {
    $card = [Windows.Markup.XamlReader]::Parse($cardXaml)
    $refs = @{}
    foreach ($n in 'VendorBadge','VendorText','GpuName','InstalledText','LatestText','StatusText','Bar','DlInfo','BtnAction','BtnNotes') {
        $refs[$n] = $card.FindName($n)
    }
    $refs.GpuName.Text       = $gpu.Name
    $refs.InstalledText.Text = if ($gpu.Installed) { "$($gpu.Installed)" } else { 'unknown' }
    $refs.VendorText.Text    = $gpu.Vendor
    switch ($gpu.Vendor) {
        'NVIDIA' { $refs.VendorText.Foreground = '#76B900'; $refs.VendorBadge.BorderBrush = '#76B900' }
        'AMD'    { $refs.VendorText.Foreground = '#ED1C24'; $refs.VendorBadge.BorderBrush = '#ED1C24' }
        'Intel'  { $refs.VendorText.Foreground = '#00A3F5'; $refs.VendorBadge.BorderBrush = '#00A3F5' }
        default  { $refs.VendorText.Foreground = '#8A7A5C'; $refs.VendorBadge.BorderBrush = '#8A7A5C' }
    }
    $refs.State     = 'checking'
    $refs.Gpu       = $gpu
    $refs.BtnAction.Tag = $gpu.Index
    $refs.BtnNotes.Tag  = $gpu.Index

    $refs.BtnAction.Add_Click({
        param($s, $e)
        Invoke-ActionButton ([int]$s.Tag)
    })
    $refs.BtnNotes.Add_Click({
        param($s, $e)
        $c = $script:Cards[[int]$s.Tag]
        if ($c.NotesUrl) { Start-Process $c.NotesUrl }
    })

    $script:Cards[$gpu.Index] = $refs
    [void]$CardPanel.Children.Add($card)
}

function Invoke-ActionButton([int]$idx) {
    $c = $script:Cards[$idx]
    switch ($c.State) {
        'ready' {   # start download
            if ($script:Sync.DlActive) { return }
            $folder = Get-DownloadFolder
            $file   = [IO.Path]::GetFileName(([uri]$c.Url).AbsolutePath)
            if (-not $file) { $file = "driver-$idx.exe" }
            $dest   = Join-Path $folder $file

            $script:Sync.DlActive = $true
            $script:Sync.DlIndex  = $idx
            $script:Sync.DlBytes  = 0L
            $script:Sync.DlTotal  = 0L
            $script:Sync.DlDone   = $false
            $script:Sync.DlError  = $null
            $script:Sync.DlPath   = $null
            $script:Sync.DlUrl    = $c.Url
            $script:Sync.DlDest   = $dest
            $script:Sync.DlRef    = $c.Referer

            $c.Bar.Visibility    = 'Visible'
            $c.DlInfo.Visibility = 'Visible'
            $c.DlInfo.Text       = 'The forge is lit...'
            $c.BtnAction.IsEnabled = $false
            $c.StatusText.Text = '⚒ FORGING NEW WEAPON...'
            $c.StatusText.Foreground = $script:ColWarn
            $StatusBar.Text = "Downloading to $dest"

            Start-BackgroundScript 'Invoke-FileDownload $sync.DlUrl $sync.DlDest $sync $sync.DlRef'
        }
        'downloaded' {  # (optional restore point first, then) launch installer
            if ($ChkRestorePoint.IsChecked -and -not $script:Sync.RpActive) {
                $script:Sync.RpActive = $true
                $script:Sync.RpIndex  = $idx
                $script:Sync.RpDone   = $false
                $script:Sync.RpError  = $null
                $script:Sync.RpDesc   = "Warchief before $($c.Gpu.Vendor) driver $($c.LatestVersion)"
                $c.BtnAction.IsEnabled = $false
                $c.StatusText.Text = '🛡 Raising a fallback camp (system restore point) — approve the admin prompt...'
                $c.StatusText.Foreground = $script:ColWarn
                $StatusBar.Text = 'Creating a restore point before the install (can take up to a minute)...'
                Start-BackgroundScript 'New-WarchiefRestorePoint $sync.RpDesc $sync'
                return   # the timer continues to Invoke-InstallPhase when the camp is up
            }
            Invoke-InstallPhase $idx
        }
        'manual' {
            if ($c.NotesUrl) { Start-Process $c.NotesUrl }
        }
    }
}

# the actual install launch, shared by the direct path and the post-restore-point path
function Invoke-InstallPhase([int]$idx) {
    $c = $script:Cards[$idx]
    # record what we're equipping so the War Chest can offer it for rollback later
    if ($c.LatestVersion) { Add-WarChestEntry $c.Gpu.Vendor $c.Gpu.Name $c.LatestVersion $c.Url $c.FilePath }

    # the AMD "minimalsetup" web installer has no packages inside to slim down
    $slimable = ($c.Gpu.Vendor -eq 'NVIDIA') -or
                ($c.Gpu.Vendor -eq 'AMD' -and $c.FilePath -notmatch 'minimalsetup')
    if ($ChkSlim.IsChecked -and $slimable) {
                if ($script:Sync.SlimActive) { return }
                $script:Sync.SlimActive = $true
                $script:Sync.SlimIndex  = $idx
                $script:Sync.SlimDone   = $false
                $script:Sync.SlimError  = $null
                $script:Sync.SlimExit   = $null
                $script:Sync.SlimSaved  = 0L
                $script:Sync.SlimStatus = 'Preparing the smithy...'
                $script:Sync.SlimExe    = $c.FilePath
                $script:Sync.SlimTools  = $script:ConfigDir

                $c.BtnAction.IsEnabled = $false
                $c.StatusText.Text = '⚒ Stripping the bloat from the war gear...'
                $c.StatusText.Foreground = $script:ColWarn
                $c.Bar.Value = 0
                $c.Bar.Visibility    = 'Visible'
                $c.DlInfo.Visibility = 'Visible'
                $c.DlInfo.Text       = 'The smithy is at work — this takes a few minutes. A dialog will announce victory.'

                if ($c.Gpu.Vendor -eq 'NVIDIA') {
                    $script:Sync.SlimDir = Join-Path $env:TEMP 'WarchiefNvSlim'
                    $StatusBar.Text = 'Slim NVIDIA install: unpacking driver package...'
                    Start-BackgroundScript 'Invoke-NvidiaSlimInstall $sync.SlimExe $sync.SlimDir $sync $sync.SlimTools'
                } else {
                    $script:Sync.SlimDir = Join-Path $env:TEMP 'WarchiefAmdSlim'
                    $StatusBar.Text = 'Slim AMD install: unpacking driver package (big one, hang tight)...'
                    Start-BackgroundScript 'Invoke-AmdSlimInstall $sync.SlimExe $sync.SlimDir $sync $sync.SlimTools'
                }
    } else {
        try {
            Start-Process -FilePath $c.FilePath
            $StatusBar.Text = 'Installer launched. Victory awaits, champion!'
        } catch {
            $StatusBar.Text = "Could not launch installer: $($_.Exception.Message)"
        }
    }
}

function Format-Bytes([long]$b) {
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    return '{0:N0} KB' -f ($b / 1KB)
}

function Test-UpdateAvailable([string]$installed, [string]$latest) {
    try { return ([version]$latest -gt [version]$installed) } catch { return $null }
}

function Apply-CheckResult([int]$idx, $r) {
    $c = $script:Cards[$idx]
    if ($r.Error) {
        $c.LatestText.Text = 'unknown'
        $c.StatusText.Text = "☠ $($r.Error)"
        $c.StatusText.Foreground = $script:ColErr
        if ($r.Notes) {
            $c.NotesUrl = $r.Notes
            $c.State = 'manual'
            $c.BtnAction.Content = '🌐 OPEN VENDOR SITE'
            $c.BtnAction.IsEnabled = $true
            $c.BtnNotes.IsEnabled = $true
        }
        return
    }
    $c.Url           = $r.Url
    $c.NotesUrl      = $r.Notes
    $c.Referer       = $r.Referer
    $c.LatestVersion = $r.Version
    $extra = @(); if ($r.Date) { $extra += $r.Date }; if ($r.Size) { $extra += $r.Size }
    $c.LatestText.Text = "$($r.Version)" + $(if ($extra) { "   ($($extra -join ', '))" })
    $c.BtnNotes.IsEnabled = [bool]$r.Notes

    $upd = Test-UpdateAvailable $c.Gpu.Installed $r.Version
    if ($upd -eq $true) {
        $c.StatusText.Text = '🔥 NEW WAR GEAR AVAILABLE!'
        $c.StatusText.Foreground = $script:ColUpdate
        $c.State = 'ready'
        $c.BtnAction.IsEnabled = $true
    } elseif ($upd -eq $false) {
        $c.IsUpToDate = $true
        $c.StatusText.Text = $script:T.UpToDate
        $c.StatusText.Foreground = $script:ColGood
        $c.State = 'ready'   # allow re-download anyway
        $c.BtnAction.IsEnabled = $true
        $c.BtnAction.Content = '⚒ REFORGE (RE-DOWNLOAD)'
    } else {
        $c.StatusText.Text = '⚑ Could not compare versions — inspect the war scrolls.'
        $c.StatusText.Foreground = $script:ColWarn
        $c.State = 'ready'
        $c.BtnAction.IsEnabled = $true
    }
}

function Start-Scan {
    $CardPanel.Children.Clear()
    $script:Cards = @{}
    $script:Sync.CheckDone = $false
    $BtnRefresh.IsEnabled = $false

    $gpus = @(Get-GpuInventory | Where-Object { $_.Vendor -in 'NVIDIA','AMD','Intel' })
    if (-not $gpus) {
        $StatusBar.Text = 'No NVIDIA, AMD, or Intel war machines found in this rig.'
        $BtnRefresh.IsEnabled = $true
        $script:Sync.CheckDone = $true
        return
    }
    foreach ($g in $gpus) { New-GpuCard $g }
    $StatusBar.Text = "Found $($gpus.Count) war machine$(if($gpus.Count -gt 1){'s'}). Scouts riding to the vendors' keeps..."

    $script:Sync.Gpus     = @($gpus | ForEach-Object { @{ Index = $_.Index; Name = $_.Name; Vendor = $_.Vendor } })
    $script:Sync.NvOs     = $script:NvOsId
    $script:Sync.AmdOs    = $script:AmdOsTag
    $script:Sync.NvStudio = [bool]$ChkStudio.IsChecked
    foreach ($g in $gpus) { $script:Sync.Remove("result$($g.Index)") }

    Start-BackgroundScript @'
foreach ($g in $sync.Gpus) {
    $r = $null
    try {
        if     ($g.Vendor -eq 'NVIDIA') { $r = Get-NvidiaLatest $g.Name $sync.NvOs $sync.NvStudio }
        elseif ($g.Vendor -eq 'Intel')  { $r = Get-IntelLatest $g.Name }
        else                            { $r = Get-AmdLatest $g.Name $sync.AmdOs }
    } catch { $r = @{ Error = $_.Exception.Message } }
    $sync["result$($g.Index)"] = $r
}
$sync.CheckDone = $true
'@
}

$BtnRefresh.Add_Click({ Start-Scan })

# ---------------------------------------------------------------------------
#  Self-update check: ask GitHub for the newest release once at startup.
#  Never downloads or installs anything by itself - only offers a button.
# ---------------------------------------------------------------------------
function Start-UpdateCheck {
    $script:Sync.UpdateChecked = $false
    $script:Sync.UpdateRepo    = $script:GitHubRepo
    Start-BackgroundScript @'
try { $sync.UpdateInfo = Get-LatestReleaseInfo $sync.UpdateRepo } catch { $sync.UpdateInfo = $null }
$sync.UpdateChecked = $true
'@
}

$BtnUpdate.Add_Click({
    $info = $script:Sync.UpdateInfo
    if (-not $info) { return }
    $r = [Windows.MessageBox]::Show(
        "A newer version is available!`n`nYou have: v$script:AppVersion`nLatest:   v$($info.Version)`n`nDownload and install it now? (Yes)`nor just open the release page to grab it yourself (No)?",
        'Warchief Driver Updater - Update Available', 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return }
    if ($r -eq 'No') { Start-Process $info.HtmlUrl; return }

    if (-not $info.SetupUrl) {
        [void][Windows.MessageBox]::Show("Couldn't find the installer in that release. Opening the release page instead.", 'Warchief Driver Updater', 'OK', 'Warning')
        Start-Process $info.HtmlUrl
        return
    }

    $BtnUpdate.IsEnabled = $false
    $BtnUpdate.Content = '⚡ DOWNLOADING...'
    $script:Sync.UpdDlActive = $true
    $script:Sync.UpdDlDone   = $false
    $script:Sync.UpdDlError  = $null
    $script:Sync.UpdDlBytes  = 0L
    $script:Sync.UpdDlTotal  = 0L
    $script:Sync.UpdUrl      = $info.SetupUrl
    $script:Sync.UpdDest     = Join-Path $env:TEMP $info.SetupName
    $StatusBar.Text = "Downloading v$($info.Version)..."
    Start-BackgroundScript 'Invoke-FileDownload $sync.UpdUrl $sync.UpdDest $sync $null "Upd"'
})

# ---------------------------------------------------------------------------
#  UI pump: applies background results every 150 ms
# ---------------------------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    try {
    # driver check results
    foreach ($idx in @($script:Cards.Keys)) {
        $c = $script:Cards[$idx]
        if ($c.State -eq 'checking' -and $script:Sync.ContainsKey("result$idx")) {
            Apply-CheckResult $idx $script:Sync["result$idx"]
        }
    }
    if ($script:Sync.CheckDone -and -not $BtnRefresh.IsEnabled) {
        $BtnRefresh.IsEnabled = $true
        $pending = @($script:Cards.Values | Where-Object { $_.State -eq 'checking' })
        if (-not $pending) { $StatusBar.Text = $script:T.ScanDone }
    }

    # download progress
    if ($script:Sync.DlActive) {
        $idx = $script:Sync.DlIndex
        $c = $script:Cards[$idx]
        if ($c) {
            $total = [long]$script:Sync.DlTotal
            $bytes = [long]$script:Sync.DlBytes
            if ($total -gt 0) {
                $c.Bar.Value = [Math]::Round(100.0 * $bytes / $total, 1)
                $c.DlInfo.Text = "$(Format-Bytes $bytes) / $(Format-Bytes $total)  ($($c.Bar.Value)%)"
            }
            if ($script:Sync.DlDone) {
                $script:Sync.DlActive = $false
                if ($script:Sync.DlError) {
                    $c.StatusText.Text = "☠ The forge failed: $($script:Sync.DlError)"
                    $c.StatusText.Foreground = $script:ColErr
                    $c.BtnAction.IsEnabled = $true
                    $c.Bar.Visibility = 'Collapsed'; $c.DlInfo.Visibility = 'Collapsed'
                    $StatusBar.Text = 'Download failed. Rally and try again.'
                } else {
                    $c.FilePath = $script:Sync.DlPath
                    $c.State = 'downloaded'
                    $c.Bar.Value = 100
                    $c.StatusText.Text = '⚔ WEAPON FORGED! Ready to equip.'
                    $c.StatusText.Foreground = $script:ColGood
                    $c.BtnAction.Content = '⚔ EQUIP (INSTALL)'
                    $c.BtnAction.IsEnabled = $true
                    $StatusBar.Text = "Saved to $($c.FilePath)"
                }
            }
        }
    }

    # self-update check result (once, at startup)
    if ($script:Sync.UpdateChecked) {
        $script:Sync.UpdateChecked = $false   # consume once
        $info = $script:Sync.UpdateInfo
        if ($info -and $info.Version) {
            $isNewer = $false
            try { $isNewer = ([version]$info.Version -gt [version]$script:AppVersion) } catch {}
            if ($isNewer) {
                $BtnUpdate.Content = "⚡ UPDATE TO v$($info.Version)"
                $BtnUpdate.Visibility = 'Visible'
            }
        }
    }

    # self-update download progress
    if ($script:Sync.UpdDlActive) {
        $total = [long]$script:Sync.UpdDlTotal
        $bytes = [long]$script:Sync.UpdDlBytes
        if ($total -gt 0) {
            $pct = [Math]::Round(100.0 * $bytes / $total, 0)
            $StatusBar.Text = "Downloading update: $(Format-Bytes $bytes) / $(Format-Bytes $total)  ($pct%)"
        }
        if ($script:Sync.UpdDlDone) {
            $script:Sync.UpdDlActive = $false
            if ($script:Sync.UpdDlError) {
                $BtnUpdate.IsEnabled = $true
                $BtnUpdate.Content = "⚡ UPDATE TO v$($script:Sync.UpdateInfo.Version)"
                $StatusBar.Text = 'Update download failed. Try again, or grab it from the release page.'
                [void][Windows.MessageBox]::Show(
                    "Couldn't download the update: $($script:Sync.UpdDlError)`n`nOpening the release page instead.",
                    'Warchief Driver Updater', 'OK', 'Error')
                Start-Process $script:Sync.UpdateInfo.HtmlUrl
            } else {
                $StatusBar.Text = 'Launching the new installer...'
                Start-Process $script:Sync.UpdDest
                $window.Close()
            }
        }
    }

    # restore point finished -> continue into the actual install
    if ($script:Sync.RpActive -and $script:Sync.RpDone) {
        $script:Sync.RpActive = $false
        $idx = $script:Sync.RpIndex
        $c = $script:Cards[$idx]
        if ($c) {
            if ($script:Sync.RpError) {
                $c.StatusText.Text = "⚑ Couldn't raise the fallback camp ($($script:Sync.RpError)) — marching on without it."
                $c.StatusText.Foreground = $script:ColWarn
            } else {
                $StatusBar.Text = 'Fallback camp raised. Beginning the install...'
            }
            $c.BtnAction.IsEnabled = $true
            Invoke-InstallPhase $idx
        }
    }

    # War Chest re-equip download
    if ($script:Sync.ReActive) {
        $total = [long]$script:Sync.ReDlTotal; $bytes = [long]$script:Sync.ReDlBytes
        if ($total -gt 0) { $StatusBar.Text = "Re-downloading old driver: $(Format-Bytes $bytes) / $(Format-Bytes $total)" }
        if ($script:Sync.ReDlDone) {
            $script:Sync.ReActive = $false
            if ($script:Sync.ReDlError) {
                $StatusBar.Text = "Re-download failed: $($script:Sync.ReDlError)"
            } else {
                try { Start-Process $script:Sync.ReDest; $StatusBar.Text = 'Old war gear installer launched — follow its steps to roll back.' }
                catch { $StatusBar.Text = "Couldn't launch installer: $($_.Exception.Message)" }
            }
        }
    }

    # Command Center live refresh (~every 5 s while that page is open;
    # Get-Counter costs a few hundred ms on the UI thread, so keep it sparse)
    $script:CmdTick = ($script:CmdTick + 1) % 33
    if ($script:CurrentView -eq 'Command' -and $script:CmdTick -eq 0 -and -not $script:CmdBusy) {
        $script:CmdBusy = $true
        try { Update-CommandView } finally { $script:CmdBusy = $false }
    }

    # slim install progress (both vendors)
    if ($script:Sync.SlimActive) {
        $idx = $script:Sync.SlimIndex
        $c = $script:Cards[$idx]
        if ($c) {
            if (-not $script:Sync.SlimDone) {
                $c.StatusText.Text = "⚒ $($script:Sync.SlimStatus)"
                $c.Bar.Value = ($c.Bar.Value + 2) % 100   # marching bar while the smithy works
            } else {
                $script:Sync.SlimActive = $false
                $c.BtnAction.IsEnabled = $true
                if ($script:Sync.SlimError) {
                    $c.Bar.Visibility = 'Collapsed'; $c.DlInfo.Visibility = 'Collapsed'
                    $c.StatusText.Text = "☠ Slim install failed: $($script:Sync.SlimError)"
                    $c.StatusText.Foreground = $script:ColErr
                    $StatusBar.Text = 'Slim install failed — untick the slim option to run the stock installer.'
                    [void][Windows.MessageBox]::Show(
                        "The slim install failed:`n`n$($script:Sync.SlimError)`n`nUntick the slim option to use the vendor's stock installer instead.",
                        'Warchief Driver Updater', 'OK', 'Error')
                } else {
                    # interpret the installer's exit code
                    $code = $script:Sync.SlimExit
                    $ok = $false; $reboot = $false
                    if ($c.Gpu.Vendor -eq 'NVIDIA') {
                        if ($code -eq 0) { $ok = $true }
                        elseif ($code -eq 1) { $ok = $true; $reboot = $true }
                    } else {
                        if ($code -eq 0) { $ok = $true }
                        elseif ($code -eq 3) { $ok = $true; $reboot = $true }
                    }
                    if ($ok) {
                        $saved = [long]$script:Sync.SlimSaved
                        $savedTxt = if ($saved -gt 0) { Format-Bytes $saved } else { $null }
                        $c.Bar.Value = 100
                        $c.DlInfo.Text = if ($savedTxt) { "Skipped $savedTxt of vendor apps." } else { 'Victory!' }
                        $c.StatusText.Text = "⚔ NEW WAR GEAR EQUIPPED!$(if ($savedTxt) { " Trimmed $savedTxt of bloat." } else { ' Driver installed.' })$(if ($reboot) { ' Reboot to seal the deal.' })"
                        $c.StatusText.Foreground = $script:ColGood
                        $StatusBar.Text = if ($savedTxt) { "Driver installed — $savedTxt of vendor apps skipped. The forge burns clean!" } else { 'Driver installed without the vendor bloat. The forge burns clean!' }
                        [void][Windows.MessageBox]::Show(
                            "$($c.Gpu.Name)`n`nNew war gear equipped — the driver was installed without the vendor's extra apps.$(if ($savedTxt) { "`n`nSlim install skipped about $savedTxt of NVIDIA App / GeForce Experience / vendor software — less disk used, no background telemetry, fewer auto-start processes." })$(if ($reboot) { "`n`nA reboot is required to finish." })`n`nVictory, champion!",
                            'Warchief Driver Updater', 'OK', 'Information')
                    } else {
                        $c.Bar.Visibility = 'Collapsed'; $c.DlInfo.Visibility = 'Collapsed'
                        $c.StatusText.Text = "☠ Installer finished with exit code $code — the driver may not be installed."
                        $c.StatusText.Foreground = $script:ColErr
                        $StatusBar.Text = 'Installer reported a problem. Untick slim install to try the stock installer.'
                        [void][Windows.MessageBox]::Show(
                            "The driver installer finished with exit code $code, which signals a problem.`n`nUntick the slim option to run the vendor's stock installer instead.",
                            'Warchief Driver Updater', 'OK', 'Warning')
                    }
                }
            }
        }
    }
    } catch {
        # never let a transient failure (WMI hiccup, race on a closing window)
        # crash the whole app from inside the UI pump
        try { $StatusBar.Text = "⚑ $($_.Exception.Message)" } catch {}
    }
})
$timer.Start()

$window.Add_ContentRendered({ Start-Scan; Start-UpdateCheck })
[void]$window.ShowDialog()

# cleanup
$timer.Stop()
if ($script:TrayIcon) { try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch {} }
foreach ($r in $script:Runspaces) {
    try { $r.PS.Stop(); $r.PS.Dispose(); $r.RS.Close() } catch {}
}
