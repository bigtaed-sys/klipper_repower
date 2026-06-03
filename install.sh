#!/bin/bash
# =============================================================================
#  repower — installer & control panel (power-loss recovery for Klipper)
#
#  Run with no arguments for the interactive menu (install, change settings &
#  modes, notifications, language, status, uninstall). Without a TTY (e.g.
#  Moonraker auto-update) it silently installs/repairs.
#
#  Flags:
#     ./install.sh                 # menu (or silent repair without a TTY)
#     ./install.sh --menu          # force the menu
#     ./install.sh --non-interactive
#     ./install.sh --uninstall
#
#  Overrides: KLIPPER_PATH=~/klipper KLIPPER_CONFIG=~/printer_data/config
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLUGIN="repower"
BT="repower  •  power-loss recovery for Klipper"
NEED_RESTART=0

log()  { printf '\033[0;32m[repower]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[repower]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[repower]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
    err "Do not run as root. Run as the user that owns Klipper (e.g. 'pi')."
    exit 1
fi

# =============================================================================
#  UI primitives (whiptail when available, plain prompts otherwise)
# =============================================================================
HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

banner() {
    printf '\033[1;36m'
    cat <<'B'
   ┌──────────────────────────────────────────────────┐
   │   repower  ·  power-loss recovery for Klipper      │
   └──────────────────────────────────────────────────┘
B
    printf '\033[0m\n'
}

ui_menu() {   # title text  tag1 item1 [...]  -> prints chosen tag
    local title="$1" text="$2"; shift 2
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --backtitle "${BT}" --title "${title}" --notags \
            --menu "${text}" 20 76 10 "$@" 3>&1 1>&2 2>&3
    else
        echo "== ${title} ==" >&2; echo "${text}" >&2
        while [ $# -gt 0 ]; do echo "   $1) $2" >&2; shift 2; done
        local a; read -r -p "> " a </dev/tty || true; echo "${a}"
    fi
}
ui_input() {  # title text default  -> prints value
    local title="$1" text="$2" def="$3"
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --backtitle "${BT}" --title "${title}" \
            --inputbox "${text}" 11 76 "${def}" 3>&1 1>&2 2>&3
    else
        local a; read -r -p "${text} [${def}]: " a </dev/tty || true
        echo "${a:-$def}"
    fi
}
ui_yesno() {  # title text  -> 0 yes / 1 no
    local title="$1" text="$2"
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --backtitle "${BT}" --title "${title}" --yesno "${text}" 12 76
    else
        local a; read -r -p "${text} [y/N]: " a </dev/tty || true
        [[ "${a}" =~ ^[Yy] ]]
    fi
}
ui_msg() {    # title text
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --backtitle "${BT}" --title "${1}" --msgbox "${2}" 20 76
    else
        echo "== ${1} ==" >&2; printf '%s\n' "${2}" >&2
        read -r -p "[Enter]" _ </dev/tty || true
    fi
}

# =============================================================================
#  Path / service discovery
# =============================================================================
find_klipper() {
    if [ -n "${KLIPPER_PATH:-}" ] && [ -d "${KLIPPER_PATH}/klippy/extras" ]; then
        echo "${KLIPPER_PATH}"; return 0; fi
    for d in "${HOME}/klipper" "${HOME}/Klipper" /usr/share/klipper /opt/klipper; do
        [ -d "${d}/klippy/extras" ] && { echo "${d}"; return 0; }; done
    return 1
}
find_config() {
    if [ -n "${KLIPPER_CONFIG:-}" ] && [ -d "${KLIPPER_CONFIG}" ]; then
        echo "${KLIPPER_CONFIG}"; return 0; fi
    for d in "${HOME}/printer_data/config" "${HOME}/klipper_config" \
             "${HOME}/printer_config"; do
        [ -d "${d}" ] && { echo "${d}"; return 0; }; done
    return 1
}
find_service() {
    for s in klipper klipper-1 Klipper; do
        if systemctl list-unit-files "${s}.service" 2>/dev/null \
             | grep -q "${s}.service"; then echo "${s}"; return 0; fi
    done; return 1
}

EXTRAS_LINK=""; CONFIG_DIR=""; PRINTER_CFG=""; ACTIVE_CFG=""; TEMPLATE_CFG=""
resolve_paths() {
    local kp cd
    kp="$(find_klipper)" || { err "Klipper not found. Set KLIPPER_PATH."; exit 1; }
    cd="$(find_config)"  || { err "Config dir not found. Set KLIPPER_CONFIG."; exit 1; }
    KLIPPER_PATH="${kp}"; CONFIG_DIR="${cd}"
    EXTRAS_LINK="${KLIPPER_PATH}/klippy/extras/${PLUGIN}.py"
    PRINTER_CFG="${CONFIG_DIR}/printer.cfg"
    ACTIVE_CFG="${CONFIG_DIR}/${PLUGIN}.cfg"
    TEMPLATE_CFG="${SCRIPT_DIR}/${PLUGIN}.cfg"
}

# =============================================================================
#  Config helpers
# =============================================================================
# Insert a block BEFORE Klipper's "#*# SAVE_CONFIG" section (never corrupt
# saved calibration); fall back to appending when there is none.
ensure_block() {
    local file="$1" pattern="$2" block="$3"
    [ -f "${file}" ] || return 1
    grep -qE "${pattern}" "${file}" && return 1
    local marker
    marker="$(grep -nE '^#\*#' "${file}" | head -1 | cut -d: -f1 || true)"
    if [ -n "${marker}" ]; then
        local tmp="${file}.rptmp"
        { head -n "$((marker - 1))" "${file}"; printf '%s\n\n' "${block}"
          tail -n "+${marker}" "${file}"; } > "${tmp}"; mv "${tmp}" "${file}"
    else
        printf '\n%s\n' "${block}" >> "${file}"
    fi
    return 0
}
# Read an active "key: value" inside a section (empty if unset/commented).
cfg_get() {
    local file="$1" section="$2" key="$3"
    [ -f "${file}" ] || return 0
    awk -v section="${section}" -v key="${key}" '
        BEGIN { insec = 0 }
        { if ($0 ~ /^\[/) { insec = ($0 == section); next }
          if (insec && $0 ~ ("^[ \t]*" key "[ \t]*:")) {
              sub("^[ \t]*" key "[ \t]*:[ \t]*", "", $0); print $0; exit } }
    ' "${file}"
}
# Set "key: value" inside a section (replaces active or #commented line, else
# inserts at the section end). Leaves "#  key:" help comments alone.
cfg_set() {
    local file="$1" section="$2" key="$3" val="$4"
    awk -v section="${section}" -v key="${key}" -v val="${val}" '
        BEGIN { insec = 0; done = 0 }
        { if ($0 ~ /^\[/) {
              if (insec && !done) { print key ": " val; done = 1 }
              insec = ($0 == section); print; next }
          if (insec && !done && $0 ~ ("^[ \t]*#?" key "[ \t]*:")) {
              print key ": " val; done = 1; next }
          print }
        END { if (insec && !done) print key ": " val }
    ' "${file}" > "${file}.rptmp" && mv "${file}.rptmp" "${file}"
}
get_rp()  { cfg_get "${ACTIVE_CFG}" "[repower]" "$1"; }
get_mac() { cfg_get "${ACTIVE_CFG}" "[gcode_macro REPOWER_RECOVER]" "$1"; }
set_rp()  { cfg_set "${ACTIVE_CFG}" "[repower]" "$1" "$2"; NEED_RESTART=1; }
set_mac() { cfg_set "${ACTIVE_CFG}" "[gcode_macro REPOWER_RECOVER]" "$1" "$2"; NEED_RESTART=1; }
# value or default
gd() { local v; v="$(get_rp "$1")";  echo "${v:-$2}"; }
gm() { local v; v="$(get_mac "$1")"; echo "${v:-$2}"; }

restart_service() {
    local svc
    if svc="$(find_service)"; then
        log "Restarting service '${svc}'..."
        sudo systemctl restart "${svc}" \
            || warn "Could not restart ${svc}; restart it manually."
        NEED_RESTART=0
    else
        warn "Klipper service not found; restart manually (FIRMWARE_RESTART)."
    fi
}
maybe_restart() {
    [ "${NEED_RESTART}" = 1 ] || return 0
    if ui_yesno "Apply changes" "Settings changed. Restart Klipper now to apply?"; then
        restart_service
    fi
}

# =============================================================================
#  Core install (idempotent)
# =============================================================================
install_config() {
    [ -L "${ACTIVE_CFG}" ] && rm -f "${ACTIVE_CFG}"          # drop old symlink
    if [ ! -e "${ACTIVE_CFG}" ]; then
        if [ "${TEMPLATE_CFG}" -ef "${ACTIVE_CFG}" ] 2>/dev/null; then :; else
            cp "${TEMPLATE_CFG}" "${ACTIVE_CFG}"
            log "Installed ${PLUGIN}.cfg -> ${ACTIVE_CFG}"; NEED_RESTART=1
        fi
    fi
}
wire_printer_cfg() {
    [ -f "${PRINTER_CFG}" ] || { warn "printer.cfg not found — add '[include ${PLUGIN}.cfg]'."; return 0; }
    if ensure_block "${PRINTER_CFG}" \
        "^[[:space:]]*\[include ${PLUGIN}\.cfg\]" "[include ${PLUGIN}.cfg]"; then
        log "Added '[include ${PLUGIN}.cfg]'"; NEED_RESTART=1
    fi
    if grep -rqsE "^[[:space:]]*enable_force_move[[:space:]]*[:=][[:space:]]*([Tt]rue|1)" "${CONFIG_DIR}"; then
        :
    elif grep -rqsE "^[[:space:]]*\[force_move\]" "${CONFIG_DIR}"; then
        warn "[force_move] exists but enable_force_move is not True — set it."
    else
        ensure_block "${PRINTER_CFG}" "^[[:space:]]*\[force_move\]" \
"[force_move]
# Added by repower installer — required by REPOWER_RECOVER.
enable_force_move: True" && { log "Added [force_move] enable_force_move: True"; NEED_RESTART=1; }
    fi
}
wire_moonraker() {
    local origin moon=""
    origin="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)"
    for m in "${CONFIG_DIR}/moonraker.conf" \
             "${HOME}/printer_data/config/moonraker.conf"; do
        [ -f "${m}" ] && { moon="${m}"; break; }; done
    [ -n "${moon}" ] && [ -n "${origin}" ] || return 0
    ensure_block "${moon}" "^\[update_manager ${PLUGIN}\]" \
"[update_manager ${PLUGIN}]
type: git_repo
path: ${SCRIPT_DIR}
origin: ${origin}
primary_branch: main
managed_services: klipper
install_script: install.sh" && log "Added [update_manager ${PLUGIN}]"
}
core_install() {
    resolve_paths
    [ -L "${EXTRAS_LINK}" ] || NEED_RESTART=1
    ln -sf "${SCRIPT_DIR}/${PLUGIN}.py" "${EXTRAS_LINK}"
    install_config
    wire_printer_cfg
    wire_moonraker
}

# =============================================================================
#  Menu actions
# =============================================================================
edit_number() {  # section-fn-prefix label key default min max
    local kind="$1" label="$2" key="$3" def="$4"
    local cur new; cur="$( [ "${kind}" = rp ] && get_rp "${key}" || get_mac "${key}" )"
    cur="${cur:-$def}"
    new="$(ui_input "${label}" "${label}:" "${cur}")" || return 0
    [ -n "${new}" ] || return 0
    [ "${kind}" = rp ] && set_rp "${key}" "${new}" || set_mac "variable_${key}" "${new}"
}

settings_menu() {
    while true; do
        local si pg pr zh tv px py up
        si="$(gd save_interval 1.0)"
        pg="$(gm variable_purge 8)";  pr="$(gm variable_prime 0)"
        zh="$(gm variable_z_hop 5)";  tv="$(gm variable_travel_speed 150)"
        px="$(gm variable_park_x -1)"; py="$(gm variable_park_y -1)"
        up="$(gm variable_use_probe 1)"
        local up_lbl="ON"; [ "${up}" = 0 ] && up_lbl="OFF"
        local c
        c="$(ui_menu "Recovery settings" "Pick a setting to change:" \
            interval "Snapshot interval ............. ${si} s" \
            purge    "Purge after re-heat .......... ${pg} mm" \
            prime    "Prime on return .............. ${pr} mm" \
            zhop     "Z hop ........................ ${zh} mm" \
            travel   "Travel speed ................. ${tv} mm/s" \
            parkx    "Park X (<0 = off) ............ ${px}" \
            parky    "Park Y (<0 = off) ............ ${py}" \
            probe    "Probe-based Z recovery ....... ${up_lbl}" \
            back     "‹ Back")" || return 0
        case "${c}" in
            interval) local v; v="$(ui_input "Snapshot interval" "Seconds (lower = less lost, more writes):" "${si}")" && [ -n "${v}" ] && set_rp save_interval "${v}";;
            purge)  edit_number mac "Purge (mm)" purge 8;;
            prime)  edit_number mac "Prime (mm)" prime 0;;
            zhop)   edit_number mac "Z hop (mm)" z_hop 5;;
            travel) edit_number mac "Travel speed (mm/s)" travel_speed 150;;
            parkx)  edit_number mac "Park X (<0 disables)" park_x -1;;
            parky)  edit_number mac "Park Y (<0 disables)" park_y -1;;
            probe)
                if ui_yesno "Probe-based Z recovery" "Probe a clear bed area to re-establish true Z on recovery?\n\nNeeds a probe; safe on screw Z. (Currently: ${up_lbl})"; then
                    set_mac variable_use_probe 1
                else
                    set_mac variable_use_probe 0
                fi;;
            *) return 0;;
        esac
    done
}

notify_menu() {
    while true; do
        local ch; ch="$(gd notify none)"
        local c
        c="$(ui_menu "Notifications" "Channel: ${ch}" \
            telegram "Use Telegram" \
            ntfy     "Use ntfy" \
            none     "Disable notifications" \
            test     "Send a test notification" \
            back     "‹ Back")" || return 0
        case "${c}" in
            telegram)
                local tok chat
                tok="$(ui_input "Telegram" "Bot token (from @BotFather):" "$(get_rp notify_telegram_token)")" || continue
                chat="$(ui_input "Telegram" "Chat id (numeric):" "$(get_rp notify_telegram_chat)")" || continue
                set_rp notify telegram
                set_rp notify_telegram_token "${tok}"
                set_rp notify_telegram_chat "${chat}";;
            ntfy)
                local topic url
                topic="$(ui_input "ntfy" "Topic (subscribe to it in the app):" "$(get_rp notify_ntfy_topic)")" || continue
                url="$(ui_input "ntfy" "Server URL:" "$(gd notify_ntfy_url https://ntfy.sh)")" || continue
                set_rp notify ntfy
                set_rp notify_ntfy_topic "${topic}"
                set_rp notify_ntfy_url "${url}";;
            none) set_rp notify none;;
            test) test_notify;;
            *) return 0;;
        esac
    done
}

test_notify() {
    local ch; ch="$(gd notify none)"
    [ "${ch}" = none ] && { ui_msg "Test" "Notifications are disabled."; return; }
    command -v curl >/dev/null 2>&1 || { ui_msg "Test" "curl not found."; return; }
    local ok=1
    if [ "${ch}" = telegram ]; then
        curl -fsS "https://api.telegram.org/bot$(get_rp notify_telegram_token)/sendMessage" \
            --data-urlencode "chat_id=$(get_rp notify_telegram_chat)" \
            --data-urlencode "text=repower: test notification" >/dev/null 2>&1 && ok=0
    elif [ "${ch}" = ntfy ]; then
        curl -fsS -d "repower: test notification" \
            "$(gd notify_ntfy_url https://ntfy.sh)/$(get_rp notify_ntfy_topic)" >/dev/null 2>&1 && ok=0
    fi
    [ "${ok}" = 0 ] && ui_msg "Test" "Sent — check your device." \
                    || ui_msg "Test" "Failed to send. Check token/topic and network."
}

language_menu() {
    local cur; cur="$(gd language en)"
    local c
    c="$(ui_menu "Language" "Dialog & notification language (current: ${cur}):" \
        en "English" ru "Русский" back "‹ Back")" || return 0
    case "${c}" in en|ru) set_rp language "${c}";; esac
}

status_screen() {
    local txt
    txt="Klipper:    ${KLIPPER_PATH}
Config:     ${ACTIVE_CFG}
Module:     ${EXTRAS_LINK}

language:        $(gd language en)
save_interval:   $(gd save_interval 1.0) s
notify:          $(gd notify none)
use_probe:       $(gm variable_use_probe 1)
purge / prime:   $(gm variable_purge 8) / $(gm variable_prime 0) mm
z_hop / travel:  $(gm variable_z_hop 5) / $(gm variable_travel_speed 150)
park_x / park_y: $(gm variable_park_x -1) / $(gm variable_park_y -1)

Pending restart: $( [ "${NEED_RESTART}" = 1 ] && echo yes || echo no )"
    ui_msg "Current configuration" "${txt}"
}

do_uninstall() {
    resolve_paths
    ui_yesno "Uninstall" "Remove the repower module link and restart Klipper?\n\n(${PLUGIN}.cfg and printer.cfg/moonraker entries are left in place.)" \
        || return 0
    [ -L "${EXTRAS_LINK}" ] && { rm -f "${EXTRAS_LINK}"; log "Removed module link"; }
    warn "Left ${PLUGIN}.cfg + [include]/[force_move]/[update_manager] entries."
    restart_service
    ui_msg "Uninstall" "Done. Module unlinked and Klipper restarted."
}

main_menu() {
    while true; do
        local rflag=""; [ "${NEED_RESTART}" = 1 ] && rflag="  (changes pending)"
        local c
        c="$(ui_menu "Main menu${rflag}" "repower control panel" \
            settings  "Recovery settings & modes" \
            notify    "Notifications" \
            language  "Language" \
            status    "Show current configuration" \
            apply     "Apply changes (restart Klipper)" \
            reinstall "Reinstall / repair links" \
            uninstall "Uninstall" \
            quit      "Exit")" || { maybe_restart; return 0; }
        case "${c}" in
            settings)  settings_menu;;
            notify)    notify_menu;;
            language)  language_menu;;
            status)    status_screen;;
            apply)     restart_service;;
            reinstall) core_install; ui_msg "Reinstall" "Links and config verified.";;
            uninstall) do_uninstall;;
            quit)      maybe_restart; return 0;;
        esac
    done
}

# =============================================================================
#  Entry point
# =============================================================================
INTERACTIVE=1; { [ -t 0 ] && [ -t 1 ]; } || INTERACTIVE=0

case "${1:-}" in
    --uninstall|-u)    do_uninstall ;;
    --non-interactive) core_install; restart_service; log "Done." ;;
    --menu|--reconfigure)
        [ "${INTERACTIVE}" = 1 ] || { err "No TTY for the menu."; exit 1; }
        banner; core_install; main_menu ;;
    ""|--install)
        if [ "${INTERACTIVE}" = 1 ]; then banner; core_install; main_menu
        else core_install; restart_service; log "Done."; fi ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "Unknown option: $1"; exit 1 ;;
esac
