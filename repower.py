# Power-loss recovery for Klipper (software snapshot based)
#
# This module periodically persists the print state to disk while a print is
# running. After an unexpected power loss the saved state can be used to resume
# the print from approximately where it stopped.
#
# Copyright (C) 2026
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import os
import json
import logging
import threading
import urllib.request
import urllib.parse

# Bump when the on-disk schema changes in an incompatible way.
STATE_VERSION = 1

# Localized strings for the recovery dialog (Mainsail/Fluidd prompts) and
# push notifications, keyed by language.
STRINGS = {
    'en': {
        'btn_recover': 'Recover', 'btn_discard': 'Discard',
        'btn_close': 'Close',
        'dlg_title': 'Power-loss recovery',
        'dlg_detected': 'An interrupted print was detected:',
        'dlg_resume': 'Resume at Z%.2f  (nozzle %.0f / bed %.0f)?',
        'notify_body': "\U0001F50C Power loss: print '%s' can be recovered.",
    },
    'ru': {
        'btn_recover': 'Восстановить', 'btn_discard': 'Сбросить',
        'btn_close': 'Закрыть',
        'dlg_title': 'Восстановление после сбоя',
        'dlg_detected': 'Обнаружена прерванная печать:',
        'dlg_resume': 'Продолжить с Z%.2f  (сопло %.0f / стол %.0f)?',
        'notify_body': "\U0001F50C Потеря питания: печать '%s' можно "
                       "восстановить.",
    },
}


class Repower:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')

        # --- Configuration -------------------------------------------------
        # Where the snapshot is stored. Default lives next to the printer data
        # directory so it survives a host reboot.
        default_state = os.path.expanduser(
            '~/printer_data/repower_state.json')
        self.state_path = os.path.expanduser(
            config.get('state_path', default_state))
        # How often (seconds) to capture a snapshot while printing. Lower is
        # safer (less lost progress) but writes to disk more often.
        self.save_interval = config.getfloat(
            'save_interval', 1., above=0.)
        # If set, only persist a new snapshot when the Z height changed by at
        # least this many mm (i.e. roughly once per layer). 0 disables the
        # filter and snapshots are taken every interval whenever the file
        # position advanced. Useful to reduce flash/SD wear on long prints.
        self.min_z_change = config.getfloat('min_z_change', 0., minval=0.)
        # Raise the Mainsail/Fluidd recovery dialog automatically on boot.
        # Fluidd only renders prompts received live (it does not rebuild them
        # from the gcode history), so we re-emit it a few times to catch the
        # moment the browser connects.
        self.prompt_on_startup = config.getboolean('prompt_on_startup', True)
        self.prompt_retries = config.getint('prompt_retries', 6, minval=1)
        self.prompt_interval = config.getfloat(
            'prompt_interval', 20., above=0.)
        # Dialog / notification language (en|ru). Takes effect immediately for
        # new prompts and notifications.
        self.language = config.get('language', 'en').lower()
        if self.language not in STRINGS:
            self.language = 'en'

        # --- Notifications -------------------------------------------------
        # Push a message when a recoverable print is detected on boot.
        # channel: none | telegram | ntfy
        self.notify = config.get('notify', 'none').lower()
        self.notify_telegram_token = config.get('notify_telegram_token', '')
        self.notify_telegram_chat = config.get('notify_telegram_chat', '')
        self.notify_ntfy_url = config.get(
            'notify_ntfy_url', 'https://ntfy.sh').rstrip('/')
        self.notify_ntfy_topic = config.get('notify_ntfy_topic', '')

        # --- Probe-based Z recovery ----------------------------------------
        # Re-establish true Z by probing a CLEAR area of the bed (never over
        # the model). Requires a probe (BLTouch/inductive). Safe on screw Z.
        # Required free margin (mm) to place an auto probe point beside the
        # model, and how far from the model edge the point is placed.
        self.recovery_clearance = config.getfloat(
            'recovery_clearance', 15., minval=0.)
        # Fixed fallback probe point (mm). <0 = unset.
        self.recovery_probe_x = config.getfloat('recovery_probe_x', -1.)
        self.recovery_probe_y = config.getfloat('recovery_probe_y', -1.)

        # --- Recovery motion tunables (read by the REPOWER_RECOVER macro) ---
        # Kept here (not as macro variables) so the menu/installer can edit
        # them in the user-owned config while the macro logic auto-updates.
        self.use_probe = config.getboolean('use_probe', True)
        self.z_hop = config.getfloat('z_hop', 5., minval=0.)
        self.travel_speed = config.getfloat('travel_speed', 150., above=0.)
        self.purge = config.getfloat('purge', 8., minval=0.)
        self.purge_retract = config.getfloat('purge_retract', 0.8, minval=0.)
        self.prime = config.getfloat('prime', 0., minval=0.)
        self.park_x = config.getfloat('park_x', -1.)
        self.park_y = config.getfloat('park_y', -1.)

        # Running model bounding box [minx, miny, maxx, maxy] for the current
        # print, and the file it belongs to (reset when the file changes).
        self._bbox = None
        self._bbox_file = None
        self._probe_z_offset = 0.

        # --- Runtime state -------------------------------------------------
        # Loaded snapshot (a dict) when a recoverable print is detected, else
        # None.
        self.state = None
        self.recoverable = False
        # Tracks whether we have seen the virtual_sdcard active in this host
        # session. Used to distinguish "print finished cleanly" (clear state)
        # from "fresh boot with a leftover snapshot" (keep state).
        self.was_active = False
        # Bookkeeping to avoid redundant writes.
        self._last_file_position = -1
        self._last_saved_z = None
        # Auto-prompt re-show bookkeeping.
        self._prompt_pending = False
        self._prompt_attempts = 0
        self._prompt_timer = None
        self._save_timer = None

        # --- Commands ------------------------------------------------------
        self.gcode.register_command(
            'REPOWER_QUERY', self.cmd_REPOWER_QUERY,
            desc=self.cmd_REPOWER_QUERY_help)
        self.gcode.register_command(
            'REPOWER_RESUME', self.cmd_REPOWER_RESUME,
            desc=self.cmd_REPOWER_RESUME_help)
        self.gcode.register_command(
            'REPOWER_CLEAR', self.cmd_REPOWER_CLEAR,
            desc=self.cmd_REPOWER_CLEAR_help)
        self.gcode.register_command(
            'REPOWER_PROMPT', self.cmd_REPOWER_PROMPT,
            desc=self.cmd_REPOWER_PROMPT_help)
        self.gcode.register_command(
            'REPOWER_PROMPT_DISMISS', self.cmd_REPOWER_PROMPT_DISMISS,
            desc=self.cmd_REPOWER_PROMPT_DISMISS_help)
        self.gcode.register_command(
            'REPOWER_SET_LANGUAGE', self.cmd_REPOWER_SET_LANGUAGE,
            desc=self.cmd_REPOWER_SET_LANGUAGE_help)
        self.gcode.register_command(
            'REPOWER_NOTIFY_TEST', self.cmd_REPOWER_NOTIFY_TEST,
            desc=self.cmd_REPOWER_NOTIFY_TEST_help)

        self.printer.register_event_handler('klippy:ready',
                                            self._handle_ready)

    # ----------------------------------------------------------------- setup
    def _handle_ready(self):
        # Cache the probe's configured z_offset for probe-based Z recovery.
        self._probe_z_offset = self._read_probe_offset()
        # Try to load any leftover snapshot from a previous (interrupted) run.
        self._load_state()
        # Start periodic snapshotting.
        self._save_timer = self.reactor.register_timer(
            self._save_event, self.reactor.NOW)
        if self.recoverable:
            self.gcode.respond_info(
                "repower: recoverable print detected (%s)."
                % (self.state.get('file_name', '?'),))
            # Pop an interactive dialog in Mainsail / Fluidd. Fluidd only
            # renders prompts received live, so re-emit it a few times to
            # catch the browser connecting after boot. REPOWER_PROMPT can
            # also re-summon it manually at any time.
            if self.prompt_on_startup:
                self._prompt_pending = True
                self._prompt_attempts = 0
                self._prompt_timer = self.reactor.register_timer(
                    self._prompt_event, self.reactor.monotonic() + 2.)
            # Fire a push notification (non-blocking, best effort).
            self._notify(STRINGS[self.language]['notify_body']
                         % (self.state.get('file_name', '?'),))

    # -------------------------------------------------------- notifications
    def _notify(self, text):
        # Build a request for the configured channel and send it from a
        # daemon thread so the reactor is never blocked on the network.
        if self.notify == 'none':
            return
        req = None
        try:
            if self.notify == 'telegram':
                if not (self.notify_telegram_token
                        and self.notify_telegram_chat):
                    logging.warning("repower: telegram not configured")
                    return
                url = ("https://api.telegram.org/bot%s/sendMessage"
                       % (self.notify_telegram_token,))
                data = urllib.parse.urlencode({
                    'chat_id': self.notify_telegram_chat,
                    'text': text,
                }).encode('utf-8')
                req = urllib.request.Request(url, data=data)
            elif self.notify == 'ntfy':
                if not self.notify_ntfy_topic:
                    logging.warning("repower: ntfy topic not configured")
                    return
                url = '%s/%s' % (self.notify_ntfy_url, self.notify_ntfy_topic)
                req = urllib.request.Request(
                    url, data=text.encode('utf-8'))
            else:
                logging.warning("repower: unknown notify channel '%s'",
                                self.notify)
                return
        except Exception as e:
            logging.warning("repower: failed to build notification: %s", e)
            return
        threading.Thread(target=self._send_request, args=(req,),
                         daemon=True).start()

    def _send_request(self, req):
        try:
            urllib.request.urlopen(req, timeout=10).read()
        except Exception as e:
            logging.warning("repower: notification send failed: %s", e)

    def _prompt_event(self, eventtime):
        # Periodically re-show the dialog until the user acts on it or the
        # retry budget is exhausted.
        if not self.recoverable or not self._prompt_pending:
            return self.reactor.NEVER
        self._show_prompt()
        self._prompt_attempts += 1
        if self._prompt_attempts >= self.prompt_retries:
            self._prompt_pending = False
            return self.reactor.NEVER
        return eventtime + self.prompt_interval

    # ------------------------------------------------------- frontend dialog
    def _show_prompt(self):
        # Emit the Mainsail/Fluidd interactive-prompt action responses. Each
        # respond_info line is sent prefixed with "// ", which the frontends
        # parse as "// action:prompt_...". No [respond] section required.
        st = self.state or {}
        L = STRINGS[self.language]
        g = self.gcode
        g.respond_info("action:prompt_end")  # clear any stale dialog
        g.respond_info("action:prompt_begin %s" % (L['dlg_title'],))
        g.respond_info("action:prompt_text %s" % (L['dlg_detected'],))
        g.respond_info("action:prompt_text %s" % (st.get('file_name', '?'),))
        g.respond_info(
            "action:prompt_text " + L['dlg_resume']
            % (st.get('z', 0.), st.get('extruder_temp', 0.),
               st.get('bed_temp', 0.)))
        g.respond_info("action:prompt_button_group_start")
        g.respond_info("action:prompt_button %s|REPOWER_RECOVER|primary"
                       % (L['btn_recover'],))
        g.respond_info("action:prompt_button %s|REPOWER_PROMPT_DISCARD|error"
                       % (L['btn_discard'],))
        g.respond_info("action:prompt_button_group_end")
        g.respond_info("action:prompt_footer_button %s|REPOWER_PROMPT_CLOSE"
                       "|secondary" % (L['btn_close'],))
        g.respond_info("action:prompt_show")

    def _read_probe_offset(self):
        # Read the configured probe z_offset (handles probe / bltooth / etc.).
        try:
            cfg = self.printer.lookup_object('configfile')
            settings = cfg.get_status(self.reactor.monotonic())['settings']
        except Exception:
            return 0.
        for key in ('probe', 'bltouch', 'smart_effector',
                    'probe_eddy_current'):
            sub = settings.get(key)
            if sub and 'z_offset' in sub:
                try:
                    return float(sub['z_offset'])
                except (TypeError, ValueError):
                    pass
        return 0.

    def _probe_point(self, eventtime):
        # Decide where (if anywhere) it is safe to probe the bare bed:
        #   1) auto: a point beside the model bounding box with clearance,
        #   2) else a configured fixed point (if it clears the model),
        #   3) else give up -> caller trusts the saved Z.
        # Returns (ok, x, y).
        if self.printer.lookup_object('probe', None) is None:
            return (False, 0., 0.)
        th = self.printer.lookup_object('toolhead', None)
        if th is None:
            return (False, 0., 0.)
        ts = th.get_status(eventtime)
        amin = ts.get('axis_minimum')
        amax = ts.get('axis_maximum')
        if not amin or not amax:
            return (False, 0., 0.)
        bxmin, bymin, bxmax, bymax = amin[0], amin[1], amax[0], amax[1]
        clr = self.recovery_clearance
        bbox = (self.state or {}).get('bbox')

        def clamp(px, py):
            return (min(max(px, bxmin + 1.), bxmax - 1.),
                    min(max(py, bymin + 1.), bymax - 1.))

        if bbox:
            minx, miny, maxx, maxy = bbox
            cx, cy = (minx + maxx) / 2., (miny + maxy) / 2.
            # (gap on this side, point placed `clr` beyond the model edge)
            candidates = [
                (bxmax - maxx, (maxx + clr, cy)),   # right
                (minx - bxmin, (minx - clr, cy)),   # left
                (bymax - maxy, (cx, maxy + clr)),   # back
                (miny - bymin, (cx, miny - clr)),   # front
            ]
            candidates.sort(key=lambda c: c[0], reverse=True)
            gap, (px, py) = candidates[0]
            if gap >= clr:
                px, py = clamp(px, py)
                return (True, px, py)

        # Fixed fallback point.
        if self.recovery_probe_x >= 0. and self.recovery_probe_y >= 0.:
            px, py = self.recovery_probe_x, self.recovery_probe_y
            if bbox:
                minx, miny, maxx, maxy = bbox
                if (minx - clr <= px <= maxx + clr
                        and miny - clr <= py <= maxy + clr):
                    return (False, 0., 0.)   # fixed point sits over the model
            px, py = clamp(px, py)
            return (True, px, py)
        return (False, 0., 0.)

    # ------------------------------------------------------------ disk state
    def _load_state(self):
        self.state = None
        self.recoverable = False
        try:
            with open(self.state_path, 'r') as f:
                data = json.load(f)
        except (IOError, OSError):
            return
        except ValueError:
            logging.warning("repower: corrupt state file %s, ignoring",
                            self.state_path)
            return
        if data.get('version') != STATE_VERSION:
            logging.warning("repower: state version mismatch, ignoring")
            return
        # A snapshot is only useful if it points at a real file and offset.
        if not data.get('file_name') or not data.get('file_position'):
            return
        self.state = data
        self.recoverable = True

    def _write_state(self, data):
        # Atomic write: dump to a temp file then rename over the target so a
        # power loss mid-write cannot corrupt the snapshot.
        tmp_path = self.state_path + '.tmp'
        try:
            with open(tmp_path, 'w') as f:
                json.dump(data, f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, self.state_path)
        except (IOError, OSError) as e:
            logging.warning("repower: failed to write state: %s", e)

    def _delete_state(self):
        for path in (self.state_path, self.state_path + '.tmp'):
            try:
                os.remove(path)
            except OSError:
                pass
        self.state = None
        self.recoverable = False
        self._prompt_pending = False
        self._bbox = None
        self._bbox_file = None
        self._last_file_position = -1
        self._last_saved_z = None

    # --------------------------------------------------------- snapshot loop
    def _capture(self, eventtime):
        # Return a snapshot dict for the current print, or None if no print is
        # currently active.
        vsd = self.printer.lookup_object('virtual_sdcard', None)
        if vsd is None:
            return None
        vsd_status = vsd.get_status(eventtime)
        if not vsd_status.get('is_active'):
            return None
        file_path = vsd_status.get('file_path')
        if not file_path:
            return None
        # Resolve the filename relative to the sdcard directory so it can be
        # reopened later via the standard load path.
        try:
            file_name = os.path.relpath(file_path, vsd.sdcard_dirname)
        except (ValueError, AttributeError):
            file_name = os.path.basename(file_path)

        toolhead = self.printer.lookup_object('toolhead')
        pos = toolhead.get_position()

        gcode_move = self.printer.lookup_object('gcode_move')
        gm = gcode_move.get_status(eventtime)
        gpos = gm['gcode_position']

        # Target temperatures (we want the printer to return to setpoint, not
        # to the momentary reading).
        extruder = self.printer.lookup_object('extruder')
        extruder_temp = extruder.get_heater().get_status(eventtime)['target']
        bed_temp = 0.
        bed = self.printer.lookup_object('heater_bed', None)
        if bed is not None:
            bed_temp = bed.get_status(eventtime)['target']
        fan_speed = 0.
        fan = self.printer.lookup_object('fan', None)
        if fan is not None:
            fan_speed = fan.get_status(eventtime).get('speed', 0.)

        # Active gcode offset (probe Z offset / babystepping). Must be
        # re-applied on resume or the recovered print is shifted in Z.
        ho = gm.get('homing_origin', (0., 0., 0., 0.))
        gcode_offset = [float(ho[0]), float(ho[1]), float(ho[2])]

        # Currently loaded bed mesh profile, if any. A fresh G28 after a power
        # loss drops the active mesh, so we re-load it on resume.
        mesh_profile = ''
        bed_mesh = self.printer.lookup_object('bed_mesh', None)
        if bed_mesh is not None:
            mesh_profile = bed_mesh.get_status(eventtime).get(
                'profile_name', '') or ''

        # Accumulate the model bounding box for this file (reset on new file).
        if self._bbox_file != file_name or self._bbox is None:
            self._bbox_file = file_name
            self._bbox = [pos[0], pos[1], pos[0], pos[1]]
        else:
            b = self._bbox
            b[0] = min(b[0], pos[0]); b[1] = min(b[1], pos[1])
            b[2] = max(b[2], pos[0]); b[3] = max(b[3], pos[1])

        return {
            'version': STATE_VERSION,
            'file_name': file_name,
            'file_position': vsd_status.get('file_position', 0),
            'file_size': vsd_status.get('file_size', 0),
            'x': pos[0], 'y': pos[1], 'z': pos[2], 'e': pos[3],
            'gcode_x': gpos[0], 'gcode_y': gpos[1],
            'gcode_z': gpos[2], 'gcode_e': gpos[3],
            'absolute_coordinates': gm.get('absolute_coordinates', True),
            'absolute_extrude': gm.get('absolute_extrude', True),
            'speed_factor': gm.get('speed_factor', 1.),
            'extrude_factor': gm.get('extrude_factor', 1.),
            'gcode_offset': gcode_offset,
            'mesh_profile': mesh_profile,
            'bbox': list(self._bbox),
            'extruder_temp': extruder_temp,
            'bed_temp': bed_temp,
            'fan_speed': fan_speed,
        }

    def _save_event(self, eventtime):
        snap = self._capture(eventtime)
        if snap is None:
            # No active print. If we previously saw an active print in this
            # session and it has now finished cleanly, clear the snapshot.
            if self.was_active:
                vsd = self.printer.lookup_object('virtual_sdcard', None)
                ps = self.printer.lookup_object('print_stats', None)
                state = ps.get_status(eventtime).get('state') if ps else None
                if state in ('complete', 'cancelled', 'standby'):
                    self._delete_state()
                    self.was_active = False
            return eventtime + self.save_interval

        self.was_active = True
        # Skip writing if nothing meaningful changed since the last snapshot.
        fpos = snap['file_position']
        z = snap['z']
        position_changed = fpos != self._last_file_position
        z_changed = (self._last_saved_z is None
                     or abs(z - self._last_saved_z) >= self.min_z_change)
        if position_changed and (self.min_z_change == 0. or z_changed):
            self._write_state(snap)
            self._last_file_position = fpos
            self._last_saved_z = z
        return eventtime + self.save_interval

    # --------------------------------------------------------------- status
    def get_status(self, eventtime):
        st = self.state or {}
        fsize = st.get('file_size', 0) or 0
        fpos = st.get('file_position', 0) or 0
        progress = round(100. * fpos / fsize, 1) if fsize else 0.
        if self.recoverable:
            probe_ok, probe_x, probe_y = self._probe_point(eventtime)
        else:
            probe_ok, probe_x, probe_y = (False, 0., 0.)
        return {
            'recoverable': self.recoverable,
            'language': self.language,
            # Probe-based Z recovery fields read by the REPOWER_RECOVER macro.
            'probe_ok': probe_ok,
            'probe_x': round(probe_x, 2),
            'probe_y': round(probe_y, 2),
            'probe_z_offset': round(self._probe_z_offset, 4),
            # Recovery motion tunables (defaults for the macro; per-call
            # params still override them).
            'use_probe': 1 if self.use_probe else 0,
            'z_hop': self.z_hop, 'travel_speed': self.travel_speed,
            'purge': self.purge, 'purge_retract': self.purge_retract,
            'prime': self.prime,
            'park_x': self.park_x, 'park_y': self.park_y,
            'file_name': st.get('file_name', ''),
            'file_position': fpos,
            'file_size': fsize,
            'progress': progress,
            'x': st.get('x', 0.), 'y': st.get('y', 0.),
            'z': st.get('z', 0.), 'e': st.get('e', 0.),
            'gcode_e': st.get('gcode_e', 0.),
            'extruder_temp': st.get('extruder_temp', 0.),
            'bed_temp': st.get('bed_temp', 0.),
            'fan_speed': st.get('fan_speed', 0.),
        }

    # ------------------------------------------------------------- commands
    cmd_REPOWER_QUERY_help = "Report whether a recoverable print is available"

    def cmd_REPOWER_QUERY(self, gcmd):
        if not self.recoverable:
            gcmd.respond_info("repower: no recoverable print state")
            return
        st = self.state
        eventtime = self.reactor.monotonic()
        # Probe-based Z recovery diagnostics (why it will / will not run).
        probe_present = self.printer.lookup_object('probe', None) is not None
        probe_ok, px, py = self._probe_point(eventtime)
        bbox = st.get('bbox')
        macro = self.printer.lookup_object(
            'gcode_macro REPOWER_RECOVER', None)
        use_probe = (macro.get_status(eventtime).get('use_probe')
                     if macro is not None else '?')
        if probe_ok:
            zline = "Z method: PROBE at X%.1f Y%.1f (offset %.3f)" % (
                px, py, self._probe_z_offset)
        else:
            if not probe_present:
                why = "no [probe]/[bltouch] object"
            elif not bbox:
                why = "no model bounding box saved"
            elif self.recovery_probe_x < 0.:
                why = "no clear area and no recovery_probe_x/y set"
            else:
                why = "no safe probe point found"
            zline = "Z method: TRUST saved Z  (probe skipped: %s)" % (why,)
        gcmd.respond_info(
            "repower: recoverable print\n"
            " file: %s\n"
            " file_position: %d\n"
            " position: X%.2f Y%.2f Z%.3f\n"
            " temps: extruder %.0f / bed %.0f\n"
            " fan: %.0f%%\n"
            " model bbox: %s\n"
            " use_probe=%s  probe_present=%s  probe_ok=%s\n"
            " %s"
            % (st.get('file_name', '?'), st.get('file_position', 0),
               st.get('x', 0.), st.get('y', 0.), st.get('z', 0.),
               st.get('extruder_temp', 0.), st.get('bed_temp', 0.),
               st.get('fan_speed', 0.) * 100., bbox,
               use_probe, probe_present, probe_ok, zline))

    cmd_REPOWER_PROMPT_help = (
        "Show the Mainsail/Fluidd recovery dialog for the saved print")

    def cmd_REPOWER_PROMPT(self, gcmd):
        if not self.recoverable:
            gcmd.respond_info("repower: no recoverable print state")
            return
        self._show_prompt()

    cmd_REPOWER_PROMPT_DISMISS_help = (
        "Stop auto re-showing the recovery dialog (keeps the saved state)")

    def cmd_REPOWER_PROMPT_DISMISS(self, gcmd):
        # The "Close" button calls this so the dialog stops popping back up,
        # while leaving the recovery state intact for the macro button.
        self._prompt_pending = False

    cmd_REPOWER_SET_LANGUAGE_help = (
        "Switch the panel/dialog language live: REPOWER_SET_LANGUAGE LANG=ru")

    def cmd_REPOWER_SET_LANGUAGE(self, gcmd):
        lang = gcmd.get('LANG', 'en').lower()
        if lang not in STRINGS:
            raise gcmd.error("repower: unknown language '%s' (have: %s)"
                             % (lang, ', '.join(sorted(STRINGS))))
        self.language = lang
        gcmd.respond_info("repower: language set to %s" % (lang,))

    cmd_REPOWER_NOTIFY_TEST_help = "Send a test push notification"

    def cmd_REPOWER_NOTIFY_TEST(self, gcmd):
        if self.notify == 'none':
            gcmd.respond_info("repower: notifications are disabled (notify: "
                              "none)")
            return
        self._notify("repower: test notification (%s)" % (self.notify,))
        gcmd.respond_info("repower: test notification queued via %s"
                          % (self.notify,))

    cmd_REPOWER_CLEAR_help = "Discard any saved power-loss recovery state"

    def cmd_REPOWER_CLEAR(self, gcmd):
        self._delete_state()
        gcmd.respond_info("repower: recovery state cleared")

    cmd_REPOWER_RESUME_help = (
        "Low-level: reopen the saved file, seek to the saved offset and"
        " resume printing. Run REPOWER_RECOVER for the full sequence.")

    def cmd_REPOWER_RESUME(self, gcmd):
        if not self.recoverable:
            raise gcmd.error("repower: no recoverable print state")
        vsd = self.printer.lookup_object('virtual_sdcard', None)
        if vsd is None:
            raise gcmd.error("repower: [virtual_sdcard] is not configured")
        if vsd.is_active():
            raise gcmd.error("repower: a print is already active")
        st = self.state

        # Restore the gcode coordinate/extrude modes and factors so the
        # continuation of the file behaves exactly as before the interruption.
        script = []
        script.append('G90' if st.get('absolute_coordinates', True) else 'G91')
        script.append('M82' if st.get('absolute_extrude', True) else 'M83')
        script.append('M220 S%.0f' % (st.get('speed_factor', 1.) * 100.,))
        script.append('M221 S%.0f' % (st.get('extrude_factor', 1.) * 100.,))
        script.append('M106 S%.0f'
                      % (max(0., min(1., st.get('fan_speed', 0.))) * 255.,))
        # Re-load the bed mesh that was active before the outage (a fresh G28
        # during recovery drops it). No-op move, just re-activates the mesh.
        mesh_profile = st.get('mesh_profile')
        if mesh_profile:
            script.append('BED_MESH_PROFILE LOAD=%s' % (mesh_profile,))
        # Re-apply the gcode offset (probe Z offset / babystep) without moving
        # the toolhead, so resumed moves land at the same physical height.
        off = st.get('gcode_offset')
        if off:
            script.append('SET_GCODE_OFFSET X=%.4f Y=%.4f Z=%.4f MOVE=0'
                          % (off[0], off[1], off[2]))
        # Re-establish the extruder origin so absolute-E gcode continues from
        # the right value. Harmless when the file uses relative extrusion.
        script.append('G92 E%.5f' % (st.get('gcode_e', 0.),))
        self.gcode.run_script_from_command('\n'.join(script))

        # Reopen the file and seek to the saved byte offset.
        vsd._load_file(gcmd, st['file_name'], check_subdirs=True)
        offset = st['file_position']
        vsd.current_file.seek(offset)
        vsd.file_position = offset
        # Newer Klipper tracks the next position separately; keep them in sync.
        if hasattr(vsd, 'next_file_position'):
            vsd.next_file_position = offset

        gcmd.respond_info(
            "repower: resuming %s at byte %d"
            % (st.get('file_name', '?'), offset))
        vsd.do_resume()
        self.was_active = True


def load_config(config):
    return Repower(config)
