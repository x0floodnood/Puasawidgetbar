# Puasa Menu Bar Widget (SwiftBar)

A macOS menu bar widget for fasting times (`Imsak`, `Sahur/Subuh`, `Berbuka/Maghrib`) with countdown status.

## Features

- Auto-detects machine location (network/IP)
- Uses live Malaysia timings from `waktusolat.my` (zone-based)
- In-widget `Change Location` menu with persistent zone selection
- `Auto (machine location)` mode and manual zone override (e.g. `PRK02`, `WLY01`)
- Falls back to Aladhan for non-Malaysia locations
- Updates every minute via SwiftBar (`puasa.1m.sh`)

## Install

1. Install SwiftBar.
2. Set SwiftBar plugin folder to this directory.
3. Ensure script is executable.

```bash
chmod +x puasa.1m.sh
```

## Change Location In Widget

1. Click the widget in menu bar.
2. Open `Change Location`.
3. Choose:
- `Auto (machine location)` to follow current network location.
- Any Malaysia zone code from `waktusolat.my` (for fixed location behavior).

Selection is persisted in:

`/Users/kaylaru/Documents/New project/PuasaWidget/.puasa_widget_config`

## Run manually

```bash
./puasa.1m.sh
```
