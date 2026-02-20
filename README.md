# Puasa Menu Bar Widget (SwiftBar)

A macOS menu bar widget for fasting times (`Imsak`, `Sahur/Subuh`, `Berbuka/Maghrib`) with countdown status.

## Features

- Auto-detects machine location (network/IP)
- Uses live Malaysia JAKIM zone timings via `solat.my` when in Malaysia
- Falls back to Aladhan for non-Malaysia locations
- Updates every minute via SwiftBar (`puasa.1m.sh`)

## Install

1. Install SwiftBar.
2. Set SwiftBar plugin folder to this directory.
3. Ensure script is executable:

```bash
chmod +x puasa.1m.sh
```

## Run manually

```bash
./puasa.1m.sh
```
