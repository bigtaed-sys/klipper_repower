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

# Bump when the on-disk schema changes in an incompatible way.
STATE_VERSION = 1


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
        # Advertise a native panel to the Fluidd plugin-UI API (fork feature).
        # Stock Fluidd/Mainsail simply ignore the extra 'fluidd_ui' status key.
        self.fluidd_panel = config.getboolean('fluidd_panel', True)
        self._fluidd_ui = self._build_fluidd_ui()

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

        self.printer.register_event_handler('klippy:ready',
                                            self._handle_ready)

    # ----------------------------------------------------------------- setup
    def _handle_ready(self):
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
        g = self.gcode
        g.respond_info("action:prompt_end")  # clear any stale dialog
        g.respond_info("action:prompt_begin Power-loss recovery")
        g.respond_info("action:prompt_text An interrupted print was detected:")
        g.respond_info("action:prompt_text %s" % (st.get('file_name', '?'),))
        g.respond_info(
            "action:prompt_text Resume at Z%.2f  (nozzle %.0f / bed %.0f)?"
            % (st.get('z', 0.), st.get('extruder_temp', 0.),
               st.get('bed_temp', 0.)))
        g.respond_info("action:prompt_button_group_start")
        g.respond_info("action:prompt_button Recover|REPOWER_RECOVER|primary")
        g.respond_info("action:prompt_button Discard|REPOWER_PROMPT_DISCARD|error")
        g.respond_info("action:prompt_button_group_end")
        g.respond_info(
            "action:prompt_footer_button Close|REPOWER_PROMPT_CLOSE|secondary")
        g.respond_info("action:prompt_show")

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

        return {
            'version': STATE_VERSION,
            'file_name': file_name,
            'file_position': vsd_status.get('file_position', 0),
            'x': pos[0], 'y': pos[1], 'z': pos[2], 'e': pos[3],
            'gcode_x': gpos[0], 'gcode_y': gpos[1],
            'gcode_z': gpos[2], 'gcode_e': gpos[3],
            'absolute_coordinates': gm.get('absolute_coordinates', True),
            'absolute_extrude': gm.get('absolute_extrude', True),
            'speed_factor': gm.get('speed_factor', 1.),
            'extrude_factor': gm.get('extrude_factor', 1.),
            'gcode_offset': gcode_offset,
            'mesh_profile': mesh_profile,
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

    # --------------------------------------------------------- fluidd panel
    def _build_fluidd_ui(self):
        # Native Fluidd panel manifest (fork plugin-UI API, schema v1). Built
        # once; it is static and Moonraker only sends it on change.
        recoverable = {'bind': 'repower.recoverable', 'op': 'truthy'}
        not_recoverable = {'bind': 'repower.recoverable', 'op': 'falsy'}
        macro = 'gcode_macro REPOWER_RECOVER'

        def set_var(var):
            return {'kind': 'gcode',
                    'command': 'SET_GCODE_VARIABLE MACRO=REPOWER_RECOVER'
                               ' VARIABLE=%s VALUE={value}' % (var,)}

        return {
            'schemaVersion': 1,
            'panels': [{
                'id': 'repower',
                'title': 'Power Recovery',
                'icon': 'backup-restore',
                'order': 500,
                'layout': [
                    {'type': 'section', 'title': 'Status', 'children': [
                        {'type': 'text', 'variant': 'body',
                         'value': 'No interrupted print — all good.',
                         'visibleIf': not_recoverable},
                        {'type': 'text', 'variant': 'title',
                         'value': 'Interrupted print detected',
                         'visibleIf': recoverable},
                        {'type': 'status', 'label': 'File',
                         'value': {'bind': 'repower.file_name'},
                         'visibleIf': recoverable},
                        {'type': 'status', 'label': 'Height',
                         'value': {'bind': 'repower.z'}, 'unit': 'mm',
                         'visibleIf': recoverable},
                        {'type': 'row', 'visibleIf': recoverable, 'children': [
                            {'type': 'status', 'label': 'Nozzle',
                             'value': {'bind': 'repower.extruder_temp'},
                             'unit': '°C'},
                            {'type': 'status', 'label': 'Bed',
                             'value': {'bind': 'repower.bed_temp'},
                             'unit': '°C'},
                        ]},
                    ]},
                    {'type': 'section', 'title': 'Recover',
                     'visibleIf': recoverable, 'children': [
                        {'type': 'row', 'children': [
                            {'type': 'button', 'label': 'Recover',
                             'icon': 'play', 'color': 'success',
                             'action': {'kind': 'gcode',
                                        'command': 'REPOWER_RECOVER',
                                        'confirm': 'Start power-loss'
                                                   ' recovery now?'}},
                            {'type': 'button', 'label': 'Discard',
                             'icon': 'delete', 'color': 'error',
                             'action': {'kind': 'gcode',
                                        'command': 'REPOWER_CLEAR',
                                        'confirm': 'Discard the saved'
                                                   ' recovery state?'}},
                        ]},
                    ]},
                    {'type': 'section', 'title': 'Recovery settings',
                     'collapsible': True, 'children': [
                        {'type': 'number', 'label': 'Purge (mm)',
                         'min': 0, 'max': 50, 'step': 1,
                         'bind': macro + '.purge', 'action': set_var('purge')},
                        {'type': 'number', 'label': 'Prime (mm)',
                         'min': 0, 'max': 20, 'step': 0.5,
                         'bind': macro + '.prime', 'action': set_var('prime')},
                        {'type': 'number', 'label': 'Z hop (mm)',
                         'min': 0, 'max': 30, 'step': 1,
                         'bind': macro + '.z_hop',
                         'action': set_var('z_hop')},
                    ]},
                    {'type': 'section', 'title': 'Tools',
                     'collapsible': True, 'children': [
                        {'type': 'button', 'label': 'Show recovery dialog',
                         'icon': 'bell', 'color': 'secondary',
                         'visibleIf': recoverable,
                         'action': {'kind': 'gcode',
                                    'command': 'REPOWER_PROMPT'}},
                    ]},
                ],
            }],
        }

    # --------------------------------------------------------------- status
    def get_status(self, eventtime):
        st = self.state or {}
        status = {
            'recoverable': self.recoverable,
            'file_name': st.get('file_name', ''),
            'file_position': st.get('file_position', 0),
            'x': st.get('x', 0.), 'y': st.get('y', 0.),
            'z': st.get('z', 0.), 'e': st.get('e', 0.),
            'gcode_e': st.get('gcode_e', 0.),
            'extruder_temp': st.get('extruder_temp', 0.),
            'bed_temp': st.get('bed_temp', 0.),
            'fan_speed': st.get('fan_speed', 0.),
        }
        if self.fluidd_panel:
            status['fluidd_ui'] = self._fluidd_ui
        return status

    # ------------------------------------------------------------- commands
    cmd_REPOWER_QUERY_help = "Report whether a recoverable print is available"

    def cmd_REPOWER_QUERY(self, gcmd):
        if not self.recoverable:
            gcmd.respond_info("repower: no recoverable print state")
            return
        st = self.state
        gcmd.respond_info(
            "repower: recoverable print\n"
            " file: %s\n"
            " file_position: %d\n"
            " position: X%.2f Y%.2f Z%.3f\n"
            " temps: extruder %.0f / bed %.0f\n"
            " fan: %.0f%%"
            % (st.get('file_name', '?'), st.get('file_position', 0),
               st.get('x', 0.), st.get('y', 0.), st.get('z', 0.),
               st.get('extruder_temp', 0.), st.get('bed_temp', 0.),
               st.get('fan_speed', 0.) * 100.))

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
