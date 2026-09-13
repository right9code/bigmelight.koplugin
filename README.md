# Bigme Light Control — KOReader Plugin

Control the **Bigme HiBreak / B6** front light (cold and warm channels) from inside KOReader, using the plugin menu or swipe gestures.

The plugin talks directly to the TI **LM3630A** dual-string LED driver through root, and installs its own helper script on demand. **No PC or manual `adb push` is required.**

## Features

- **Menu control** — a dedicated `Bigme Light` entry with a light dialog, step-size setting, all-off, and the EinkCenter panel.
- **Gesture support** — assign swipes/taps to increase or decrease the **cold** or **warm** channel, toggle the light, or open the dialog.
- **Self-contained setup** — the helper script is embedded in the plugin and installed through Magisk with one tap. No external files to place.
- **Cold + warm channels** — independently control both LED strings from 0 to 255.
- **Toggle with memory** — turning the light off remembers the last cold/warm values and restores them when turned back on.
- **Health checks** — `Check setup` reports root, driver, and helper status with clear messages instead of failing silently.

## Requirements

- **Device:** Bigme HiBreak / Bigme B6 (MediaTek Helio P35) exposing the LM3630A front-light driver at `/sys/bus/i2c/devices/2-0036/`.
- **Root:** Magisk is **required**. Every read/write goes through `su`. If your HiBreak is not rooted yet, follow the [Bigme B6 & HiBreak Rooting Guide](https://github.com/right9code/hibigzero/blob/main/docs/ROOTING_GUIDE.md).
- **KOReader:** any recent version.
- **External dependencies:** none. No Lua libraries, no network, no companion app. The only system tools used are `su` and Android's toybox `base64`, both present on the stock firmware. The helper is installed to `/data/local/tmp/`, which survives reboots.

> This plugin is independent of **HiBig Zero**. HiBig Zero does *not* provide the light helper, and this plugin does not require the app.

## Installation

The plugin is a folder. You can install it entirely on the device — no computer needed.

1. Download `bigmelight-v1.0.zip` from the [Releases](https://github.com/right9code/bigmelight.koplugin/releases) page (open the link in the device browser, or use KOReader's file browser / cloud storage).
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
3. The helper is installed automatically:
   ```
   su -c 'base64 -d ... > /data/local/tmp/bigme_light.sh && chmod 755 ...'
   ```
4. It then reads the current light values and reports `Bigme Light: ready`.

The Magisk prompt appears **once**. After that the plugin works silently. No terminal and no PC are involved.

If anything is missing, use **Bigme Light → Check setup** or **Install / update helper** for an explicit status.

## Usage

### Menu

Open **Bigme Light** in the KOReader menu:

| Entry | Description |
|---|---|
| **Light control dialog** | Set the cold value and nudge warm up/down |
| **Step size: N** | How much each gesture changes the light (1–50) |
| **All off** | Turn both channels off |
| **EinkCenter panel** | Open the Bigme EinkCenter panel |
| **Install / update helper** | Reinstall the root helper and re-check status |
| **Check setup** | Report root, driver, and helper status |
| **Status: cold=… warm=…** | Current values (read-only) |
| **Refresh from hardware** | Re-read current values from the driver |

### Gestures

Assign in KOReader → **Settings → Tap and gestures → Gesture manager**, then pick the **General** category:

- `Bigme: increase cold light` / `Bigme: decrease cold light`
- `Bigme: increase warm light` / `Bigme: decrease warm light`
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
**Version**: 1.0  
**License**: [Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/)
