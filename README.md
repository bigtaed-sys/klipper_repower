# repower — power-loss recovery for Klipper

**English** · [Русский](README_RU.md)

A Klipper plugin that saves print state while printing and, after an
unexpected power loss, resumes the print roughly where it stopped. No extra
hardware (snapshot based). If you have a probe, it re-establishes the true Z
height and cleanly purges the nozzle with a prime line.

> ⚠️ Power-loss recovery on FDM is not 100% reliable: a small seam at the
> resume point is possible. The plugin does its best.

## Requirements

- Printing from the host via `[virtual_sdcard]` (Mainsail / Fluidd).
- `[force_move]` with `enable_force_move: True` (the installer adds it).
- A lead-screw Z axis (holds position when powered off).

## Install

On the host (MKS Pi / Raspberry Pi):

```bash
git clone https://github.com/bigtaed-sys/klipper_repower ~/repower
cd ~/repower
chmod +x install.sh
./install.sh
```

A menu (EN/RU) opens — it finds Klipper, installs the plugin, wires up the
config and offers settings. Walk through it and pick **Apply (restart
Klipper)** at the end. Done.

## Usage

1. Print as usual — the plugin silently saves progress.
2. Power is lost → turn the printer back on.
3. A **"Power-loss recovery"** dialog pops up in Mainsail/Fluidd — press
   **Recover**. (Or run `REPOWER_RECOVER` in the console.)
4. The printer heats up, homes X/Y, restores the height and resumes printing.

Don't want to resume — press **Discard** (or `REPOWER_CLEAR`).

## Settings

Run `./install.sh` again and choose **Recovery settings & modes** or
**Notifications** — everything is editable from the menu (snapshot interval,
purge, probe-based Z, Telegram/ntfy, etc.).

## Details

Full reference (all commands and parameters, probe-based Z, purge line,
notifications, dialogs, internals, limitations) — see **[DOCS.md](DOCS.md)**.
