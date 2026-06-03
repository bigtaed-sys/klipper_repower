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
#  Localization (the control panel itself, EN/RU)
# =============================================================================
UI_LANG="en"
declare -A MSG_EN=(
    [mm_title]="Main menu"           [mm_sub]="repower control panel"
    [mm_pending]="  (changes pending)"
    [mm_settings]="Recovery settings & modes"
    [mm_notify]="Notifications"      [mm_language]="Language"
    [mm_status]="Show current configuration"
    [mm_apply]="Apply changes (restart Klipper)"
    [mm_reinstall]="Reinstall / repair links"
    [mm_uninstall]="Uninstall"       [mm_quit]="Exit"
    [back]="‹ Back"
    [set_title]="Recovery settings"  [set_pick]="Pick a setting to change:"
    [set_interval]="Snapshot interval"   [set_purge]="Purge after re-heat"
    [set_prime]="Prime on return"        [set_zhop]="Z hop"
    [set_travel]="Travel speed"          [set_parkx]="Park X (<0 = off)"
    [set_party]="Park Y (<0 = off)"      [set_probe]="Probe-based Z recovery"
    [on]="ON" [off]="OFF"
    [q_interval]="Seconds (lower = less lost progress, more disk writes):"
    [l_purge]="Purge (mm)"  [l_prime]="Prime (mm)"  [l_zhop]="Z hop (mm)"
    [l_travel]="Travel speed (mm/s)"
    [l_parkx]="Park X (<0 disables)"  [l_party]="Park Y (<0 disables)"
    [probe_title]="Probe-based Z recovery"
    [probe_q]="Probe a clear bed area to re-establish true Z on recovery?\n\nNeeds a probe; safe on screw Z."
    [nt_title]="Notifications"           [nt_channel]="Channel"
    [nt_telegram]="Use Telegram"         [nt_ntfy]="Use ntfy"
    [nt_none]="Disable notifications"    [nt_test]="Send a test notification"
    [tg_token]="Bot token (from @BotFather):"
    [tg_chat]="Chat id (numeric):"
    [ntfy_topic]="Topic (subscribe to it in the ntfy app):"
    [ntfy_url]="Server URL:"
    [test_title]="Test notification"
    [test_disabled]="Notifications are disabled."
    [test_nocurl]="curl not found."
    [test_ok]="Sent — check your device."
    [test_fail]="Failed to send. Check token/topic and network."
    [lang_title]="Language"
    [lang_q]="Dialog & notification language (current: %s):"
    [st_title]="Current configuration"  [st_pending]="Pending restart"
    [yes]="yes" [no]="no"
    [un_title]="Uninstall"
    [un_q]="Remove the repower module link and restart Klipper?\n\n(repower.cfg and printer.cfg/moonraker entries are left in place.)"
    [un_done]="Done. Module unlinked and Klipper restarted."
    [apply_title]="Apply changes"
    [apply_q]="Settings changed. Restart Klipper now to apply?"
    [ri_title]="Reinstall"  [ri_done]="Links and config verified."
)
declare -A MSG_RU=(
    [mm_title]="Главное меню"        [mm_sub]="Панель управления repower"
    [mm_pending]="  (есть изменения)"
    [mm_settings]="Настройки и режимы восстановления"
    [mm_notify]="Уведомления"        [mm_language]="Язык"
    [mm_status]="Показать текущую конфигурацию"
    [mm_apply]="Применить (перезапуск Klipper)"
    [mm_reinstall]="Переустановить / починить ссылки"
    [mm_uninstall]="Удалить"         [mm_quit]="Выход"
    [back]="‹ Назад"
    [set_title]="Настройки восстановления"  [set_pick]="Выберите, что изменить:"
    [set_interval]="Интервал снапшотов"   [set_purge]="Прочистка после нагрева"
    [set_prime]="Прайм при возврате"      [set_zhop]="Подъём Z"
    [set_travel]="Скорость перемещения"   [set_parkx]="Парковка X (<0 = выкл)"
    [set_party]="Парковка Y (<0 = выкл)"  [set_probe]="Восстановление Z пробой"
    [on]="ВКЛ" [off]="ВЫКЛ"
    [q_interval]="Секунды (меньше = меньше потерь, чаще запись):"
    [l_purge]="Прочистка (мм)"  [l_prime]="Прайм (мм)"  [l_zhop]="Подъём Z (мм)"
    [l_travel]="Скорость перемещения (мм/с)"
    [l_parkx]="Парковка X (<0 — выкл)"  [l_party]="Парковка Y (<0 — выкл)"
    [probe_title]="Восстановление Z пробой"
    [probe_q]="Щупать чистый участок стола, чтобы измерить истинный Z при восстановлении?\n\nНужна проба; безопасно для винтового Z."
    [nt_title]="Уведомления"             [nt_channel]="Канал"
    [nt_telegram]="Использовать Telegram" [nt_ntfy]="Использовать ntfy"
    [nt_none]="Выключить уведомления"    [nt_test]="Отправить тест"
    [tg_token]="Токен бота (от @BotFather):"
    [tg_chat]="Chat id (числовой):"
    [ntfy_topic]="Тема (подпишитесь в приложении ntfy):"
    [ntfy_url]="URL сервера:"
    [test_title]="Тест уведомления"
    [test_disabled]="Уведомления выключены."
    [test_nocurl]="curl не найден."
    [test_ok]="Отправлено — проверьте устройство."
    [test_fail]="Не удалось отправить. Проверьте токен/тему и сеть."
    [lang_title]="Язык"
    [lang_q]="Язык диалогов и уведомлений (сейчас: %s):"
    [st_title]="Текущая конфигурация"  [st_pending]="Нужен перезапуск"
    [yes]="да" [no]="нет"
    [un_title]="Удаление"
    [un_q]="Снять ссылку на модуль repower и перезапустить Klipper?\n\n(repower.cfg и записи в printer.cfg/moonraker остаются.)"
    [un_done]="Готово. Модуль отвязан, Klipper перезапущен."
    [apply_title]="Применить изменения"
    [apply_q]="Настройки изменены. Перезапустить Klipper сейчас?"
    [ri_title]="Переустановка"  [ri_done]="Ссылки и конфиг проверены."
)
t() {
    local k="$1" v=""
    if [ "${UI_LANG}" = "ru" ]; then v="${MSG_RU[$k]:-}"; fi
    [ -n "${v}" ] || v="${MSG_EN[$k]:-$k}"
    printf '%s' "${v}"
}

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
    if ui_yesno "$(t apply_title)" "$(t apply_q)"; then
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
edit_number() {  # label key default
    local label="$1" key="$2" def="$3"
    local cur new; cur="$(get_mac "variable_${key}")"; cur="${cur:-$def}"
    new="$(ui_input "${label}" "${label}:" "${cur}")" || return 0
    [ -n "${new}" ] || return 0
    set_mac "variable_${key}" "${new}"
}

settings_menu() {
    while true; do
        local si pg pr zh tv px py up up_lbl c
        si="$(gd save_interval 1.0)"
        pg="$(gm variable_purge 8)";  pr="$(gm variable_prime 0)"
        zh="$(gm variable_z_hop 5)";  tv="$(gm variable_travel_speed 150)"
        px="$(gm variable_park_x -1)"; py="$(gm variable_park_y -1)"
        up="$(gm variable_use_probe 1)"
        up_lbl="$(t on)"; [ "${up}" = 0 ] && up_lbl="$(t off)"
        c="$(ui_menu "$(t set_title)" "$(t set_pick)" \
            interval "$(t set_interval): ${si} s" \
            purge    "$(t set_purge): ${pg} mm" \
            prime    "$(t set_prime): ${pr} mm" \
            zhop     "$(t set_zhop): ${zh} mm" \
            travel   "$(t set_travel): ${tv} mm/s" \
            parkx    "$(t set_parkx): ${px}" \
            parky    "$(t set_party): ${py}" \
            probe    "$(t set_probe): ${up_lbl}" \
            back     "$(t back)")" || return 0
        case "${c}" in
            interval) local v; v="$(ui_input "$(t set_interval)" "$(t q_interval)" "${si}")" && [ -n "${v}" ] && set_rp save_interval "${v}";;
            purge)  edit_number "$(t l_purge)" purge 8;;
            prime)  edit_number "$(t l_prime)" prime 0;;
            zhop)   edit_number "$(t l_zhop)" z_hop 5;;
            travel) edit_number "$(t l_travel)" travel_speed 150;;
            parkx)  edit_number "$(t l_parkx)" park_x -1;;
            parky)  edit_number "$(t l_party)" park_y -1;;
            probe)
                if ui_yesno "$(t probe_title)" "$(t probe_q)"; then
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
        local ch c; ch="$(gd notify none)"
        c="$(ui_menu "$(t nt_title)" "$(t nt_channel): ${ch}" \
            telegram "$(t nt_telegram)" \
            ntfy     "$(t nt_ntfy)" \
            none     "$(t nt_none)" \
            test     "$(t nt_test)" \
            back     "$(t back)")" || return 0
        case "${c}" in
            telegram)
                local tok chat
                tok="$(ui_input "Telegram" "$(t tg_token)" "$(get_rp notify_telegram_token)")" || continue
                chat="$(ui_input "Telegram" "$(t tg_chat)" "$(get_rp notify_telegram_chat)")" || continue
                set_rp notify telegram
                set_rp notify_telegram_token "${tok}"
                set_rp notify_telegram_chat "${chat}";;
            ntfy)
                local topic url
                topic="$(ui_input "ntfy" "$(t ntfy_topic)" "$(get_rp notify_ntfy_topic)")" || continue
                url="$(ui_input "ntfy" "$(t ntfy_url)" "$(gd notify_ntfy_url https://ntfy.sh)")" || continue
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
    [ "${ch}" = none ] && { ui_msg "$(t test_title)" "$(t test_disabled)"; return; }
    command -v curl >/dev/null 2>&1 || { ui_msg "$(t test_title)" "$(t test_nocurl)"; return; }
    local ok=1
    if [ "${ch}" = telegram ]; then
        curl -fsS "https://api.telegram.org/bot$(get_rp notify_telegram_token)/sendMessage" \
            --data-urlencode "chat_id=$(get_rp notify_telegram_chat)" \
            --data-urlencode "text=repower: test notification" >/dev/null 2>&1 && ok=0
    elif [ "${ch}" = ntfy ]; then
        curl -fsS -d "repower: test notification" \
            "$(gd notify_ntfy_url https://ntfy.sh)/$(get_rp notify_ntfy_topic)" >/dev/null 2>&1 && ok=0
    fi
    [ "${ok}" = 0 ] && ui_msg "$(t test_title)" "$(t test_ok)" \
                    || ui_msg "$(t test_title)" "$(t test_fail)"
}

language_menu() {
    local cur c; cur="$(gd language en)"
    c="$(ui_menu "$(t lang_title)" "$(printf "$(t lang_q)" "${cur}")" \
        en "English" ru "Русский" back "$(t back)")" || return 0
    case "${c}" in
        en|ru) set_rp language "${c}"; UI_LANG="${c}";;
    esac
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

$(t st_pending): $( [ "${NEED_RESTART}" = 1 ] && t yes || t no )"
    ui_msg "$(t st_title)" "${txt}"
}

do_uninstall() {
    resolve_paths
    UI_LANG="$(gd language en)"
    ui_yesno "$(t un_title)" "$(t un_q)" || return 0
    [ -L "${EXTRAS_LINK}" ] && { rm -f "${EXTRAS_LINK}"; log "Removed module link"; }
    warn "Left ${PLUGIN}.cfg + [include]/[force_move]/[update_manager] entries."
    restart_service
    ui_msg "$(t un_title)" "$(t un_done)"
}

ensure_ui_language() {
    # Use the configured language for the panel; ask once if unset.
    UI_LANG="$(get_rp language)"
    if [ -z "${UI_LANG}" ]; then
        UI_LANG="$(ui_menu "Язык / Language" "Выберите язык / Choose a language" \
            en "English" ru "Русский")" || UI_LANG="en"
        [ -n "${UI_LANG}" ] || UI_LANG="en"
        set_rp language "${UI_LANG}"
    fi
}

main_menu() {
    ensure_ui_language
    while true; do
        local rflag=""; [ "${NEED_RESTART}" = 1 ] && rflag="$(t mm_pending)"
        local c
        c="$(ui_menu "$(t mm_title)${rflag}" "$(t mm_sub)" \
            settings  "$(t mm_settings)" \
            notify    "$(t mm_notify)" \
            language  "$(t mm_language)" \
            status    "$(t mm_status)" \
            apply     "$(t mm_apply)" \
            reinstall "$(t mm_reinstall)" \
            uninstall "$(t mm_uninstall)" \
            quit      "$(t mm_quit)")" || { maybe_restart; return 0; }
        case "${c}" in
            settings)  settings_menu;;
            notify)    notify_menu;;
            language)  language_menu;;
            status)    status_screen;;
            apply)     restart_service;;
            reinstall) core_install; ui_msg "$(t ri_title)" "$(t ri_done)";;
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
