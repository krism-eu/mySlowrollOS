#!/usr/bin/env bash
# ==============================================================================
# myslowroll-privacy v3.0.1 - Modalità Isolamento / Privacy on-demand
#                             per mySlowrollOS (openSUSE Slowroll, KDE Plasma)
#
# Uso (SOLO A COMANDO MANUALE, non parte all'avvio):
#   myslowroll-privacy toggle | on | off     (richiedono root: auto-elevazione pkexec)
#   myslowroll-privacy status                (senza root; exit 0 = ON, 3 = OFF)
#   myslowroll-privacy is-on                 (silenzioso, solo exit code)
#
# Architettura:
#   - Stato e backup SOLO in /run (tmpfs). Rete, firewall e mask del Bluetooth
#     sono runtime-only: un riavvio del PC ripristina lo stato base.
#   - Un'unità transitoria in RAM (systemd-run con After=systemd-rfkill.service)
#     garantisce che, anche se si riavvia il PC con la modalità Privacy attiva,
#     il blocco rfkill del Bluetooth venga rimosso allo spegnimento.
#   - Il microfono viene sempre mutato in ON; in OFF viene riattivato SOLO se
#     era attivo prima di accendere la Privacy (se era già muto, resta muto).
#   - Configurazione opzionale: /etc/myslowroll-privacy.conf (root:root, non
#     scrivibile da group/other).
# ==============================================================================

set -uo pipefail
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C.UTF-8

readonly SCRIPT_VERSION="3.0.1"
readonly TAG="myslowroll-privacy"
readonly STATE_DIR="/run/myslowroll-privacy"
readonly STATE_FILE="${STATE_DIR}/state"
readonly IFACES_FILE="${STATE_DIR}/ifaces"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly LOCK_FILE="/run/myslowroll-privacy.lock"
readonly CONFIG_FILE="/etc/myslowroll-privacy.conf"
readonly BT_RESTORE_UNIT="myslowroll-privacy-bt-restore"

# --- Default (sovrascrivibili da CONFIG_FILE) ---------------------------------
DNS4="9.9.9.9,149.112.112.112"            # Quad9 (utilizzato solo se DO_DNS="yes")
DNS6="2620:fe::fe,2620:fe::9"             # Quad9 IPv6 (evita leak DNS via RA)
STATIC_IP4=""                             # es. "192.168.11.50/24" (vuoto = non modifica IP)
STATIC_GW4=""                             # es. "192.168.11.1" (solo se STATIC_IP4 è valorizzato)
FIREWALL_ZONE="drop"
DO_MIC="yes"
DO_BLUETOOTH="yes"
DO_NETWORK="yes"
DO_DNS="no"                               # "no" = non tocca i DNS (preserva sempre 192.168.11.1)
DO_TRACES="yes"

FAILS=0

# ------------------------------------------------------------------------------
# Utilità
# ------------------------------------------------------------------------------
log() {
    local msg="$*"
    echo "[$(date '+%F %T')] ${msg}" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t "$TAG" -- "$msg" || true
    fi
}

fail() {
    log "ERRORE: $*"
    FAILS=$((FAILS + 1))
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local owner mode
    read -r owner mode < <(stat -c '%u %a' "$CONFIG_FILE")
    if [[ "$owner" != "0" ]] || (( 8#$mode & 8#022 )); then
        log "Config ${CONFIG_FILE} ignorata: deve essere di root e non scrivibile da group/other"
        return 0
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        local self
        self="$(readlink -f -- "$0")"
        exec pkexec "$self" "$@"
    fi
}

is_on() {
    [[ -f "$STATE_FILE" ]] && grep -qx 'on' "$STATE_FILE"
}

# Utente della sessione grafica: prima chi ha invocato pkexec/sudo, poi la
# sessione attiva su seat0 (esclude greeter SDDM e sessioni non attive).
get_session_user() {
    local uid="" sid props
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        uid="$PKEXEC_UID"
    elif [[ -n "${SUDO_UID:-}" ]]; then
        uid="$SUDO_UID"
    fi
    if [[ -n "$uid" && "$uid" != "0" ]]; then
        id -nu "$uid" 2>/dev/null && return 0
    fi

    while read -r sid _; do
        [[ -n "$sid" ]] || continue
        props="$(loginctl show-session "$sid" -p Name -p Active -p Class -p Seat 2>/dev/null)" || continue
        if grep -qx 'Active=yes' <<<"$props" \
            && grep -qx 'Class=user' <<<"$props" \
            && grep -qx 'Seat=seat0' <<<"$props"; then
            sed -n 's/^Name=//p' <<<"$props"
            return 0
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    return 1
}

# Esegue un comando nella sessione dell'utente (bus utente), senza dipendere da sudo.
as_user() {
    local user="$1"
    shift
    local uid home
    uid="$(id -u "$user" 2>/dev/null)" || return 1
    home="$(getent passwd "$user" | cut -d: -f6)"
    [[ -S "/run/user/${uid}/bus" ]] || return 1
    timeout 10 runuser -u "$user" -- env \
        HOME="$home" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        "$@"
}

notify() {
    local title="$1" text="$2" user
    user="$(get_session_user)" || return 0
    # Usa notify-send o D-Bus diretto (funziona sotto pkexec su KDE Wayland/X11)
    # e chiude il fd 9 per non trattenere il lock.
    {
        if command -v notify-send >/dev/null 2>&1 \
            && as_user "$user" notify-send -a "$TAG" "$title" "$text" >/dev/null 2>&1; then
            :
        elif command -v gdbus >/dev/null 2>&1; then
            as_user "$user" gdbus call --session \
                --dest org.freedesktop.Notifications \
                --object-path /org/freedesktop/Notifications \
                --method org.freedesktop.Notifications.Notify \
                "$TAG" 0 "security-high" "$title" "$text" "[]" "{}" 5000 >/dev/null 2>&1 || true
        elif command -v kdialog >/dev/null 2>&1; then
            as_user "$user" kdialog --title "$title" --passivepopup "$text" 6 >/dev/null 2>&1 || true
        fi
    } 9>&- &
    disown 2>/dev/null || true
    return 0
}

# ------------------------------------------------------------------------------
# Firewall (runtime)
# ------------------------------------------------------------------------------
fw_ready() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

fw_zone_of() {
    local z
    z="$(firewall-cmd --get-zone-of-interface="$1" 2>/dev/null)" || z=""
    if [[ "$z" == "no zone" ]]; then
        z=""
    fi
    printf '%s' "$z"
}

fw_zone_exists() {
    local zones
    zones="$(firewall-cmd --get-zones 2>/dev/null)" || return 1
    [[ " ${zones} " == *" $1 "* ]]
}

# ------------------------------------------------------------------------------
# Microfono (tutte le sorgenti non-monitor, con stato precedente per-sorgente)
# ------------------------------------------------------------------------------
mic_sources() {
    local user="$1" out
    out="$(as_user "$user" pactl list short sources 2>/dev/null)" || return 1
    awk '$2 !~ /\.monitor$/ {print $2}' <<<"$out"
}

mic_enable() {
    local user="$1" name out
    : > "${BACKUP_DIR}/mic_state"
    if command -v pactl >/dev/null 2>&1; then
        local count=0
        while read -r name; do
            [[ -n "$name" ]] || continue
            out="$(as_user "$user" pactl get-source-mute "$name" 2>/dev/null)"
            if [[ "$out" == *yes* ]]; then
                printf '%s\tyes\n' "$name" >> "${BACKUP_DIR}/mic_state"
            else
                printf '%s\tno\n' "$name" >> "${BACKUP_DIR}/mic_state"
            fi
            if as_user "$user" pactl set-source-mute "$name" 1 >/dev/null 2>&1; then
                count=$((count + 1))
            else
                log "ATTENZIONE: impossibile silenziare la sorgente $name"
            fi
        done < <(mic_sources "$user")
        log "Microfono: silenziate ${count} sorgenti"
    elif command -v wpctl >/dev/null 2>&1; then
        out="$(as_user "$user" wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)"
        if [[ "$out" == *MUTED* ]]; then
            printf '@DEFAULT_AUDIO_SOURCE@\tyes\n' >> "${BACKUP_DIR}/mic_state"
        else
            printf '@DEFAULT_AUDIO_SOURCE@\tno\n' >> "${BACKUP_DIR}/mic_state"
        fi
        as_user "$user" wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1 >/dev/null 2>&1 \
            && log "Microfono: sorgente predefinita silenziata (solo wpctl)" \
            || log "ATTENZIONE: wpctl set-mute fallito"
    else
        log "ATTENZIONE: né pactl né wpctl disponibili, microfono non gestito"
    fi
}

mic_disable() {
    local user="$1" name prev unmuted=0 kept_muted=0
    [[ -f "${BACKUP_DIR}/mic_state" ]] || return 0
    while IFS=$'\t' read -r name prev; do
        [[ -n "$name" ]] || continue
        if [[ "$prev" == "no" ]]; then
            if [[ "$name" == "@DEFAULT_AUDIO_SOURCE@" ]]; then
                as_user "$user" wpctl set-mute "$name" 0 >/dev/null 2>&1 \
                    && unmuted=$((unmuted + 1)) \
                    || log "ATTENZIONE: microfono non ripristinato (sorgente predefinita)"
            else
                as_user "$user" pactl set-source-mute "$name" 0 >/dev/null 2>&1 \
                    && unmuted=$((unmuted + 1)) \
                    || log "ATTENZIONE: microfono non ripristinato ($name)"
            fi
        else
            kept_muted=$((kept_muted + 1))
        fi
    done < "${BACKUP_DIR}/mic_state"

    if ((unmuted > 0)); then
        log "Microfono: riattivate ${unmuted} sorgenti (erano attive all'attivazione)"
    elif ((kept_muted > 0)); then
        log "Microfono: mantenuto muto (era già muto all'attivazione)"
    fi
}

# ------------------------------------------------------------------------------
# Bluetooth
# ------------------------------------------------------------------------------
bt_enable() {
    local out rf="none" rfkill_bin

    if systemctl is-active --quiet bluetooth.service; then
        echo "active" > "${BACKUP_DIR}/bt_service"
    else
        echo "inactive" > "${BACKUP_DIR}/bt_service"
    fi

    if rfkill_bin="$(command -v rfkill 2>/dev/null)"; then
        out="$("$rfkill_bin" -n -o SOFT list bluetooth 2>/dev/null)"
        if [[ -z "$out" ]]; then
            rf="none"
        elif grep -qx 'unblocked' <<<"$out"; then
            rf="unblocked"
        else
            rf="blocked"
        fi
    fi
    echo "$rf" > "${BACKUP_DIR}/bt_rfkill"

    # mask --runtime vive in /run: impedisce l'attivazione D-Bus (bluedevil) e sparisce al reboot
    if systemctl mask --runtime bluetooth.service >/dev/null 2>&1; then
        echo "yes" > "${BACKUP_DIR}/bt_masked"
    fi
    systemctl stop bluetooth.service >/dev/null 2>&1 || true

    if [[ "$rf" != "none" ]]; then
        "$rfkill_bin" block bluetooth >/dev/null 2>&1 || fail "rfkill block bluetooth"
        if [[ "$rf" == "unblocked" ]] && command -v systemd-run >/dev/null 2>&1; then
            systemctl stop "${BT_RESTORE_UNIT}.service" >/dev/null 2>&1 || true
            systemd-run --unit="$BT_RESTORE_UNIT" \
                --property=RemainAfterExit=yes \
                --property=After=systemd-rfkill.service \
                --property=ExecStop="${rfkill_bin} unblock bluetooth" \
                /bin/true >/dev/null 2>&1 || true
        fi
    fi

    if systemctl is-active --quiet bluetooth.service; then
        fail "bluetooth.service è ancora attivo"
    else
        log "Bluetooth: servizio fermo (mask runtime) e radio bloccata (rfkill: precedente=$rf)"
    fi
}

bt_disable() {
    systemctl stop "${BT_RESTORE_UNIT}.service" >/dev/null 2>&1 || true

    if [[ -f "${BACKUP_DIR}/bt_masked" ]]; then
        systemctl unmask --runtime bluetooth.service >/dev/null 2>&1 || fail "unmask bluetooth.service"
    fi
    if [[ "$(cat "${BACKUP_DIR}/bt_rfkill" 2>/dev/null)" == "unblocked" ]]; then
        rfkill unblock bluetooth >/dev/null 2>&1 || fail "rfkill unblock bluetooth"
        log "Bluetooth: sbloccato in rfkill (era attivo all'attivazione)"
    else
        log "Bluetooth: mantenuto bloccato in rfkill (era già bloccato all'attivazione)"
    fi
    if [[ "$(cat "${BACKUP_DIR}/bt_service" 2>/dev/null)" == "active" ]]; then
        systemctl start bluetooth.service >/dev/null 2>&1 || fail "start bluetooth.service"
        log "Bluetooth: servizio bluetooth.service riavviato"
    fi
}

# ------------------------------------------------------------------------------
# Rete + Firewall (tutte le interfacce fisiche connesse, solo runtime)
# ------------------------------------------------------------------------------
physical_ifaces() {
    nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
        | awk -F: '($2=="ethernet" || $2=="wifi") && $3=="connected" {print $1}'
}

net_enable() {
    local -a ifaces=() nm4=() nm6=()
    local iface zone fw="no"

    mapfile -t ifaces < <(physical_ifaces)
    if ((${#ifaces[@]} == 0)); then
        log "Rete: nessuna interfaccia fisica connessa, nulla da isolare"
        return 0
    fi

    if [[ "$DO_DNS" == "yes" || -n "$STATIC_IP4" ]]; then
        nm4=(ipv4.dhcp-send-hostname no)
        nm6=(ipv6.dhcp-send-hostname no)
        if [[ "$DO_DNS" == "yes" ]]; then
            nm4+=(ipv4.ignore-auto-dns yes ipv4.dns "$DNS4")
            nm6+=(ipv6.ignore-auto-dns yes ipv6.dns "$DNS6")
        fi
        if [[ -n "$STATIC_IP4" ]]; then
            nm4+=(ipv4.method manual ipv4.addresses "$STATIC_IP4")
            if [[ -n "$STATIC_GW4" ]]; then
                nm4+=(ipv4.gateway "$STATIC_GW4")
            fi
        fi
    fi

    if fw_ready; then
        if fw_zone_exists "$FIREWALL_ZONE"; then
            fw="yes"
        else
            log "ATTENZIONE: zona firewall '$FIREWALL_ZONE' inesistente, firewall non modificato"
        fi
    else
        log "ATTENZIONE: firewalld non attivo, firewall non modificato"
    fi

    : > "${BACKUP_DIR}/net_state"
    printf '%s\n' "${ifaces[@]}" > "$IFACES_FILE"
    chmod 0644 "$IFACES_FILE"

    for iface in "${ifaces[@]}"; do
        zone=""
        if [[ "$fw" == "yes" ]]; then
            zone="$(fw_zone_of "$iface")"
        fi
        printf '%s\t%s\n' "$iface" "$zone" >> "${BACKUP_DIR}/net_state"

        # Applica modifiche NetworkManager solo se espressamente richiesto (DNS o IP statico)
        if ((${#nm4[@]} > 0)); then
            if nmcli device modify "$iface" "${nm4[@]}" "${nm6[@]}" >/dev/null 2>&1; then
                log "Rete: $iface -> configurazione applicata (runtime)${STATIC_IP4:+, IP fisso $STATIC_IP4}"
            elif nmcli device modify "$iface" "${nm4[@]}" >/dev/null 2>&1; then
                log "Rete: $iface -> configurazione IPv4 applicata (IPv6 non modificabile su questo profilo)"
            else
                fail "nmcli device modify $iface"
            fi
        else
            log "Rete: $iface -> DNS e IP preservati invariati (DO_DNS=$DO_DNS)"
        fi

        if [[ "$fw" == "yes" ]]; then
            if firewall-cmd --zone="$FIREWALL_ZONE" --change-interface="$iface" >/dev/null 2>&1 \
                && [[ "$(fw_zone_of "$iface")" == "$FIREWALL_ZONE" ]]; then
                log "Firewall: $iface (zona precedente: ${zone:-nessuna}) -> $FIREWALL_ZONE"
            else
                fail "firewall: $iface non risulta nella zona $FIREWALL_ZONE"
            fi
        fi
    done
}

net_disable() {
    local iface zone st
    [[ -f "${BACKUP_DIR}/net_state" ]] || return 0

    while IFS=$'\t' read -r iface zone; do
        [[ -n "$iface" ]] || continue

        st="$(nmcli -g GENERAL.STATE device show "$iface" 2>/dev/null)"
        if [[ "$st" == 100* ]]; then
            if nmcli device reapply "$iface" >/dev/null 2>&1; then
                log "Rete: rieseguito device reapply su $iface (riletto profilo originale su disco)"
            else
                fail "nmcli device reapply $iface"
            fi
        else
            log "Rete: $iface non più connessa, nessun override da rimuovere"
        fi

        if fw_ready; then
            if [[ -n "$zone" ]]; then
                if firewall-cmd --zone="$zone" --change-interface="$iface" >/dev/null 2>&1 \
                    && [[ "$(fw_zone_of "$iface")" == "$zone" ]]; then
                    log "Firewall: $iface riportata nella zona $zone"
                else
                    fail "firewall: $iface non riportata nella zona $zone"
                fi
            elif [[ -n "$(fw_zone_of "$iface")" ]]; then
                firewall-cmd --remove-interface="$iface" >/dev/null 2>&1 || true
            fi
        fi
    done < "${BACKUP_DIR}/net_state"
}

# ------------------------------------------------------------------------------
# Tracce locali: eseguite COME UTENTE (mai rm come root su percorsi dell'utente)
# ------------------------------------------------------------------------------
traces_clean() {
    local user="$1" home
    home="$(getent passwd "$user" | cut -d: -f6)"

    as_user "$user" busctl --user call org.kde.klipper /klipper org.kde.klipper.klipper clearClipboardHistory >/dev/null 2>&1 \
        || log "ATTENZIONE: cronologia Klipper non svuotata (Klipper non in esecuzione?)"
    as_user "$user" busctl --user call org.kde.klipper /klipper org.kde.klipper.klipper clearClipboardContents >/dev/null 2>&1 || true
    as_user "$user" rm -f -- "${home}/.local/share/recently-used.xbel" >/dev/null 2>&1 || true
    if [[ -d "${home}/.cache/thumbnails" ]]; then
        as_user "$user" find "${home}/.cache/thumbnails" -mindepth 1 -delete >/dev/null 2>&1 || true
    fi
    log "Tracce: appunti Klipper, recenti GTK e miniature puliti (azione irreversibile)"
}

# ------------------------------------------------------------------------------
# ON / OFF
# ------------------------------------------------------------------------------
enable_privacy() {
    local user=""
    log "=== Attivazione Modalità Privacy v${SCRIPT_VERSION} ==="

    rm -rf -- "$STATE_DIR"
    install -d -m 0755 "$STATE_DIR"
    install -d -m 0700 "$BACKUP_DIR"
    echo "on" > "$STATE_FILE"

    user="$(get_session_user)" || user=""
    if [[ -n "$user" ]]; then
        echo "$user" > "${BACKUP_DIR}/user"
    else
        log "ATTENZIONE: nessuna sessione grafica rilevata, passi utente (microfono, tracce) saltati"
    fi

    if [[ "$DO_MIC" == "yes" && -n "$user" ]]; then mic_enable "$user"; fi
    if [[ "$DO_BLUETOOTH" == "yes" ]]; then bt_enable; fi
    if [[ "$DO_NETWORK" == "yes" ]]; then net_enable; fi
    if [[ "$DO_TRACES" == "yes" && -n "$user" ]]; then traces_clean "$user"; fi

    if ((FAILS > 0)); then
        notify "mySlowrollOS — Privacy PARZIALE" "Attivata con ${FAILS} errori: vedi journalctl -t ${TAG}"
        log "=== Modalità Privacy attivata CON ${FAILS} ERRORI ==="
        return 1
    fi
    local notif_msg="Mic muto, Bluetooth spento, firewall in zona ${FIREWALL_ZONE}, tracce pulite."
    if [[ "$DO_DNS" == "yes" ]]; then
        notif_msg="Mic muto, Bluetooth spento, DNS Quad9, firewall in zona ${FIREWALL_ZONE}, tracce pulite."
    fi
    notify "mySlowrollOS — Privacy ATTIVA" "$notif_msg"
    log "=== Modalità Privacy ATTIVATA con successo ==="
}

disable_privacy() {
    local user=""
    log "=== Disattivazione Modalità Privacy (Ripristino STATO BASE) ==="

    user="$(cat "${BACKUP_DIR}/user" 2>/dev/null)" || user=""
    if [[ -z "$user" ]]; then
        user="$(get_session_user)" || user=""
    fi

    if [[ -f "${BACKUP_DIR}/mic_state" ]]; then
        if [[ -n "$user" ]]; then
            mic_disable "$user"
        else
            log "ATTENZIONE: sessione utente assente, microfono NON ripristinato (verifica il mute a mano)"
        fi
    fi
    if [[ -f "${BACKUP_DIR}/bt_service" ]]; then bt_disable; fi
    net_disable

    if ((FAILS > 0)); then
        notify "mySlowrollOS — Ripristino INCOMPLETO" "${FAILS} errori: stato Privacy mantenuto, riprova 'off'."
        log "=== Ripristino INCOMPLETO (${FAILS} errori): stato conservato per un nuovo tentativo ==="
        return 1
    fi

    rm -rf -- "$STATE_DIR"
    notify "mySlowrollOS — Privacy DISATTIVATA" "Sistema ripristinato allo stato base."
    log "=== Modalità Privacy DISATTIVATA con successo ==="
}

# ------------------------------------------------------------------------------
# STATUS (senza root, non scatena popup Polkit di firewall-cmd)
# ------------------------------------------------------------------------------
show_status() {
    local iface name out zone_info
    if ! is_on; then
        echo "Stato Privacy: DISATTIVATA (stato base)"
        return 3
    fi
    echo "Stato Privacy: ATTIVA"
    if [[ -r "$IFACES_FILE" ]]; then
        while read -r iface; do
            [[ -n "$iface" ]] || continue
            zone_info="$FIREWALL_ZONE"
            if [[ $EUID -eq 0 ]] && fw_ready; then
                zone_info="$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || echo '?')"
            fi
            echo "  Rete $iface : zona ${zone_info}," \
                "DNS $(nmcli -g IP4.DNS,IP6.DNS device show "$iface" 2>/dev/null | tr '\n|' '  ')"
        done < "$IFACES_FILE"
    fi
    echo "  Bluetooth   : $(systemctl is-active bluetooth.service 2>&1), rfkill: $(rfkill -n -o SOFT list bluetooth 2>/dev/null | tr '\n' ' ')"
    if command -v pactl >/dev/null 2>&1 && out="$(pactl list short sources 2>/dev/null)"; then
        while read -r name; do
            [[ -n "$name" ]] || continue
            echo "  Mic $name : $(pactl get-source-mute "$name" 2>/dev/null)"
        done < <(awk '$2 !~ /\.monitor$/ {print $2}' <<<"$out")
    fi
    return 0
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
main() {
    local cmd="${1:-toggle}"

    case "$cmd" in
        status)
            show_status
            return $?
            ;;
        is-on)
            is_on
            return $?
            ;;
        on | off | toggle) ;;
        *)
            echo "Uso: $0 {toggle|on|off|status|is-on}" >&2
            return 2
            ;;
    esac

    require_root "$@"
    load_config

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Errore: un'operazione ${TAG} è già in corso." >&2
        return 1
    fi

    case "$cmd" in
        on)
            if is_on; then echo "Privacy già attiva."; else enable_privacy; fi
            ;;
        off)
            if is_on; then disable_privacy; else echo "Privacy già disattivata."; fi
            ;;
        toggle)
            if is_on; then disable_privacy; else enable_privacy; fi
            ;;
    esac
}

main "$@"
exit $?
