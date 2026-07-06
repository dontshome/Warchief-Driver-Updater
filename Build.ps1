<#
    Build script for Warchief Driver Updater.
    Produces:
      dist\WarchiefDriverUpdater.exe        - the app (GUI, no console)
      dist\WarchiefDriverUpdater-Setup.exe  - installer (Start Menu shortcut,
                                              uninstall entry in Windows Settings)
    Requires the ps2exe module (auto-installed to CurrentUser if missing).

    Usage:  powershell -ExecutionPolicy Bypass -File .\Build.ps1
#>
param(
    [switch]$SkipInstaller,
    [string]$Version = '1.3.1'
)
$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist   = Join-Path $root 'dist'
$assets = Join-Path $root 'assets'
New-Item -ItemType Directory -Force -Path $dist, $assets | Out-Null

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host 'Installing ps2exe module (CurrentUser)...'
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

# ---------------------------------------------------------------------------
# Icon: dark rounded shield, gold border, crossed-swords glyph. Generated
# programmatically so the repo needs no binary assets checked in.
# ---------------------------------------------------------------------------
function New-FactionIcon([string]$Path, [string]$TopHex, [string]$BottomHex, [string]$BorderHex, [string]$GlyphHex, [int]$GlyphCode) {
    Add-Type -AssemblyName System.Drawing
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
        $sf.Alignment     = 'Center'
        $sf.LineAlignment = 'Center'
        $rf = New-Object Drawing.RectangleF(0, ($s * 0.02), $s, $s)
        $g.DrawString([string][char]$GlyphCode, $font, $brush, $rf, $sf)

        $g.Dispose(); $fill.Dispose(); $pen.Dispose(); $font.Dispose(); $brush.Dispose()

        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()
    }

    # pack the PNGs into a .ico container
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

# horde = red + crossed swords, alliance = blue + fleur-de-lis (same palettes as the app)
$icon         = Join-Path $assets 'horde.ico'
$allianceIcon = Join-Path $assets 'alliance.ico'
if (-not (Test-Path $icon)) {
    Write-Host 'Generating Horde icon...'
    New-FactionIcon $icon '#5C160C' '#120906' '#E5A93D' '#FFC94A' 0x2694
}
if (-not (Test-Path $allianceIcon)) {
    Write-Host 'Generating Alliance icon...'
    New-FactionIcon $allianceIcon '#16406E' '#060D18' '#E5C558' '#FFD766' 0x269C
}

# ---------------------------------------------------------------------------
# 1) the app itself
# ---------------------------------------------------------------------------
$appExe = Join-Path $dist 'WarchiefDriverUpdater.exe'

# Windows PowerShell 5.1 mis-reads BOM-less UTF-8 as ANSI (mangles the emoji),
# so make sure the source is saved UTF-8 WITH BOM before compiling.
$srcPath = Join-Path $root 'WarchiefDriverUpdater.ps1'
$srcBytes = [IO.File]::ReadAllBytes($srcPath)
if ($srcBytes.Length -lt 3 -or $srcBytes[0] -ne 0xEF -or $srcBytes[1] -ne 0xBB -or $srcBytes[2] -ne 0xBF) {
    Write-Host 'Adding UTF-8 BOM to source...'
    $text = [Text.Encoding]::UTF8.GetString($srcBytes)
    [IO.File]::WriteAllText($srcPath, $text, [Text.UTF8Encoding]::new($true))
}

Write-Host "Compiling app -> $appExe"
Invoke-PS2EXE -inputFile (Join-Path $root 'WarchiefDriverUpdater.ps1') -outputFile $appExe `
    -iconFile $icon -noConsole -STA `
    -title 'Warchief Driver Updater' -description 'Horde-themed GPU driver updater' `
    -company 'Warchief Driver Updater contributors' -product 'Warchief Driver Updater' `
    -copyright 'MIT License' -version "$Version.0"
if (-not (Test-Path $appExe)) { throw 'App compilation failed.' }

# ---------------------------------------------------------------------------
# 2) the installer (app exe embedded as base64 payload)
# ---------------------------------------------------------------------------
if (-not $SkipInstaller) {
    $setupExe = Join-Path $dist 'WarchiefDriverUpdater-Setup.exe'
    Write-Host "Compiling installer -> $setupExe"
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($appExe))
    $tpl = [IO.File]::ReadAllText((Join-Path $root 'Installer.template.ps1'))
    $src = $tpl.Replace('__PAYLOAD_B64__', $b64).Replace('__VERSION__', $Version)
    $tmp = Join-Path $env:TEMP 'wdu-installer-gen.ps1'
    [IO.File]::WriteAllText($tmp, $src, [Text.UTF8Encoding]::new($true))
    try {
        Invoke-PS2EXE -inputFile $tmp -outputFile $setupExe `
            -iconFile $icon -noConsole -STA `
            -title 'Warchief Driver Updater Setup' -description 'Installer for Warchief Driver Updater' `
            -company 'Warchief Driver Updater contributors' -product 'Warchief Driver Updater' `
            -copyright 'MIT License' -version "$Version.0"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $setupExe)) { throw 'Installer compilation failed.' }
}

Write-Host "`nBuild complete. Artifacts in $dist" -ForegroundColor Green
Get-ChildItem $dist | Format-Table Name, @{n='Size (KB)'; e={[int]($_.Length/1KB)}}
