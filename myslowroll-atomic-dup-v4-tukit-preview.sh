#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# mySlowrollOS atomic distribution upgrade v4 — tukit preview
#
# REVIEW FILE: this is a safe design prototype, not a replacement for the
# tested v3.4.9 script. Mutating commands are intentionally blocked until the
# complete v3.4.9 source is rebased here and the crash/recovery matrix has been
# tested in a VM.
#
# Goal:
#   SOURCE (live RW root) is never modified by zypper.
#   tukit creates an offline RW TARGET cloned from SOURCE.
#   zypper dup, RPM manifests and target checks run inside TARGET.
#   TARGET becomes default only after every check passes.
#
# Established design constraints:
#   - tukit close keeps TARGET RW when the current default is RW; verify this
#     before and after close instead of forcing the Btrfs property.
#   - /var/cache is shared by tukit, so the already validated package cache can
#     be reused, but visibility is checked before zypper starts.
#   - the ESP is external to the root snapshot: SOURCE and TARGET boot entries
#     must both be checked because aborting TARGET cannot roll back ESP writes.
#   - recover must never abort or delete an active TARGET.
#   - no package/system administration is allowed between TARGET cloning and
#     reboot, otherwise changes made later to SOURCE would be absent in TARGET.

readonly PROG="${0##*/}"
readonly PREVIEW_VERSION='4.0.0-tukit-preview'
readonly STATE_DIR=/var/lib/myslowroll/atomic-dup-v4-preview
readonly STATE_FILE="${STATE_DIR}/state"
readonly HISTORY_FILE="${STATE_DIR}/history.log"
readonly CACHE_ROOT=/var/cache/myslowroll-atomic-dup
readonly LOG_ROOT=/var/log/myslowroll-atomic-dup
readonly LOCK_FILE=/run/myslowroll-atomic-dup-v4-preview.lock
readonly SNAPPER_CONFIG=root
readonly REQUIRED_OS_ID=opensuse-slowroll

readonly -a VALID_STATES=(
    planning planned target-prepared target-updating target-verifying
    target-verified committing pending-reboot confirmed aborted
)

readonly -a CRITICAL_PKGS=(
    criscore1 criscore2 btrfsprogs kernel-default rpm
    sdbootutil sdbootutil-kernel-install sdbootutil-snapper
    snapper systemd systemd-boot transactional-update tukit zypper
)

STATE_STATUS=
STATE_TXID=
STATE_SOURCE=
STATE_TARGET=
STATE_BOOT_ID_BEFORE=
STATE_PLAN_HASH=
STATE_CACHE_HASH=
STATE_RPMDB_PRE_HASH=
STATE_RPMDB_POST_HASH=
STATE_CREATED_UTC=
STATE_UPDATED_UTC=
STATE_LAST_ERROR=

log()  { printf '[%s] %s\n' "${PROG}" "$*"; }
warn() { printf '[%s] ATTENZIONE: %s\n' "${PROG}" "$*" >&2; }
die()  { printf '[%s] ERRORE: %s\n' "${PROG}" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Uso: ${PROG} COMMAND

Comandi sicuri disponibili in questa preview:
  status          mostra lo stato preview
  check           verifica i prerequisiti senza creare snapshot
  design          mostra il flusso e la recovery previsti

Comandi intenzionalmente bloccati:
  plan upgrade recover confirm abort

La v3.4.9 collaudata resta il programma operativo. Questa preview serve per
revisionare il nuovo motore offline prima del collaudo distruttivo in VM.
EOF
}

require_root() {
    (( EUID == 0 )) || die 'eseguire come root.'
}

acquire_lock() {
    exec 9>"${LOCK_FILE}"
    flock -n 9 || die "un'altra istanza di ${PROG} e' gia' in esecuzione."
}

require_commands() {
    local cmd
    for cmd in awk btrfs cat findmnt flock grep rpm sha256sum snapper sort \
               sdbootutil sync systemctl transactional-update tukit zypper; do
        command -v "${cmd}" >/dev/null 2>&1 || die "comando richiesto non trovato: ${cmd}"
    done
}

state_value_valid() {
    local wanted="$1" item
    for item in "${VALID_STATES[@]}"; do
        [[ "${item}" == "${wanted}" ]] && return 0
    done
    return 1
}

load_state() {
    local key value
    [[ -f "${STATE_FILE}" ]] || return 0
    while IFS='=' read -r key value; do
        case "${key}" in
            status)          STATE_STATUS="${value}" ;;
            txid)            STATE_TXID="${value}" ;;
            source)          STATE_SOURCE="${value}" ;;
            target)          STATE_TARGET="${value}" ;;
            boot_id_before)  STATE_BOOT_ID_BEFORE="${value}" ;;
            plan_hash)       STATE_PLAN_HASH="${value}" ;;
            cache_hash)      STATE_CACHE_HASH="${value}" ;;
            rpmdb_pre_hash)  STATE_RPMDB_PRE_HASH="${value}" ;;
            rpmdb_post_hash) STATE_RPMDB_POST_HASH="${value}" ;;
            created_utc)     STATE_CREATED_UTC="${value}" ;;
            updated_utc)     STATE_UPDATED_UTC="${value}" ;;
            last_error)      STATE_LAST_ERROR="${value}" ;;
            ''|'#'*) ;;
            *) die "chiave state sconosciuta: ${key}" ;;
        esac
    done < "${STATE_FILE}"
    [[ -z "${STATE_STATUS}" ]] || state_value_valid "${STATE_STATUS}" ||
        die "stato non valido: ${STATE_STATUS}"
}

persist_state() {
    # Reference implementation for the final v4. The preview never calls it.
    local tmp
    install -d -o root -g root -m 0700 "${STATE_DIR}"
    tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
    {
        printf 'status=%s\n' "${STATE_STATUS}"
        printf 'txid=%s\n' "${STATE_TXID}"
        printf 'source=%s\n' "${STATE_SOURCE}"
        printf 'target=%s\n' "${STATE_TARGET}"
        printf 'boot_id_before=%s\n' "${STATE_BOOT_ID_BEFORE}"
        printf 'plan_hash=%s\n' "${STATE_PLAN_HASH}"
        printf 'cache_hash=%s\n' "${STATE_CACHE_HASH}"
        printf 'rpmdb_pre_hash=%s\n' "${STATE_RPMDB_PRE_HASH}"
        printf 'rpmdb_post_hash=%s\n' "${STATE_RPMDB_POST_HASH}"
        printf 'created_utc=%s\n' "${STATE_CREATED_UTC}"
        printf 'updated_utc=%s\n' "${STATE_UPDATED_UTC}"
        printf 'last_error=%s\n' "${STATE_LAST_ERROR//$'\n'/ }"
    } > "${tmp}"
    chmod 0600 "${tmp}"
    sync "${tmp}"
    mv -f -- "${tmp}" "${STATE_FILE}"
    sync "${STATE_DIR}"
}

snapshot_path() {
    local number="$1"
    [[ "${number}" =~ ^[0-9]+$ ]] || return 1
    printf '/.snapshots/%s/snapshot\n' "${number}"
}

active_snapshot() {
    local opts
    opts="$(findmnt -no OPTIONS /)"
    sed -nE 's#.*subvol=/?.*\.snapshots/([0-9]+)/snapshot.*#\1#p' <<<"${opts}"
}

default_snapshot() {
    local line
    line="$(btrfs subvolume get-default /)"
    sed -nE 's#.*path .*\.snapshots/([0-9]+)/snapshot.*#\1#p' <<<"${line}"
}

snapshot_exists() {
    [[ -d "$(snapshot_path "$1")" ]]
}

snapshot_is_rw() {
    local value
    value="$(btrfs property get "$(snapshot_path "$1")" ro 2>/dev/null || true)"
    [[ "${value}" == 'ro=false' ]]
}

snapshot_is_bootable() {
    sdbootutil is-bootable "$1" >/dev/null 2>&1
}

tukit_open_target() {
    # tukit open prints the transaction/snapshot identifier.
    local description="$1" target
    target="$(tukit --description "${description}" open)" || return 1
    target="$(grep -Eo '[0-9]+' <<<"${target}" | tail -n 1)"
    [[ "${target}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${target}"
}

tukit_call() {
    local target="$1"
    shift
    tukit call "${target}" "$@"
}

tukit_call_external() {
    local target="$1"
    shift
    tukit callext "${target}" "$@"
}

tukit_abort_target() {
    local target="$1" active
    active="$(active_snapshot)"
    [[ -n "${active}" ]] || die 'snapshot attiva non determinabile.'
    [[ "${target}" != "${active}" ]] || die "rifiuto di abortire TARGET ${target}: e' la root attiva."
    tukit abort "${target}"
}

target_cache_visible() {
    local target="$1" cache="$2"
    tukit_call "${target}" test -d "${cache}" &&
    tukit_call "${target}" test -r "${cache}"
}

write_target_manifest() {
    local target="$1" output="$2" tmp
    tmp="${output}.tmp"
    LC_ALL=C tukit_call "${target}" rpm -qa \
        --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}|%{ARCH}\n' |
        LC_ALL=C sort -u > "${tmp}"
    sync "${tmp}"
    mv -f -- "${tmp}" "${output}"
    sync "${output%/*}"
}

target_os_id() {
    local target="$1"
    tukit_call "${target}" awk -F= \
        '$1 == "ID" { gsub(/^"|"$/, "", $2); print $2; exit }' \
        /usr/lib/os-release
}

verify_target_packages() {
    local target="$1" pkg
    for pkg in "${CRITICAL_PKGS[@]}"; do
        tukit_call "${target}" rpm --quiet -q "${pkg}" || return 1
    done
}

verify_offline_target() {
    local target="$1" expected_manifest="$2" post_manifest="$3"
    snapshot_exists "${target}" || return 1
    snapshot_is_rw "${target}" || return 1
    write_target_manifest "${target}" "${post_manifest}" || return 1
    cmp -s -- "${expected_manifest}" "${post_manifest}" || return 1
    verify_target_packages "${target}" || return 1
    [[ "$(target_os_id "${target}")" == "${REQUIRED_OS_ID}" ]] || return 1
    snapshot_is_bootable "${STATE_SOURCE}" || return 1
    snapshot_is_bootable "${target}" || return 1
}

update_offline_target() {
    local target="$1" package_cache="$2" log_file="$3"
    target_cache_visible "${target}" "${package_cache}" ||
        die "cache ${package_cache} non visibile nella transazione tukit."

    # The final v4 reuses the exact v3.4.9 zypper arguments and fingerprints.
    # systemd-inhibit runs on the host; zypper runs only inside TARGET.
    systemd-inhibit \
        --what=shutdown:sleep:idle \
        --who="${PROG}" \
        --why='aggiornamento atomico offline del target Btrfs' \
        --mode=block \
        tukit call "${target}" \
            zypper --non-interactive --no-refresh \
            --pkg-cache-dir "${package_cache}" \
            dup --no-recommends --no-allow-vendor-change \
        2>&1 | tee "${log_file}"
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) || return "${rc}"
}

commit_verified_target() {
    local source="$1" target="$2"
    [[ "$(active_snapshot)" == "${source}" ]] ||
        die 'SOURCE non e piu la snapshot attiva: commit rifiutato.'
    [[ "$(default_snapshot)" == "${source}" ]] ||
        die 'SOURCE non e piu la snapshot predefinita: commit rifiutato.'
    snapshot_is_bootable "${source}" || die 'SOURCE non piu bootable: commit rifiutato.'
    snapshot_is_bootable "${target}" || die 'TARGET non bootable: commit rifiutato.'
    snapshot_is_rw "${target}" || die 'TARGET non RW prima del commit.'

    STATE_STATUS=committing
    STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
    persist_state

    tukit close "${target}" || return 1

    [[ "$(default_snapshot)" == "${target}" ]] || return 1
    snapshot_is_rw "${target}" || return 1
    snapshot_is_bootable "${source}" || return 1
    snapshot_is_bootable "${target}" || return 1

    STATE_STATUS=pending-reboot
    STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
    persist_state
}

recover_committing_reference() {
    # Decision table for a crash between durable 'committing' and
    # 'pending-reboot'. This function is reference code and is not dispatched.
    local active default target
    active="$(active_snapshot)"
    default="$(default_snapshot)"
    target="${STATE_TARGET}"

    if [[ "${active}" == "${target}" ]]; then
        # Never delete the running root. Validate and continue to confirmation.
        snapshot_is_rw "${target}" || die 'TARGET attiva ma read-only.'
        snapshot_is_bootable "${target}" || die 'TARGET attiva ma non bootable.'
        STATE_STATUS=pending-reboot
        persist_state
    elif [[ "${default}" == "${STATE_SOURCE}" ]]; then
        tukit_abort_target "${target}"
        STATE_STATUS=aborted
        persist_state
    elif [[ "${default}" == "${target}" ]]; then
        snapshot_is_rw "${target}" || die 'TARGET default ma read-only.'
        snapshot_is_bootable "${STATE_SOURCE}" || die 'SOURCE non bootable durante recovery.'
        snapshot_is_bootable "${target}" || die 'TARGET non bootable durante recovery.'
        STATE_STATUS=pending-reboot
        persist_state
    else
        die "recovery ambigua: active=${active:-?} default=${default:-?} target=${target:-?}."
    fi
}

show_status() {
    load_state
    printf 'Versione preview: %s\n' "${PREVIEW_VERSION}"
    printf 'Snapshot attiva: %s\n' "$(active_snapshot || true)"
    printf 'Snapshot default: %s\n' "$(default_snapshot || true)"
    printf 'Stato: %s\n' "${STATE_STATUS:-nessuna transazione preview}"
    printf 'TXID: %s\n' "${STATE_TXID:-nessuno}"
    printf 'SOURCE: %s\n' "${STATE_SOURCE:-nessuna}"
    printf 'TARGET: %s\n' "${STATE_TARGET:-nessuna}"
}

preflight_check() {
    require_root
    acquire_lock
    require_commands
    [[ "$(findmnt -no FSTYPE /)" == btrfs ]] || die 'root non Btrfs.'
    findmnt -no OPTIONS / | grep -qw rw || die 'root attiva non RW.'
    local active default
    active="$(active_snapshot)"
    default="$(default_snapshot)"
    [[ -n "${active}" && "${active}" == "${default}" ]] ||
        die "snapshot attiva/default non coincidono (${active:-?}/${default:-?})."
    snapshot_is_rw "${active}" || die "snapshot attiva ${active} non RW."
    snapshot_is_bootable "${active}" || die "snapshot attiva ${active} non bootable."
    log "Preflight preview superato: SOURCE ${active} RW e bootable; tukit disponibile."
}

show_design() {
    cat <<'EOF'
Flusso previsto:
  1. v3.4.9 plan A/B + pre-download + manifest atteso (invariati)
  2. persist target-prepared prima di ogni modifica al TARGET
  3. tukit open da SOURCE RW
  4. verifica TARGET RW e cache /var/cache visibile
  5. persist target-updating; zypper dup dentro tukit call
  6. persist target-verifying; manifest e controlli dentro TARGET
  7. verifica bootability di SOURCE e TARGET sulla ESP reale
  8. persist committing; tukit close TARGET
  9. verifica default=TARGET, TARGET RW, entrambe le entry bootable
 10. persist pending-reboot; reboot; conferma solo da TARGET

Recovery:
  target-prepared/updating/verifying/verified + default=SOURCE:
      abort TARGET, senza toccare SOURCE.
  committing + default=SOURCE:
      abort TARGET.
  committing + default=TARGET:
      verifica TARGET e continua pending-reboot.
  active=TARGET:
      non abortire e non cancellare mai TARGET.
  qualunque combinazione diversa:
      fail-closed, nessuna modifica automatica.

Rischio esterno residuo:
  la ESP non appartiene alla snapshot root. Per questo SOURCE e TARGET devono
  restare entrambi bootable durante l'intera transizione.
EOF
}

blocked_mutation() {
    die 'comando bloccato nella preview: integrare prima il sorgente completo v3.4.9 e collaudare in VM.'
}

main() {
    case "${1:-}" in
        status)  require_root; show_status ;;
        check)   preflight_check ;;
        design)  show_design ;;
        plan|upgrade|recover|confirm|abort) blocked_mutation ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
