# ⚔ Warchief Driver Updater

**Lok'tar ogar!** A Horde-themed, zero-dependency GPU driver checker & downloader for Windows.
Detects your NVIDIA / AMD graphics cards, asks the vendors' own servers for the newest driver,
and forges (downloads) it for you with one click — all wrapped in a dark iron-and-gold war room UI.

> Unofficial fan project. Not affiliated with or endorsed by Blizzard Entertainment, NVIDIA, or AMD.
> World of Warcraft and the Horde are trademarks of Blizzard Entertainment.

## Features

- ⚔🦁 **Pick your faction** — one click in the title bar switches between the **Horde** theme
  (black iron, blood red, gold) and the **Alliance** theme (royal blue, gold, silver). Your
  choice is remembered between sessions, and the **window, taskbar, Start Menu and desktop
  icons all change sigils** with it (red crossed swords vs. blue fleur-de-lis).
- 🧹 **Slim install — no NVIDIA App, no Adrenalin app** — optional (on by default):
  - **NVIDIA:** unpacks the driver package with 7-Zip, strips out the NVIDIA App / GeForce
    Experience / telemetry components, patches the install manifest, and runs a quiet
    driver-only install (same technique as NVCleanstall).
  - **AMD:** unpacks the Adrenalin package without `Packages\Apps` and uses AMD's own
    documented silent installer (`Setup.exe -INSTALL -USE <Packages\Drivers>`) for a
    driver-only install with no Adrenalin software.
  - Either way you get a progress bar while the smithy works and a clear victory (or defeat)
    dialog when the installer finishes, with the real installer exit code checked.
  - Uses your installed 7-Zip if present, otherwise fetches the official standalone `7zr.exe`
    (~600 KB) on first use. Untick the checkbox any time to get the stock installer instead.
- 🐺 **Auto-scouting** — detects every NVIDIA/AMD GPU in your rig via WMI, including the
  human-readable installed driver version (e.g. `560.94`, not `32.0.15.6094`).
- ⚒ **Straight from the forge** — queries **NVIDIA's official driver lookup API** and **AMD's
  official per-product driver pages**. No third-party mirrors, downloads come directly from
  `download.nvidia.com` / `drivers.amd.com`.
- 🧠 **Smart matching** — maps your exact GPU name to NVIDIA's product IDs (desktop vs. laptop
  handled automatically) and derives the correct AMD product page from the model number.
  Detects Windows 10 vs. 11 and picks the right installer (WHQL, DCH).
- 🔥 **Update status at a glance** — `BATTLE READY` when you're current, `NEW WAR GEAR AVAILABLE`
  when the vendors have shipped something newer.
- 📜 **War scrolls** — one click to the official release notes.
- ⚔ **Forge & equip** — downloads with a rage-bar progress meter to your Downloads folder, then
  launches the installer on demand. Nothing is installed silently, ever.
- 🪶 **Zero dependencies** — pure PowerShell 5.1 + WPF. No Node, no Python, no runtime installs.
  Works on any stock Windows 10/11 machine.

## Getting started

**Option A — installer (recommended):** grab `WarchiefDriverUpdater-Setup.exe` from the
[Releases](../../releases) page, run it, and you're done. You get a Start Menu (and optional
desktop) shortcut, plus a normal uninstall entry in *Windows Settings → Apps → Installed apps*.
The installer also supports `-Silent` for unattended installs and `-Uninstall [-Silent]`.

**Option B — portable:** clone the repo and double-click **`Start Warchief Driver Updater.bat`**
(or a built `WarchiefDriverUpdater.exe`). No installation needed.

Either way: the armory opens, scouts ride out, and you'll see whether new war gear awaits.

> **SmartScreen note:** the exes are compiled from this repo's PowerShell source with
> [ps2exe](https://github.com/MScholtes/PS2EXE) and are not code-signed, so Windows SmartScreen
> may show "unknown publisher" the first time. Click *More info → Run anyway*, or build the exe
> yourself from source (see below) if you'd rather trust your own build.

## Building the exe yourself

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1
```

This auto-installs the [ps2exe](https://www.powershellgallery.com/packages/ps2exe) module
(CurrentUser scope), generates the icon in `assets\`, and drops both
`WarchiefDriverUpdater.exe` and `WarchiefDriverUpdater-Setup.exe` into `dist\`.

No admin rights are needed to check or download; the driver installer itself will ask for
elevation when you click **EQUIP (INSTALL)** — that prompt comes from NVIDIA/AMD's installer,
not from this tool.

## Headless self-test

For debugging or CI, run the built-in diagnostics (no GUI):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WarchiefDriverUpdater.ps1 -SelfTest
```

It prints detected GPUs, installed versions, and the latest driver + download URL each vendor reports.

## How it works

| Vendor | Latest-version source | Download source |
|---|---|---|
| NVIDIA | `nvidia.com/Download/API/lookupValueSearch.aspx` (GPU → product IDs), then the `AjaxDriverService` JSON API | `us.download.nvidia.com` (direct link from the API) |
| AMD | The official per-GPU driver page on `amd.com` (server-rendered; scraped for the Adrenalin version) | `drivers.amd.com` (direct link from that page, sent with the required referer) |

Installed versions come from `Win32_VideoController` (NVIDIA's friendly version is decoded from
the WMI version string) and, for AMD, the `RadeonSoftwareVersion` registry value.

## Known limits

- AMD's website layout can change; if the scraper can't find your card's page, the tool falls
  back to an **OPEN VENDOR SITE** button instead of guessing.
- AMD integrated graphics (Ryzen APUs) and Intel GPUs aren't matched yet — PRs welcome.
- NVIDIA results are Game Ready WHQL drivers; a Studio-driver toggle is on the wish list.

## Contributing

Issues and pull requests are welcome. Keep it dependency-free, keep it Horde. 🩸

## License

[MIT](LICENSE)
