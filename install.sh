#!/bin/bash
# =============================================================================
#  Installer for the "repower" power-loss recovery plugin for Klipper.
#
#  Interactive & self-contained. Auto-detects Klipper and the config dir,
#  links the module, installs a user-owned config, wires up printer.cfg
#  ([include] + [force_move]), adds a Moonraker update_manager entry, and
#  restarts the service. On first run it offers a guided setup (menu language,
#  snapshot interval, purge, push notifications). Re-runs without a TTY (e.g.
#  Moonraker auto-update) skip all prompts and just repair the install.
#
#  Usage:
#     ./install.sh                 # guided install / repair
#     ./install.sh --non-interactive
#     ./install.sh --reconfigure   # re-run the guided setup only
#     ./install.sh --uninstall
#
#  Overrides: KLIPPER_PATH=~/klipper KLIPPER_CONFIG=~/printer_data/config
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLUGIN="repower"

log()  { printf '\033[0;32m[repower]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[repower]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[repower]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
    err "Do not run as root. Run as the user that owns Klipper (e.g. 'pi')."
    exit 1
fi

# --- Setup defaults (overridden by the guided setup) -------------------------
PANEL_LANG="en"
SAVE_INTERVAL="1.0"
PURGE="8"
NOTIFY="none"
TG_TOKEN=""
TG_CHAT=""
NTFY_URL="https://ntfy.sh"
NTFY_TOPIC=""
INSTALLER_LANG="en"

# =============================================================================
#  Localized installer messages
# =============================================================================
declare -A MSG_EN=(
    [welcome]="repower setup — power-loss recovery for Klipper"
    [ask_interval]="Snapshot interval in seconds (lower = less lost progress, more disk writes)"
    [ask_purge]="Purge length after re-heating, in mm (clears ooze before resuming)"
    [notify_text]="Push a notification when a recoverable print is found after a power loss?"
    [notify_none]="No notifications"
    [ask_tg_token]="Telegram bot token (from @BotFather)"
    [ask_tg_chat]="Telegram chat id (your numeric id)"
    [ask_ntfy_topic]="ntfy topic (subscribe to it in the ntfy app)"
    [ask_ntfy_url]="ntfy server URL"
    [test_q]="Send a test notification now?"
    [test_ok]="Test sent — check your device."
    [test_fail]="Test failed to send (check token/topic and network)."
    [summary]="Setup summary"
    [done]="Install complete. After restart, open Fluidd or run REPOWER_QUERY."
)
declare -A MSG_RU=(
    [welcome]="Настройка repower — восстановление печати после потери питания"
    [ask_interval]="Интервал снапшотов в секундах (меньше = меньше потерь, чаще запись на диск)"
    [ask_purge]="Длина прочистки после нагрева, мм (убирает каплю перед продолжением)"
    [notify_text]="Слать уведомление, когда после сбоя найдена восстановимая печать?"
    [notify_none]="Без уведомлений"
    [ask_tg_token]="Токен Telegram-бота (от @BotFather)"
    [ask_tg_chat]="Telegram chat id (ваш числовой id)"
    [ask_ntfy_topic]="Тема ntfy (подпишитесь на неё в приложении ntfy)"
    [ask_ntfy_url]="URL сервера ntfy"
    [test_q]="Отправить тестовое уведомление сейчас?"
    [test_ok]="Тест отправлен — проверьте устройство."
    [test_fail]="Не удалось отправить тест (проверьте токен/тему и сеть)."
    [summary]="Итог настройки"
    [done]="Установка завершена. После рестарта откройте Fluidd или REPOWER_QUERY."
)
t() {
    local k="$1"
    if [ "${INSTALLER_LANG}" = "ru" ]; then echo "${MSG_RU[$k]}"
    else echo "${MSG_EN[$k]}"; fi
}

# =============================================================================
#  UI primitives (whiptail when available, plain prompts otherwise)
# =============================================================================
HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

ui_menu() {   # title text  tag1 item1 [tag2 item2 ...]  -> prints chosen tag
    local title="$1" text="$2"; shift 2
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --title "${title}" --notags --menu "${text}" 18 74 6 \
            "$@" 3>&1 1>&2 2>&3
    else
        echo "${text}" >&2
        local tag item
        while [ $# -gt 0 ]; do tag="$1"; item="$2"; shift 2
            echo "   ${tag}) ${item}" >&2; done
        local ans; read -r -p "> " ans </dev/tty || true; echo "${ans}"
    fi
}
ui_input() {  # title text default  -> prints value
    local title="$1" text="$2" def="$3"
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --title "${title}" --inputbox "${text}" 11 74 "${def}" \
            3>&1 1>&2 2>&3
    else
        local ans; read -r -p "${text} [${def}]: " ans </dev/tty || true
        echo "${ans:-$def}"
    fi
}
ui_yesno() {  # title text  -> return 0 (yes) / 1 (no)
    local title="$1" text="$2"
    if [ "${HAS_WHIPTAIL}" = 1 ]; then
        whiptail --title "${title}" --yesno "${text}" 11 74
    else
        local ans; read -r -p "${text} [y/N]: " ans </dev/tty || true
        [[ "${ans}" =~ ^[Yy] ]]
    fi
}

# =============================================================================
#  Path / service discovery
# =============================================================================
find_klipper() {
    if [ -n "${KLIPPER_PATH:-}" ] && [ -d "${KLIPPER_PATH}/klippy/extras" ]; then
        echo "${KLIPPER_PATH}"; return 0
    fi
    for d in "${HOME}/klipper" "${HOME}/Klipper" /usr/share/klipper /opt/klipper; do
        [ -d "${d}/klippy/extras" ] && { echo "${d}"; return 0; }
    done
    return 1
}
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
find_service() {
    for s in klipper klipper-1 Klipper; do
        if systemctl list-unit-files "${s}.service" 2>/dev/null \
             | grep -q "${s}.service"; then
            echo "${s}"; return 0
        fi
    done
    return 1
}

EXTRAS_LINK=""; CONFIG_DIR=""; PRINTER_CFG=""; ACTIVE_CFG=""; TEMPLATE_CFG=""
resolve_paths() {
    KLIPPER_PATH="$(find_klipper)" || {
        err "Klipper not found. Set KLIPPER_PATH=/path/to/klipper and re-run."
        exit 1; }
    EXTRAS_LINK="${KLIPPER_PATH}/klippy/extras/${PLUGIN}.py"
    CONFIG_DIR="$(find_config)" || {
        err "Config dir not found. Set KLIPPER_CONFIG=/path and re-run."
        exit 1; }
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
          tail -n "+${marker}" "${file}"; } > "${tmp}"
        mv "${tmp}" "${file}"
    else
        printf '\n%s\n' "${block}" >> "${file}"
    fi
    return 0
}

# Set "key: value" inside a given section (replaces an active or #commented
# line, else inserts at the end of the section). Comment help-lines with
# spaces after '#' are left alone.
cfg_set() {
    local file="$1" section="$2" key="$3" val="$4"
    awk -v section="${section}" -v key="${key}" -v val="${val}" '
        BEGIN { insec = 0; done = 0 }
        {
            if ($0 ~ /^\[/) {
                if (insec && !done) { print key ": " val; done = 1 }
                insec = ($0 == section); print; next
            }
            if (insec && !done && $0 ~ ("^[ \t]*#?" key "[ \t]*:")) {
                print key ": " val; done = 1; next
            }
            print
        }
        END { if (insec && !done) print key ": " val }
    ' "${file}" > "${file}.rptmp" && mv "${file}.rptmp" "${file}"
}

restart_service() {
    local svc
    if svc="$(find_service)"; then
        log "Restarting service '${svc}'..."
        sudo systemctl restart "${svc}" \
            || warn "Could not restart ${svc}; restart it manually."
    else
        warn "Klipper service not found; restart manually (FIRMWARE_RESTART)."
    fi
}

# =============================================================================
#  Guided setup
# =============================================================================
configure() {
    INSTALLER_LANG="$(ui_menu "Язык / Language" \
        "Выберите язык / Choose a language" \
        en "English" ru "Русский")" || INSTALLER_LANG="en"
    [ -n "${INSTALLER_LANG}" ] || INSTALLER_LANG="en"
    PANEL_LANG="${INSTALLER_LANG}"

    SAVE_INTERVAL="$(ui_input "repower" "$(t ask_interval)" "${SAVE_INTERVAL}")" \
        || true
    PURGE="$(ui_input "repower" "$(t ask_purge)" "${PURGE}")" || true

    NOTIFY="$(ui_menu "repower" "$(t notify_text)" \
        none "$(t notify_none)" telegram "Telegram" ntfy "ntfy")" \
        || NOTIFY="none"
    [ -n "${NOTIFY}" ] || NOTIFY="none"
    if [ "${NOTIFY}" = "telegram" ]; then
        TG_TOKEN="$(ui_input "Telegram" "$(t ask_tg_token)" "")" || true
        TG_CHAT="$(ui_input "Telegram" "$(t ask_tg_chat)" "")" || true
    elif [ "${NOTIFY}" = "ntfy" ]; then
        NTFY_TOPIC="$(ui_input "ntfy" "$(t ask_ntfy_topic)" "")" || true
        NTFY_URL="$(ui_input "ntfy" "$(t ask_ntfy_url)" "${NTFY_URL}")" || true
    fi

    log "$(t summary):"
    log "  language=${PANEL_LANG}  save_interval=${SAVE_INTERVAL}  purge=${PURGE}"
    log "  notify=${NOTIFY}"
}

send_test_notification() {
    command -v curl >/dev/null 2>&1 || return 0
    [ "${NOTIFY}" = "none" ] && return 0
    ui_yesno "repower" "$(t test_q)" || return 0
    local ok=1
    if [ "${NOTIFY}" = "telegram" ] && [ -n "${TG_TOKEN}" ]; then
        curl -fsS "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT}" \
            --data-urlencode "text=repower: test notification" \
            >/dev/null 2>&1 && ok=0
    elif [ "${NOTIFY}" = "ntfy" ] && [ -n "${NTFY_TOPIC}" ]; then
        curl -fsS -d "repower: test notification" \
            "${NTFY_URL%/}/${NTFY_TOPIC}" >/dev/null 2>&1 && ok=0
    fi
    [ "${ok}" = 0 ] && log "$(t test_ok)" || warn "$(t test_fail)"
}

install_config() {
    # User-owned config: copy the template once, then keep the user's edits.
    if [ -L "${ACTIVE_CFG}" ]; then rm -f "${ACTIVE_CFG}"; fi   # old symlink
    if [ ! -e "${ACTIVE_CFG}" ]; then
        if [ "${TEMPLATE_CFG}" -ef "${ACTIVE_CFG}" ] 2>/dev/null; then :; else
            cp "${TEMPLATE_CFG}" "${ACTIVE_CFG}"
            log "Installed ${PLUGIN}.cfg -> ${ACTIVE_CFG}"
        fi
    fi
}

apply_config() {
    [ -f "${ACTIVE_CFG}" ] || return 0
    cfg_set "${ACTIVE_CFG}" "[repower]" "language" "${PANEL_LANG}"
    cfg_set "${ACTIVE_CFG}" "[repower]" "save_interval" "${SAVE_INTERVAL}"
    cfg_set "${ACTIVE_CFG}" "[repower]" "notify" "${NOTIFY}"
    if [ "${NOTIFY}" = "telegram" ]; then
        cfg_set "${ACTIVE_CFG}" "[repower]" "notify_telegram_token" "${TG_TOKEN}"
        cfg_set "${ACTIVE_CFG}" "[repower]" "notify_telegram_chat" "${TG_CHAT}"
    elif [ "${NOTIFY}" = "ntfy" ]; then
        cfg_set "${ACTIVE_CFG}" "[repower]" "notify_ntfy_topic" "${NTFY_TOPIC}"
        cfg_set "${ACTIVE_CFG}" "[repower]" "notify_ntfy_url" "${NTFY_URL}"
    fi
    cfg_set "${ACTIVE_CFG}" "[gcode_macro REPOWER_RECOVER]" \
        "variable_purge" "${PURGE}"
    log "Applied settings to ${ACTIVE_CFG}"
}

wire_printer_cfg() {
    if [ ! -f "${PRINTER_CFG}" ]; then
        warn "printer.cfg not found — add '[include ${PLUGIN}.cfg]' yourself."
        return 0
    fi
    if ensure_block "${PRINTER_CFG}" \
        "^[[:space:]]*\[include ${PLUGIN}\.cfg\]" "[include ${PLUGIN}.cfg]"; then
        log "Added '[include ${PLUGIN}.cfg]' to printer.cfg"
    else
        log "printer.cfg already includes ${PLUGIN}.cfg"
    fi
    if grep -rqsE "^[[:space:]]*enable_force_move[[:space:]]*[:=][[:space:]]*([Tt]rue|1)" "${CONFIG_DIR}"; then
        log "[force_move] already enabled"
    elif grep -rqsE "^[[:space:]]*\[force_move\]" "${CONFIG_DIR}"; then
        warn "[force_move] exists but enable_force_move is not True — set it."
    else
        ensure_block "${PRINTER_CFG}" "^[[:space:]]*\[force_move\]" \
"[force_move]
# Added by repower installer — required by REPOWER_RECOVER.
enable_force_move: True" && log "Added [force_move] enable_force_move: True"
    fi
}

wire_moonraker() {
    local origin moon=""
    origin="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)"
    for m in "${CONFIG_DIR}/moonraker.conf" \
             "${HOME}/printer_data/config/moonraker.conf"; do
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
        warn "Skipped Moonraker update_manager (moonraker.conf/origin missing)."
    fi
}

# =============================================================================
#  Top-level flows
# =============================================================================
do_install() {
    local interactive="$1"
    resolve_paths
    log "Klipper:    ${KLIPPER_PATH}"
    log "Config dir: ${CONFIG_DIR}"

    ln -sf "${SCRIPT_DIR}/${PLUGIN}.py" "${EXTRAS_LINK}"
    log "Linked ${PLUGIN}.py -> ${EXTRAS_LINK}"

    install_config
    if [ "${interactive}" = 1 ]; then
        log "$(t welcome)"
        configure
        apply_config
    fi
    wire_printer_cfg
    wire_moonraker
    restart_service
    [ "${interactive}" = 1 ] && send_test_notification || true
    echo
    log "$(t done)"
}

do_reconfigure() {
    resolve_paths
    install_config
    configure
    apply_config
    restart_service
    log "$(t done)"
}

do_uninstall() {
    resolve_paths
    log "Uninstalling..."
    [ -L "${EXTRAS_LINK}" ] && { rm -f "${EXTRAS_LINK}"; log "Removed module link"; }
    warn "Left ${PLUGIN}.cfg and printer.cfg/moonraker.conf entries in place."
    warn "Remove [include ${PLUGIN}.cfg], [force_move] and"
    warn "[update_manager ${PLUGIN}] by hand if you no longer need them."
    restart_service
    log "Uninstall done."
}

# --- Entry point -------------------------------------------------------------
INTERACTIVE=1
[ -t 0 ] && [ -t 1 ] || INTERACTIVE=0

case "${1:-}" in
    --uninstall|-u) do_uninstall ;;
    --reconfigure)  do_reconfigure ;;
    --non-interactive) do_install 0 ;;
    ""|--install)   do_install "${INTERACTIVE}" ;;
    -h|--help)      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "Unknown option: $1"; exit 1 ;;
esac
