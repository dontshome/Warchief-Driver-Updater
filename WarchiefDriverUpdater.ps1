<#
    ⚔  WARCHIEF DRIVER UPDATER  ⚔
    A Warcraft-faction-themed GPU driver checker & downloader for Windows.
    Detects NVIDIA / AMD GPUs, checks the vendors' own servers for the
    newest driver, and downloads it with one click. Pick your side:
    Horde or Alliance. Lok'tar ogar!

    "Slim NVIDIA install" unpacks NVIDIA's driver package and installs the
    display driver WITHOUT the NVIDIA App / GeForce Experience / telemetry.

    Unofficial fan project. Not affiliated with Blizzard, NVIDIA or AMD.
    License: MIT
#>
param(
    [switch]$SelfTest   # run headless diagnostics (no GUI) and exit
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# ---------------------------------------------------------------------------
#  Shared constants & config
# ---------------------------------------------------------------------------
$script:UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$script:OsBuild  = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$script:NvOsId   = if ($script:OsBuild -ge 22000) { 135 } else { 57 }   # 135 = Win11, 57 = Win10 x64
$script:AmdOsTag = if ($script:OsBuild -ge 22000) { 'win11' } else { 'win10' }

$script:ConfigDir  = Join-Path $env:APPDATA 'WarchiefDriverUpdater'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'

function Get-AppConfig {
    $cfg = @{ Theme = 'horde'; SlimInstall = $true; NvidiaStudio = $false }
    try {
        if (Test-Path $script:ConfigPath) {
            $saved = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if ($saved.Theme -in 'horde', 'alliance') { $cfg.Theme = $saved.Theme }
            if ($null -ne $saved.SlimInstall) { $cfg.SlimInstall = [bool]$saved.SlimInstall }
            elseif ($null -ne $saved.SlimNvidia) { $cfg.SlimInstall = [bool]$saved.SlimNvidia }  # pre-1.2 config
            if ($null -ne $saved.NvidiaStudio) { $cfg.NvidiaStudio = [bool]$saved.NvidiaStudio }
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
function Invoke-FileDownload([string]$Url, [string]$Dest, $Sync, [string]$Referer) {
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UA
        if ($Referer) { $req.Referer = $Referer }
        $resp = $req.GetResponse()
        $Sync.DlTotal = $resp.ContentLength
        $in  = $resp.GetResponseStream()
        $out = [IO.File]::Create($Dest)
        try {
            $buf = New-Object byte[] 262144
            $done = 0L
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                $Sync.DlBytes = $done
            }
        } finally { $out.Close(); $in.Close(); $resp.Close() }
        $Sync.DlPath = $Dest
    } catch {
        $Sync.DlError = $_.Exception.Message
        try { if (Test-Path $Dest) { Remove-Item $Dest -Force } } catch {}
    }
    $Sync.DlDone = $true
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
        $bloat = @('GFExperience*', 'NvApp*', 'NVApp*', 'NvTelemetry*', 'FrameViewSDK',
                   'Update.Core', 'NvBackend', 'ShadowPlay', 'ShieldWirelessController', 'GfeSDK*', 'nodejs')
        $szArgs = @('x', $ExePath, "-o$WorkDir", '-y') + ($bloat | ForEach-Object { "-xr!$_" })
        & $sz @szArgs | Out-Null
        if ($LASTEXITCODE -gt 1) { throw "7-Zip failed with exit code $LASTEXITCODE." }
        if (-not (Test-Path (Join-Path $WorkDir 'setup.exe'))) { throw 'setup.exe not found after extraction.' }

        # remove manifest references to files that lived in the stripped folders
        $cfg = Join-Path $WorkDir 'setup.cfg'
        if (Test-Path $cfg) {
            $txt = [IO.File]::ReadAllText($cfg)
            $txt = [regex]::Replace($txt, '(?m)^.*\$\{\{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile|GDPR[^}]*)\}\}.*\r?\n', '')
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

# ---------------------------------------------------------------------------
#  Self-test mode:  .\WarchiefDriverUpdater.ps1 -SelfTest
# ---------------------------------------------------------------------------
if ($SelfTest) {
    Write-Host "== Warchief Driver Updater self-test ==" -ForegroundColor Yellow
    Write-Host "OS build $script:OsBuild -> NVIDIA osID $script:NvOsId / AMD tag $script:AmdOsTag"
    Write-Host "Config: theme=$($script:Config.Theme) slimInstall=$($script:Config.SlimInstall) nvidiaStudio=$($script:Config.NvidiaStudio)"
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
            <Button x:Name="BtnFaction" Content="🦁 ALLIANCE" FontSize="11" Padding="10,4" Margin="0"/>
            <Button x:Name="BtnMin"   Content="—" Width="38" Padding="0,4" Margin="0"/>
            <Button x:Name="BtnClose" Content="✕" Width="38" Padding="0,4" Margin="0"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- banner -->
      <Border DockPanel.Dock="Top" Padding="20,16,20,12" Background="{DynamicResource BannerBg}">
        <StackPanel>
          <TextBlock x:Name="BannerTitle" Text="⚔  THE WARCHIEF'S ARMORY  ⚔" Foreground="{DynamicResource GoldBright}"
                     FontSize="26" FontWeight="Bold" HorizontalAlignment="Center"/>
          <TextBlock x:Name="BannerTagline" Text="Lok'tar ogar!" Foreground="{DynamicResource Dim}"
                     FontSize="14" FontStyle="Italic" HorizontalAlignment="Center" Margin="0,4,0,0"/>
        </StackPanel>
      </Border>

      <!-- footer -->
      <Border DockPanel.Dock="Bottom" Background="{DynamicResource TitleBg}"
              BorderBrush="{DynamicResource PanelBorder}" BorderThickness="0,1,0,0" Padding="16,10">
        <DockPanel>
          <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="🐺 SCOUT AGAIN" Margin="10,0,0,0"/>
          <CheckBox x:Name="ChkStudio" DockPanel.Dock="Right" Content="Studio driver" Margin="10,0,0,0"
                    ToolTip="NVIDIA only: fetch the Studio driver (for creative apps) instead of Game Ready"/>
          <CheckBox x:Name="ChkSlim" DockPanel.Dock="Right" Content="Slim install (no vendor apps)" Margin="10,0,0,0"
                    ToolTip="Driver-only install: strips the NVIDIA App / GeForce Experience or AMD Adrenalin software"/>
          <TextBlock x:Name="StatusBar" Text="Scouting the battlefield for war machines..."
                     Foreground="{DynamicResource Parchment}" FontSize="13" VerticalAlignment="Center"/>
        </DockPanel>
      </Border>

      <!-- GPU cards -->
      <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="20,12">
        <StackPanel x:Name="CardPanel"/>
      </ScrollViewer>
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
foreach ($n in 'TitleBar','TitleBarText','BannerTitle','BannerTagline','BtnFaction','BtnMin','BtnClose','BtnRefresh','ChkSlim','ChkStudio','StatusBar','CardPanel') {
    Set-Variable -Name $n -Value $window.FindName($n)
}

$TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnClose.Add_Click({ $window.Close() })

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

Set-Theme $script:Config.Theme

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
        'downloaded' {  # launch installer (slim/driver-only path when enabled)
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
        'manual' {
            if ($c.NotesUrl) { Start-Process $c.NotesUrl }
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
    $c.Url      = $r.Url
    $c.NotesUrl = $r.Notes
    $c.Referer  = $r.Referer
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
#  UI pump: applies background results every 150 ms
# ---------------------------------------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
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
                        $c.Bar.Value = 100
                        $c.DlInfo.Text = 'Victory!'
                        $c.StatusText.Text = "⚔ NEW WAR GEAR EQUIPPED! Driver installed$(if ($reboot) { ' — reboot to seal the deal' })."
                        $c.StatusText.Foreground = $script:ColGood
                        $StatusBar.Text = 'Driver installed without the vendor bloat. The forge burns clean!'
                        [void][Windows.MessageBox]::Show(
                            "$($c.Gpu.Name)`n`nNew war gear equipped — the driver was installed without the vendor's extra apps.$(if ($reboot) { "`n`nA reboot is required to finish." })`n`nVictory, champion!",
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
})
$timer.Start()

$window.Add_ContentRendered({ Start-Scan })
[void]$window.ShowDialog()

# cleanup
$timer.Stop()
foreach ($r in $script:Runspaces) {
    try { $r.PS.Stop(); $r.PS.Dispose(); $r.RS.Close() } catch {}
}
