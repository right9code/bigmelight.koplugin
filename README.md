# Bigme Light Control — KOReader Plugin

Control the **Bigme HiBreak / B6** front light (cold and warm channels) from inside KOReader, using the plugin menu or swipe gestures.

The plugin talks directly to the TI **LM3630A** dual-string LED driver through root, and installs its own helper script on demand. **No PC or manual `adb push` is required.**

## Features

- **Zero-latency direct sysfs I/O** — sets permissions on startup so swipe gestures write directly (<1ms) without spawning subshells or causing UI lag (with seamless root fallback).
- **Power management** — turns off front lights during device sleep/standby to prevent battery drain, and restores them on resume.
- **Custom presets & touch dialog** — built-in presets (Daytime, Reading, Bedtime) that you can edit, plus your own presets saved from current values; fine-tuning steppers without slow virtual keyboards.
- **Menu control** — dedicated `Bigme Light` menu with presets, step size, sleep power management toggle, and EinkCenter panel.
- **Gesture support** — assign swipes/taps to cool/warm up & down, presets, light toggle, or dialog.
- **Self-contained setup** — helper script is embedded in the plugin and auto-installed through Magisk. No external files to place manually.
- **Cold + warm channels** — independently control both LED strings from 0 to 255.
- **Toggle with memory** — turning the light off remembers the last cold/warm values and restores them when turned back on.
- **Health checks** — `Check setup` reports root, driver, direct I/O, and helper status.

## Requirements

- **Device:** Bigme HiBreak / Bigme B6 (MediaTek Helio P35) exposing the LM3630A front-light driver at `/sys/bus/i2c/devices/2-0036/`.
- **Root:** Magisk is **required**. Every read/write goes through `su`. If your HiBreak is not rooted yet, follow the [Bigme B6 & HiBreak Rooting Guide](https://github.com/right9code/hibigzero/blob/main/docs/ROOTING_GUIDE.md).
- **KOReader:** any recent version.
- **External dependencies:** none. No Lua libraries, no network, no companion app. The only system tools used are `su` and Android's toybox `base64`, both present on the stock firmware. The helper is installed to `/data/local/tmp/`, which survives reboots.

> This plugin is independent of **HiBig Zero**. HiBig Zero does *not* provide the light helper, and this plugin does not require the app.

## Installation

The plugin is a folder. You can install it entirely on the device — no computer needed.

1. Download `bigmelight-v1.2.0.zip` from the [Releases](https://github.com/right9code/bigmelight.koplugin/releases) page (open the link in the device browser, or use KOReader's file browser / cloud storage).
2. Unzip it so the folder lands here:
   ```
   /sdcard/koreader/plugins/bigmelight.koplugin/
   ```
3. Restart KOReader.

Optional (from a PC):

```sh
adb push bigmelight.koplugin /sdcard/koreader/plugins/
```

## Setup (one time, on device)

1. Open KOReader, then open the menu and go to **Bigme Light**.
2. The plugin performs a health check. Because it needs root, **Magisk will prompt to grant superuser** — tap **Allow**.
3. The helper is installed automatically, sysfs nodes are configured for direct I/O, and status reports `Bigme Light: ready`.

The Magisk prompt appears **once**. After that the plugin works silently. No terminal and no PC are involved.

If anything is missing, use **Bigme Light → Check setup** or **Install / update helper** for an explicit status.

## Usage

### Menu

Open **Bigme Light** in the KOReader menu:

| Entry | Description |
|---|---|
| **Light control dialog** | Interactive touch dialog with steppers, presets, and off |
| **Quick presets** | Your presets (editable): tap to apply, hold to edit or delete, add your own |
| **Step size: N** | How much each gesture changes the light (1–50) |
| **Turn off on sleep** | Power saving toggle: turns off LEDs on sleep, restores on wake |
| **All off** | Turn both channels off |
| **EinkCenter panel** | Open the Bigme EinkCenter panel |
| **Install / update helper** | Reinstall root helper and refresh permissions |
| **Check setup** | Report root, driver, direct sysfs I/O, and helper status |
| **Status: C=… W=… (Direct/Root)** | Current values and active driver mode |
| **Refresh from hardware** | Re-read current values from the driver |

### Gestures

Assign in KOReader → **Settings → Tap and gestures → Gesture manager**, then pick the **General** category:

- `Bigme: increase cold light` / `Bigme: decrease cold light`
- `Bigme: increase warm light` / `Bigme: decrease warm light`
- `Bigme: preset Daytime (cold 80, warm 0)`
- `Bigme: preset Reading (cold 50, warm 60)`
- `Bigme: preset Bedtime (cold 0, warm 50)`
- `Bigme: toggle front light`
- `Bigme: light control dialog`
- `Bigme: turn off all lights`
- `Bigme: EinkCenter panel`

## Technical Details

- **Driver:** TI LM3630A at `/sys/bus/i2c/devices/2-0036/lm3630a_cold_light` and `lm3630a_warm_light` (range 0–255).
- **Helper:** `/data/local/tmp/bigme_light.sh`, embedded in `main.lua` as base64 and installed via Magisk root.
- **Reads:** `io.popen` through `su` (result needed). **Writes:** fire-and-forget `os.execute` for speed.
- **`su` pre-warm:** the daemon is warmed on init so the first gesture is not slow.

## File Structure

```
bigmelight.koplugin/
├── .gitignore
├── LICENSE
├── README.md
└── bigmelight.koplugin/
    ├── _meta.lua          # Plugin metadata (KOReader registration)
    └── main.lua           # Full plugin implementation + embedded helper
```

---

**Author**: right9code  
**Version**: 1.2.0  
**License**: [Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/)
