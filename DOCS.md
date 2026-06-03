# repower — full documentation

**English** · [Русский](DOCS_RU.md)

Overview and quick start are in [README.md](README.md). This page collects all
the detail: installer, commands, parameters, probe-based Z, purge line,
notifications, dialogs and how it works.

Tuned for **CoreXY + probe**, but the config is generic — for other kinematics
just adjust the macro in `repower_macros.cfg`.

---

## Installer / control panel

`install.sh` is an interactive control panel with a modern TUI rendered via
**`gum`** (charm.sh); on first run it offers to install gum with one command.
If you decline or have no internet it falls back to **whiptail**, then to plain
text prompts. The menu is **bilingual (EN/RU)**.

On launch it automatically:

- finds Klipper and the config dir (or uses `KLIPPER_PATH` / `KLIPPER_CONFIG`);
- symlinks `repower.py` into `klippy/extras/`;
- **symlinks** `repower_macros.cfg` (macro logic — auto-updates on
  `git pull` / Moonraker, no need to edit);
- installs a **copy** of `repower.cfg` (the `[repower]` settings only) — your
  values are never overwritten by updates; an old monolithic config is
  **migrated** automatically (tunables carried over, macros split out, `.bak`);
- on update, **appends new options** (as commented hints) without touching
  values you already set;
- adds `[include repower.cfg]`, `[include repower_macros.cfg]` and
  `[force_move] enable_force_move: True` **before** the `#*# SAVE_CONFIG` block;
- registers `[update_manager repower]` in `moonraker.conf` for UI updates.

Main menu:

```
 Main menu
   Recovery settings & modes   ← interval, purge/prime, Z hop, travel,
                                 park X/Y, purge mode, probe-Z on/off
   Notifications               ← Telegram / ntfy / off + test
   Language                    ← en / ru
   Show current configuration  ← current values and paths
   Apply changes (restart)     ← apply (restart Klipper)
   Reinstall / repair links
   Uninstall
   Exit
```

Flags:

```bash
./install.sh --menu             # force the menu
./install.sh --non-interactive  # silently install/repair (no menu)
./install.sh --uninstall        # remove the module symlink and restart
```

> Run by Moonraker (no TTY), the script stays silent — it just repairs the
> install; your settings are kept.

---

## Recovery: what `REPOWER_RECOVER` does

1. Start heating the bed (in parallel).
2. Trust the (held) Z and lift the nozzle (safe on a lead-screw Z).
3. Home X/Y (nozzle already lifted off the part).
4. **Probe Z** on a clear bed area (if enabled, see below).
5. Park at a **bed corner** and **heat the nozzle** there (stationary).
6. **Purge** (line or blob).
7. Travel back to the saved spot and descend to the right height.
8. `REPOWER_RESUME` — restore modes/factors/mesh/offset and continue the file
   from the exact saved byte.

The nozzle reaches temperature **only after** the lift/home/probe, so heat-up
ooze lands at the corner, not on the model.

---

## Probe-based Z recovery

Instead of trusting that Z held its height, the plugin can **measure the true
Z by probing a clear area of the bed** (never over the model):

1. the nozzle lifts, X/Y home;
2. the plugin picks a **clear point**: **auto** — beside the model bounding box
   (tracked during the print) with `recovery_clearance`; if none fits — a
   **fixed point** `recovery_probe_x/y`; if neither — **trust Z**;
3. `PROBE` on the bare bed → re-reference Z by the probe `z_offset` (this even
   catches a dropped Z).

Control: `use_probe` (in `[repower]` or `REPOWER_RECOVER USE_PROBE=0`).
`REPOWER_QUERY` shows what will be used and the chosen point.

> Needs a probe (BLTouch/inductive) and a **lead-screw Z**. For a belted Z the
> post-loss lift is less predictable.

---

## Purge: line or blob

- **`purge_mode: line`** (default): the head parks & heats at the corner, then
  travels to a line start (offset from the corner so heat-up ooze is not on the
  line) and draws a **thin prime line** along the bed edge — visible, out of
  the way, easy to remove.
- **`purge_mode: blob`**: just extrude in place.
- If no clear area is found — automatic fallback to `blob`.

Parameters: `purge`, `purge_retract`, `purge_line_length`, `purge_line_z`,
`purge_line_speed`, `prime`.

---

## Dialog in Mainsail / Fluidd

After a power loss, on boot a **"Power-loss recovery"** dialog pops up with
**Recover** / **Discard** buttons (via `action:prompt_*`, no `[respond]`
section needed).

> ⚠️ **Fluidd** only renders dialogs received live, so the plugin re-shows the
> dialog a few times after boot (`prompt_retries` × `prompt_interval`) to catch
> the browser connecting. **Close** stops the re-shows (state is kept — recover
> via the `REPOWER_RECOVER` macro button or `REPOWER_PROMPT`).

`REPOWER_RECOVER` is also available as a macro button in the Macros panel.

---

## Push notifications

When a recoverable print is found on boot, the plugin can send a notification
(in the background, never blocking Klipper):

```ini
# Telegram (bot via @BotFather)
[repower]
notify: telegram
notify_telegram_token: 123456:ABC-DEF...
notify_telegram_chat: 111111111

# or ntfy (subscribe to the topic in the app)
[repower]
notify: ntfy
notify_ntfy_topic: my-secret-printer-topic
#notify_ntfy_url: https://ntfy.sh
```

Test it: `REPOWER_NOTIFY_TEST` (or the test at the end of the menu setup).

---

## Commands

| Command | Purpose |
| --- | --- |
| `REPOWER_QUERY` | Show state and the recovery plan (Z, probe point, purge) |
| `REPOWER_PROMPT` | Show the recovery dialog in Mainsail/Fluidd |
| `REPOWER_RECOVER` | Full recovery procedure |
| `REPOWER_RESUME` | Low-level: open the file, seek to the offset, resume |
| `REPOWER_CLEAR` | Discard the saved state |
| `REPOWER_SET_LANGUAGE LANG=ru` | Switch dialog/notification language live |
| `REPOWER_NOTIFY_TEST` | Send a test push notification |

Per-call parameter overrides:
`REPOWER_RECOVER PURGE=12 PRIME=1 USE_PROBE=0 PURGE_MODE=blob`.

---

## `[repower]` parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `state_path` | `~/printer_data/repower_state.json` | Where the snapshot is written |
| `save_interval` | `1.0` | Snapshot rate (s). Lower = less lost, more writes |
| `min_z_change` | `0.0` | Snapshot only when Z moved ≥ N mm (saves the SD). `0` = every interval |
| `language` | `en` | Dialog/notification language: `en` / `ru` |
| `use_probe` | `True` | Re-establish Z by probing (else trust the saved Z) |
| `z_hop` | `5` | Z lift before moving over the part (mm) |
| `travel_speed` | `150` | XY travel speed during recovery (mm/s) |
| `purge` | `8` | Filament purged after re-heating (mm) |
| `purge_retract` | `0.8` | Retract after purge (mm) |
| `prime` | `0` | Extra prime after returning to the part (mm) |
| `park_x` / `park_y` | `-1` | Heat/purge spot. `<0` = auto bed corner on the clear side |
| `purge_mode` | `line` | `line` — draw a purge line; `blob` — extrude in place |
| `purge_line_length` | `40` | Purge line length (mm) |
| `purge_line_z` | `0.3` | Purge line height (mm) |
| `purge_line_speed` | `15` | Purge line drawing speed (mm/s) |
| `recovery_clearance` | `15` | Free margin (mm) to place the auto probe point |
| `recovery_probe_x` | `-1` | Fixed fallback probe point X. `<0` = off |
| `recovery_probe_y` | `-1` | Fixed fallback probe point Y |
| `notify` | `none` | Power-loss notification: `none` / `telegram` / `ntfy` |
| `notify_telegram_token` | — | Telegram bot token |
| `notify_telegram_chat` | — | Telegram chat id (numeric) |
| `notify_ntfy_topic` | — | ntfy topic |
| `notify_ntfy_url` | `https://ntfy.sh` | ntfy server URL (for self-hosted) |
| `prompt_on_startup` | `True` | Show the recovery dialog on boot |
| `prompt_retries` | `6` | How many times to re-show the dialog (for Fluidd) |
| `prompt_interval` | `20.0` | Interval between dialog re-shows (s) |

New options appear in your `repower.cfg` automatically on update (as commented
hints); values you already set are left untouched.

---

## What the snapshot stores

- position in the G-code file (byte offset in `virtual_sdcard`);
- X/Y/Z/E and gcode coordinates;
- target nozzle/bed temperatures, fan speed;
- speed/flow factors (M220/M221), G90/G91 and M82/M83 modes;
- the active bed mesh profile and the gcode offset (probe Z-offset / babystep);
- the model bounding box (to pick the clear probe point).

On resume, `REPOWER_RESUME` restores modes/factors/fan, **re-loads the bed
mesh** (`BED_MESH_PROFILE LOAD=...`) and **re-applies the gcode offset**
(`SET_GCODE_OFFSET ... MOVE=0`), then sets the extruder origin (`G92 E`) and
continues the file from the saved byte.

---

## Files

| File | What it is |
| --- | --- |
| `repower.py` | Klipper module (`klippy/extras/`) — snapshots, logic, status |
| `repower_macros.cfg` | Recovery macros (symlinked, auto-updates) |
| `repower.cfg` | Your `[repower]` settings (a copy, not overwritten) |
| `install.sh` | Installer / control panel |

> 🛟 The installer inserts its sections into `printer.cfg` **before** the
> `#*# SAVE_CONFIG` block, so BLTouch offsets and bed meshes are not clobbered.

Tip: add `REPOWER_CLEAR` to your `PRINT_END` and `CANCEL_PRINT` macros so a
stale snapshot is never left after a normal finish (the plugin also auto-clears
on clean completion).

---

## How it works (short)

`repower.py` polls `virtual_sdcard`, `toolhead`, `gcode_move`, heaters and the
fan on a timer and atomically (temp file + rename) writes a JSON snapshot. On
boot it reads the snapshot: if a print was interrupted it raises
`printer.repower.recoverable`. Resume reopens the file, `seek()`s to the saved
offset and starts `do_resume()` on `virtual_sdcard`.

## Limitations and plans

- Up to `save_interval` seconds of printing is lost between the last snapshot
  and the outage → a small seam is possible there.
- Z return: with `use_probe` the height is measured by the probe (catches a
  drop); without a probe, Z is assumed to have held.
- **Planned:** a hardware power-loss detector (GPIO + capacitor) to capture the
  exact state at the moment of failure and park safely.
