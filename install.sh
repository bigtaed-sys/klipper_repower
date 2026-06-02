#!/bin/bash
# =============================================================================
#  Installer for the "repower" power-loss recovery plugin for Klipper.
#
#  Self-contained: auto-detects Klipper and the config directory, links the
#  module and config, wires up printer.cfg ([include] + [force_move]), adds a
#  Moonraker update_manager entry, and restarts the service.
#
#  Usage:
#     ./install.sh                 # install / repair (idempotent)
#     ./install.sh --uninstall     # remove everything this script added
#
#  Override autodetection with environment variables, e.g.:
#     KLIPPER_PATH=~/klipper KLIPPER_CONFIG=~/printer_data/config ./install.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLUGIN="repower"

log()  { printf '\033[0;32m[repower]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[repower]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[repower]\033[0m %s\n' "$*" >&2; }

# --- Refuse to run as root (Klipper runs as a normal user) -------------------
if [ "$(id -u)" -eq 0 ]; then
    err "Do not run as root. Run as the user that owns Klipper (e.g. 'pi')."
    exit 1
fi

# --- Locate the Klipper installation -----------------------------------------
find_klipper() {
    if [ -n "${KLIPPER_PATH:-}" ] && [ -d "${KLIPPER_PATH}/klippy/extras" ]; then
        echo "${KLIPPER_PATH}"; return 0
    fi
    for d in "${HOME}/klipper" "${HOME}/Klipper" /usr/share/klipper /opt/klipper; do
        [ -d "${d}/klippy/extras" ] && { echo "${d}"; return 0; }
    done
    return 1
}

# --- Locate the printer config directory -------------------------------------
find_config() {
    if [ -n "${KLIPPER_CONFIG:-}" ] && [ -d "${KLIPPER_CONFIG}" ]; then
        echo "${KLIPPER_CONFIG}"; return 0
    fi
    for d in "${HOME}/printer_data/config" "${HOME}/klipper_config" \
             "${HOME}/printer_config"; do
        [ -d "${d}" ] && { echo "${d}"; return 0; }
    done
    return 1
}

# --- Detect the systemd service name for the Klipper host --------------------
find_service() {
    for s in klipper klipper-1 Klipper; do
        if systemctl list-unit-files "${s}.service" >/dev/null 2>&1 \
           && systemctl list-unit-files "${s}.service" | grep -q "${s}.service"; then
            echo "${s}"; return 0
        fi
    done
    return 1
}

EXTRAS_LINK=""        # set after KLIPPER_PATH known
CONFIG_DIR=""
PRINTER_CFG=""
CFG_LINK=""

resolve_paths() {
    KLIPPER_PATH="$(find_klipper)" || {
        err "Klipper not found. Set KLIPPER_PATH=/path/to/klipper and re-run."
        exit 1
    }
    EXTRAS_LINK="${KLIPPER_PATH}/klippy/extras/${PLUGIN}.py"

    CONFIG_DIR="$(find_config)" || {
        err "Config dir not found. Set KLIPPER_CONFIG=/path/to/config and re-run."
        exit 1
    }
    PRINTER_CFG="${CONFIG_DIR}/printer.cfg"
    CFG_LINK="${CONFIG_DIR}/${PLUGIN}.cfg"
}

# --- Idempotently insert a block into a config file --------------------------
# Inserts BEFORE Klipper's "#*# <--- SAVE_CONFIG --->" auto-generated section
# (probe offsets, bed meshes, etc.) so we never corrupt saved calibration.
# Falls back to appending when there is no SAVE_CONFIG block.
ensure_block() {
    # $1 = file, $2 = grep pattern that proves it's already there, $3 = block
    local file="$1" pattern="$2" block="$3"
    if [ -f "${file}" ] && grep -qE "${pattern}" "${file}"; then
        return 1   # already present
    fi
    if [ ! -f "${file}" ]; then
        return 1
    fi
    local marker
    marker="$(grep -nE '^#\*#' "${file}" | head -1 | cut -d: -f1)"
    if [ -n "${marker}" ]; then
        local tmp="${file}.repower.tmp"
        {
            head -n "$((marker - 1))" "${file}"
            printf '%s\n\n' "${block}"
            tail -n "+${marker}" "${file}"
        } > "${tmp}"
        mv "${tmp}" "${file}"
    else
        printf '\n%s\n' "${block}" >> "${file}"
    fi
    return 0       # added
}

restart_service() {
    local svc
    if svc="$(find_service)"; then
        log "Restarting service '${svc}'..."
        sudo systemctl restart "${svc}" || warn "Could not restart ${svc}; restart it manually."
    else
        warn "Klipper service not found; restart the host manually (or via FIRMWARE_RESTART)."
    fi
}

# =============================================================================
#  Uninstall
# =============================================================================
do_uninstall() {
    resolve_paths
    log "Uninstalling..."
    [ -L "${EXTRAS_LINK}" ] && { rm -f "${EXTRAS_LINK}"; log "Removed ${EXTRAS_LINK}"; }
    [ -L "${CFG_LINK}" ]    && { rm -f "${CFG_LINK}";    log "Removed ${CFG_LINK}"; }
    warn "Left printer.cfg/moonraker.conf untouched — remove the [include ${PLUGIN}.cfg],"
    warn "[force_move] and [update_manager ${PLUGIN}] entries by hand if you no longer need them."
    restart_service
    log "Uninstall done."
}

# =============================================================================
#  Install
# =============================================================================
do_install() {
    resolve_paths
    log "Klipper:    ${KLIPPER_PATH}"
    log "Config dir: ${CONFIG_DIR}"

    # 1) Link the python module into klippy/extras.
    ln -sf "${SCRIPT_DIR}/${PLUGIN}.py" "${EXTRAS_LINK}"
    log "Linked ${PLUGIN}.py -> ${EXTRAS_LINK}"

    # 2) Link the config into the printer config directory.
    ln -sf "${SCRIPT_DIR}/${PLUGIN}.cfg" "${CFG_LINK}"
    log "Linked ${PLUGIN}.cfg -> ${CFG_LINK}"

    # 3) Make sure printer.cfg includes it.
    if [ ! -f "${PRINTER_CFG}" ]; then
        warn "printer.cfg not found at ${PRINTER_CFG} — add '[include ${PLUGIN}.cfg]' yourself."
    elif ensure_block "${PRINTER_CFG}" "^[[:space:]]*\[include ${PLUGIN}\.cfg\]" "[include ${PLUGIN}.cfg]"; then
        log "Added '[include ${PLUGIN}.cfg]' to printer.cfg"
    else
        log "printer.cfg already includes ${PLUGIN}.cfg"
    fi

    # 4) Ensure [force_move] with enable_force_move is present (needed for the
    #    Z handling in REPOWER_RECOVER). Check across all .cfg files so we
    #    never add a duplicate [force_move] section (that is a config error).
    if [ -f "${PRINTER_CFG}" ]; then
        if grep -rqsE "^[[:space:]]*enable_force_move[[:space:]]*[:=][[:space:]]*([Tt]rue|1)" "${CONFIG_DIR}"; then
            log "[force_move] (enable_force_move) already enabled"
        elif grep -rqsE "^[[:space:]]*\[force_move\]" "${CONFIG_DIR}"; then
            warn "A [force_move] section exists but enable_force_move is not True."
            warn "Set 'enable_force_move: True' there — REPOWER_RECOVER needs it."
        else
            ensure_block "${PRINTER_CFG}" "^[[:space:]]*\[force_move\]" \
"[force_move]
# Added by repower installer — required by REPOWER_RECOVER.
enable_force_move: True" \
                && log "Added [force_move] enable_force_move: True to printer.cfg"
        fi
    fi

    # 5) Add a Moonraker update_manager entry so the plugin updates from the UI.
    local origin
    origin="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)"
    local moon=""
    for m in "${CONFIG_DIR}/moonraker.conf" "${HOME}/printer_data/config/moonraker.conf"; do
        [ -f "${m}" ] && { moon="${m}"; break; }
    done
    if [ -n "${moon}" ] && [ -n "${origin}" ]; then
        if ensure_block "${moon}" "^\[update_manager ${PLUGIN}\]" \
"[update_manager ${PLUGIN}]
type: git_repo
path: ${SCRIPT_DIR}
origin: ${origin}
primary_branch: main
managed_services: klipper
install_script: install.sh"; then
            log "Added [update_manager ${PLUGIN}] to ${moon}"
        else
            log "Moonraker update_manager already configured"
        fi
    else
        warn "Skipped Moonraker update_manager (moonraker.conf or git origin not found)."
    fi

    # 6) Restart Klipper to load the new module.
    restart_service

    echo
    log "Install complete. After restart, run REPOWER_QUERY in the console to verify."
}

# --- Entry point -------------------------------------------------------------
case "${1:-}" in
    --uninstall|-u) do_uninstall ;;
    ""|--install)   do_install ;;
    -h|--help)
        grep -E '^#( |$|====)' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        err "Unknown option: $1 (use --install or --uninstall)"; exit 1 ;;
esac
