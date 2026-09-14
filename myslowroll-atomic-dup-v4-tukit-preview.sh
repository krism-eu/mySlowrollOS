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
readonly PREVIEW_VERSION='4.0.7-tukit-preview'
readonly STATE_DIR=/var/lib/myslowroll/atomic-dup-v4-preview
readonly STATE_FILE="${STATE_DIR}/state"
readonly HISTORY_FILE="${STATE_DIR}/history.log"
readonly CACHE_ROOT=/var/cache/myslowroll-atomic-dup-v4-preview
readonly LOG_ROOT=/var/log/myslowroll-atomic-dup-v4-preview
readonly LOCK_FILE=/run/myslowroll-atomic-dup-v4-preview.lock
readonly SNAPPER_CONFIG=root
readonly REQUIRED_OS_ID=opensuse-slowroll
readonly TARGET_MAX_AGE_SECONDS="${MYSLOWROLL_TARGET_MAX_AGE_SECONDS:-3600}"
readonly ESP_MIN_FREE_BYTES="${MYSLOWROLL_ESP_MIN_FREE_BYTES:-134217728}"
readonly AUTO_AGREE_LICENSES="${MYSLOWROLL_AUTO_AGREE_LICENSES:-0}"

readonly -a VALID_STATES=(
    planning planned target-opening target-open-ambiguous
    target-prepared target-updating target-verifying
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
STATE_SOURCE_OPEN_HASH=
STATE_CREATED_UTC=
STATE_TARGET_OPENED_UTC=
STATE_UPDATED_UTC=
STATE_LAST_ERROR=
declare -a ZYPPER_LICENSE_ARGS=()

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
  plan upgrade recover confirm abort prune

Variabili previste per la versione finale:
  MYSLOWROLL_TARGET_MAX_AGE_SECONDS  durata massima della finestra TARGET
                                     (default 3600 secondi).
  MYSLOWROLL_ESP_MIN_FREE_BYTES      spazio libero minimo sulla ESP
                                     (default 134217728 byte).
  MYSLOWROLL_AUTO_AGREE_LICENSES     1 accetta automaticamente le licenze;
                                     default 0, comportamento fail-closed.

La versione finale includera prune per cache e log v4. Questa preview usa un
namespace separato dalla v3, ma non elimina automaticamente alcun artefatto.

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
    for cmd in awk bootctl btrfs cat chmod cmp date df env findmnt flock grep \
               install mktemp mv readlink rm rpm sed sha256sum snapper sort \
               sdbootutil sync systemctl systemd-inhibit tee tr \
               transactional-update tukit wc zypper; do
        command -v "${cmd}" >/dev/null 2>&1 || die "comando richiesto non trovato: ${cmd}"
    done
}

is_uuid() {
    local value="${1:-}"
    [[ "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_sha256() {
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

is_utc_timestamp() {
    [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

validate_configuration() {
    [[ "${TARGET_MAX_AGE_SECONDS}" =~ ^[0-9]+$ ]] ||
        die 'MYSLOWROLL_TARGET_MAX_AGE_SECONDS deve essere un intero positivo.'
    (( 10#${TARGET_MAX_AGE_SECONDS} > 0 )) ||
        die 'MYSLOWROLL_TARGET_MAX_AGE_SECONDS deve essere maggiore di zero.'
    [[ "${ESP_MIN_FREE_BYTES}" =~ ^[0-9]+$ ]] ||
        die 'MYSLOWROLL_ESP_MIN_FREE_BYTES deve essere un intero positivo.'
    (( 10#${ESP_MIN_FREE_BYTES} > 0 )) ||
        die 'MYSLOWROLL_ESP_MIN_FREE_BYTES deve essere maggiore di zero.'
    configure_license_policy
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
    local -A seen=()
    [[ -f "${STATE_FILE}" ]] || return 0
    while IFS='=' read -r key value; do
        case "${key}" in
            status|txid|source|target|boot_id_before|plan_hash|cache_hash|rpmdb_pre_hash|rpmdb_post_hash|source_open_hash|created_utc|target_opened_utc|updated_utc|last_error)
                [[ -z "${seen[${key}]+x}" ]] || die "chiave state duplicata: ${key}"
                seen["${key}"]=1
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
                    source_open_hash) STATE_SOURCE_OPEN_HASH="${value}" ;;
                    created_utc)     STATE_CREATED_UTC="${value}" ;;
                    target_opened_utc) STATE_TARGET_OPENED_UTC="${value}" ;;
                    updated_utc)     STATE_UPDATED_UTC="${value}" ;;
                    last_error)      STATE_LAST_ERROR="${value}" ;;
                esac
                ;;
            ''|'#'*) ;;
            *) die "chiave state sconosciuta: ${key}" ;;
        esac
    done < "${STATE_FILE}"
    [[ -n "${STATE_STATUS}" ]] || die 'file state privo di status.'
    state_value_valid "${STATE_STATUS}" || die "stato non valido: ${STATE_STATUS}"
    is_uuid "${STATE_TXID}" || die 'txid non valido nello state.'
    [[ "${STATE_SOURCE}" =~ ^[0-9]+$ ]] || die 'SOURCE non valida nello state.'
    [[ -z "${STATE_TARGET}" || "${STATE_TARGET}" =~ ^[0-9]+$ ]] ||
        die 'TARGET non valida nello state.'
    [[ -z "${STATE_BOOT_ID_BEFORE}" ]] || is_uuid "${STATE_BOOT_ID_BEFORE}" ||
        die 'boot_id_before non valido nello state.'
    [[ -z "${STATE_PLAN_HASH}" ]] || is_sha256 "${STATE_PLAN_HASH}" ||
        die 'plan_hash non valido nello state.'
    [[ -z "${STATE_CACHE_HASH}" ]] || is_sha256 "${STATE_CACHE_HASH}" ||
        die 'cache_hash non valido nello state.'
    [[ -z "${STATE_RPMDB_PRE_HASH}" ]] || is_sha256 "${STATE_RPMDB_PRE_HASH}" ||
        die 'rpmdb_pre_hash non valido nello state.'
    [[ -z "${STATE_RPMDB_POST_HASH}" ]] || is_sha256 "${STATE_RPMDB_POST_HASH}" ||
        die 'rpmdb_post_hash non valido nello state.'
    [[ -z "${STATE_SOURCE_OPEN_HASH}" ]] || is_sha256 "${STATE_SOURCE_OPEN_HASH}" ||
        die 'source_open_hash non valido nello state.'
    [[ -z "${STATE_CREATED_UTC}" ]] || is_utc_timestamp "${STATE_CREATED_UTC}" ||
        die 'created_utc non valido nello state.'
    [[ -z "${STATE_TARGET_OPENED_UTC}" ]] || is_utc_timestamp "${STATE_TARGET_OPENED_UTC}" ||
        die 'target_opened_utc non valido nello state.'
    [[ -z "${STATE_UPDATED_UTC}" ]] || is_utc_timestamp "${STATE_UPDATED_UTC}" ||
        die 'updated_utc non valido nello state.'
}

persist_state() {
    # Reference implementation for the final v4. The preview never calls it.
    local tmp
    install -d -o root -g root -m 0700 "${STATE_DIR}" ||
        die 'impossibile preparare STATE_DIR per il marker anti-drift.'
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
        printf 'source_open_hash=%s\n' "${STATE_SOURCE_OPEN_HASH}"
        printf 'created_utc=%s\n' "${STATE_CREATED_UTC}"
        printf 'target_opened_utc=%s\n' "${STATE_TARGET_OPENED_UTC}"
        printf 'updated_utc=%s\n' "${STATE_UPDATED_UTC}"
        local safe_last_error="${STATE_LAST_ERROR//$'\n'/ }"
        safe_last_error="${safe_last_error//$'\r'/ }"
        safe_last_error="${safe_last_error//$'\t'/ }"
        printf 'last_error=%s\n' "${safe_last_error}"
    } > "${tmp}"
    chmod 0600 "${tmp}"
    sync "${tmp}"
    mv -f -- "${tmp}" "${STATE_FILE}"
    sync "${STATE_DIR}"
    sync -f "${STATE_FILE}"
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

available_bytes() {
    # GNU df rejects -P together with --output, so use -B1 only.
    LC_ALL=C df -B1 --output=avail -- "$1" 2>/dev/null |
        awk 'NR == 2 && $1 ~ /^[0-9]+$/ { print $1 }'
}

esp_path() {
    bootctl --print-esp-path 2>/dev/null
}

check_esp_space() {
    local esp available options
    esp="$(esp_path)" || return 1
    [[ -n "${esp}" && -d "${esp}" ]] || return 1
    options="$(findmnt -n -o OPTIONS --target "${esp}" 2>/dev/null || true)"
    tr ',' '\n' <<<"${options}" | grep -qx rw || {
        warn "ESP ${esp} non montata read-write."
        return 1
    }
    available="$(available_bytes "${esp}")" || return 1
    [[ "${available}" =~ ^[0-9]+$ ]] || return 1
    (( available >= ESP_MIN_FREE_BYTES )) || {
        warn "spazio ESP insufficiente: disponibile=${available}, minimo=${ESP_MIN_FREE_BYTES} byte"
        return 1
    }
}

nearest_existing_storage_path() {
    local path="$1"
    [[ "${path}" == /* ]] || return 1
    while [[ ! -e "${path}" ]]; do
        [[ ! -L "${path}" ]] || return 1
        [[ "${path}" != / ]] || return 1
        path="${path%/*}"
        [[ -n "${path}" ]] || path=/
    done
    readlink -f -- "${path}"
}

path_is_outside_root_snapshot() {
    local wanted="$1" path root_dev path_dev root_fs path_fs root_id path_id
    path="$(nearest_existing_storage_path "${wanted}")" || return 1
    root_dev="$(findmnt -n -o MAJ:MIN --target / 2>/dev/null || true)"
    path_dev="$(findmnt -n -o MAJ:MIN --target "${path}" 2>/dev/null || true)"
    root_fs="$(findmnt -n -o FSTYPE --target / 2>/dev/null || true)"
    path_fs="$(findmnt -n -o FSTYPE --target "${path}" 2>/dev/null || true)"
    [[ -n "${root_dev}" && -n "${path_dev}" ]] || return 1
    [[ "${root_dev}" != "${path_dev}" ]] && return 0
    [[ "${root_fs}" == btrfs && "${path_fs}" == btrfs ]] || return 1
    root_id="$(btrfs inspect-internal rootid / 2>/dev/null || true)"
    path_id="$(btrfs inspect-internal rootid "${path}" 2>/dev/null || true)"
    [[ "${root_id}" =~ ^[0-9]+$ && "${path_id}" =~ ^[0-9]+$ ]] || return 1
    [[ "${root_id}" != "${path_id}" ]]
}

rpmdb_is_in_root_snapshot() {
    local db_path root_dev db_dev root_id db_id
    db_path="$(rpm --eval '%{_dbpath}' 2>/dev/null || true)"
    [[ "${db_path}" == /* ]] || return 1
    db_path="$(readlink -f -- "${db_path}" 2>/dev/null || true)"
    [[ -n "${db_path}" && -d "${db_path}" ]] || return 1
    root_dev="$(findmnt -n -o MAJ:MIN --target / 2>/dev/null || true)"
    db_dev="$(findmnt -n -o MAJ:MIN --target "${db_path}" 2>/dev/null || true)"
    [[ -n "${root_dev}" && "${root_dev}" == "${db_dev}" ]] || return 1
    root_id="$(btrfs inspect-internal rootid / 2>/dev/null || true)"
    db_id="$(btrfs inspect-internal rootid "${db_path}" 2>/dev/null || true)"
    [[ "${root_id}" =~ ^[0-9]+$ && "${root_id}" == "${db_id}" ]]
}

check_zypp_lock_hint() {
    local pid lock_file
    for lock_file in /run/zypp.pid /run/zypp-rpm.pid; do
        [[ -r "${lock_file}" ]] || continue
        pid=
        read -r pid < "${lock_file}" || true
        if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            die "ZYpp risulta gia in uso dal PID ${pid} (${lock_file}); chiudere YaST/Zypper e riprovare."
        fi
    done
}

source_rpmdb_hash() {
    local tmp hash
    tmp="$(mktemp /run/myslowroll-source-rpmdb.XXXXXX)" || return 1
    if ! LC_ALL=C rpm -qa \
        --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}|%{ARCH}\n' |
        LC_ALL=C sort -u >"${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    # Do not accept the valid SHA-256 of an empty stream as a healthy RPMDB.
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    hash="$(sha256sum "${tmp}" | awk '{ print $1 }')" || {
        rm -f -- "${tmp}"
        return 1
    }
    rm -f -- "${tmp}"
    [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${hash}"
}

start_source_drift_guard() {
    # Called immediately before tukit open. Starting before the clone closes
    # the small observation gap that would otherwise exist while parsing open.
    local marker
    marker="$(source_etc_marker)" || die 'percorso marker anti-drift non valido.'
    install -d -o root -g root -m 0700 "${STATE_DIR}"
    printf 'txid=%s\nopened_utc=%s\n' "${STATE_TXID}" "$(date -u +%FT%TZ)" >"${marker}" ||
        die 'impossibile creare il marker anti-drift di /etc.'
    chmod 0600 "${marker}" || {
        rm -f -- "${marker}"
        die 'impossibile proteggere il marker anti-drift di /etc.'
    }
    sync "${marker}" || die 'impossibile rendere durevole il marker anti-drift di /etc.'

    STATE_SOURCE_OPEN_HASH="$(source_rpmdb_hash)" ||
        die 'impossibile acquisire il fingerprint RPM della SOURCE.'
    [[ "${STATE_SOURCE_OPEN_HASH}" =~ ^[0-9a-f]{64}$ ]] ||
        die 'fingerprint RPM SOURCE non valido.'
    persist_state || die 'impossibile rendere durevole il fingerprint della SOURCE.'
}

source_etc_marker() {
    is_uuid "${STATE_TXID}" || return 1
    printf '%s/%s.source-etc-open.marker\n' "${STATE_DIR}" "${STATE_TXID}"
}

source_etc_drift_report() {
    local marker path tmp
    marker="$(source_etc_marker)" || return 1
    [[ -f "${marker}" ]] || return 1
    tmp="$(mktemp /run/myslowroll-etc-drift.XXXXXX)" || return 1
    if ! find /etc -xdev -type f -newer "${marker}" -print0 >"${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    while IFS= read -r -d '' path; do
        case "${path}" in
            /etc/resolv.conf|/etc/mtab|/etc/adjtime) continue ;;
        esac
        printf '%s\n' "${path}"
    done <"${tmp}"
    rm -f -- "${tmp}"
}

assert_source_unchanged() {
    local current etc_drift
    [[ "${STATE_SOURCE_OPEN_HASH}" =~ ^[0-9a-f]{64}$ ]] ||
        die 'fingerprint SOURCE all apertura assente o non valido.'
    current="$(source_rpmdb_hash)" || die 'fingerprint RPM SOURCE corrente non calcolabile.'
    [[ "${current}" == "${STATE_SOURCE_OPEN_HASH}" ]] ||
        die 'RPMDB della SOURCE cambiata dopo tukit open: chiudere YaST/Zypper, abortire la TARGET e creare un nuovo piano.'
    etc_drift="$(source_etc_drift_report)" ||
        die 'marker anti-drift di /etc assente o non verificabile: commit rifiutato.'
    [[ -z "${etc_drift}" ]] ||
        die "file della SOURCE modificati in /etc dopo tukit open: ${etc_drift//$'\n'/, }; abortire la TARGET e creare un nuovo piano."
}

check_transactional_update_idle() {
    if systemctl is-failed --quiet transactional-update.service 2>/dev/null; then
        die 'transactional-update.service e in stato failed: esaminare systemctl status e journalctl prima di continuare.'
    fi
    if systemctl is-active --quiet transactional-update.service 2>/dev/null; then
        die 'transactional-update.service e attivo: attendere che termini.'
    fi
    if systemctl is-enabled --quiet transactional-update.timer 2>/dev/null; then
        die 'transactional-update.timer deve essere disabilitato: eseguire systemctl disable --now transactional-update.timer.'
    fi
}

ensure_snapshot_bootable() {
    # add-all-kernels runs on the host because the BLS entries and kernel
    # payload live on the real ESP, outside the root snapshot.
    local snapshot="$1" log_file="${2:-${LOG_ROOT}/sdboot-${snapshot}.log}"
    snapshot_is_bootable "${snapshot}" && return 0
    check_esp_space || return 1
    install -d -o root -g root -m 0700 "${log_file%/*}"
    (
        printf 'snapshot=%s action=sdbootutil-add-all-kernels\n' "${snapshot}"
        if sdbootutil add-all-kernels "${snapshot}"; then
            rc=0
        else
            rc=$?
        fi
        printf 'add-all-kernels_rc=%s\n' "${rc}"
        (( rc == 0 )) || exit "${rc}"
        sdbootutil is-bootable "${snapshot}"
    ) >"${log_file}" 2>&1 || return 1
    sync "${log_file}"
    snapshot_is_bootable "${snapshot}"
}

configure_license_policy() {
    case "${AUTO_AGREE_LICENSES}" in
        0|no|false|off) ZYPPER_LICENSE_ARGS=() ;;
        1|yes|true|on)  ZYPPER_LICENSE_ARGS=(--auto-agree-with-licenses) ;;
        *) die 'MYSLOWROLL_AUTO_AGREE_LICENSES deve essere un valore booleano.' ;;
    esac
}

verify_tukit_cli_surface() {
    local help version
    version="$(tukit --version 2>&1)" || return 1
    help="$(tukit --help 2>&1)" || return 1
    local subcommand
    for subcommand in open call callext close abort; do
        grep -Eq "(^|[[:space:]])${subcommand}([[:space:]]|$)" <<<"${help}" || return 1
    done
    log "CLI tukit rilevata: ${version//$'\n'/ }"
    # The VM matrix must additionally record the effective tukit.conf, Snapper
    # configuration and observed open/close semantics for the installed build.
}

parse_tukit_open_output() {
    # Fail closed: until the local CLI is characterized, accept only one line
    # containing only the snapshot number. The raw output is retained for the
    # VM test and the adapter can then be specialized to that exact version.
    local raw_file="$1" candidate count
    candidate="$(awk '
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        /^[0-9]+$/ { print }
    ' "${raw_file}")"
    count="$(wc -l <<<"${candidate}")"
    [[ "${count}" == 1 && "${candidate}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${candidate}"
}

tukit_open_target() {
    local description="$1" raw_file="$2" target
    install -d -o root -g root -m 0700 "${raw_file%/*}"
    STATE_STATUS=target-opening
    STATE_TARGET=
    STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
    STATE_LAST_ERROR=
    persist_state || return 1
    start_source_drift_guard

    if ! tukit --description "${description}" open >"${raw_file}" 2>&1; then
        sync "${raw_file}" || true
        STATE_STATUS=target-open-ambiguous
        STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
        STATE_LAST_ERROR="tukit open fallito o ambiguo; cercare la TARGET tramite descrizione/txid; output=${raw_file}"
        persist_state || true
        warn "tukit open non concluso in modo verificabile; non riprovare automaticamente. Output: ${raw_file}"
        return 1
    fi
    sync "${raw_file}"
    if ! target="$(parse_tukit_open_output "${raw_file}")"; then
        STATE_STATUS=target-open-ambiguous
        STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
        STATE_LAST_ERROR="tukit open riuscito ma numero TARGET non riconosciuto; cercare per txid; output=${raw_file}"
        persist_state || true
        warn "TARGET forse creata ma numero non riconosciuto; non riprovare. Output: ${raw_file}"
        return 1
    fi
    STATE_TARGET="${target}"
    STATE_STATUS=target-prepared
    STATE_TARGET_OPENED_UTC="$(date -u +%FT%TZ)"
    STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
    persist_state || return 1
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
    local target="$1" active default
    active="$(active_snapshot)"
    default="$(default_snapshot)"
    [[ -n "${active}" ]] || die 'snapshot attiva non determinabile.'
    [[ "${target}" != "${active}" ]] || die "rifiuto di abortire TARGET ${target}: e' la root attiva."
    [[ "${target}" != "${default}" ]] || die "rifiuto di abortire TARGET ${target}: e' la snapshot default."
    remove_target_boot_entries "${target}" ||
        warn "pulizia preventiva delle entry BLS TARGET ${target} incompleta; proseguo con abort Snapper."
    tukit abort "${target}"
}

remove_target_boot_entries() {
    local target="$1" log_file="${LOG_ROOT}/${STATE_TXID:-unknown}.target-${target}.sdboot-remove.log"
    [[ "${target}" =~ ^[0-9]+$ ]] || return 1
    [[ "$(active_snapshot)" != "${target}" ]] || return 1
    [[ "$(default_snapshot)" != "${target}" ]] || return 1
    install -d -o root -g root -m 0700 "${LOG_ROOT}"
    (
        rc=0
        if sdbootutil remove-all-kernels --disable-predictions "${target}"; then
            printf 'remove-all-kernels_rc=0\n'
        else
            cmd_rc=$?
            printf 'remove-all-kernels_rc=%s\n' "${cmd_rc}"
            rc="${cmd_rc}"
        fi
        if sdbootutil cleanup --disable-predictions "${target}"; then
            printf 'cleanup_rc=0\n'
        else
            cmd_rc=$?
            printf 'cleanup_rc=%s\n' "${cmd_rc}"
            (( rc != 0 )) || rc="${cmd_rc}"
        fi
        exit "${rc}"
    ) >"${log_file}" 2>&1
    local rc=$?
    sync "${log_file}" || true
    return "${rc}"
}

target_cache_visible() {
    local target="$1" cache="$2" marker token rc=0
    [[ "${target}" =~ ^[0-9]+$ && "${cache}" == "${CACHE_ROOT}/"* ]] || return 1
    [[ -d "${cache}" && -r "${cache}" && -w "${cache}" ]] || return 1
    token="${STATE_TXID}:$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    is_uuid "${token#*:}" || return 1
    marker="${cache}/.target-visibility-${STATE_TXID}"
    printf '%s\n' "${token}" >"${marker}" || return 1
    chmod 0600 "${marker}" || { rm -f -- "${marker}"; return 1; }
    sync "${marker}" || { rm -f -- "${marker}"; return 1; }
    tukit_call "${target}" sh -c \
        'test -r "$1" && test -w "${1%/*}" && IFS= read -r value <"$1" && test "$value" = "$2"' \
        sh "${marker}" "${token}" || rc=$?
    rm -f -- "${marker}" || return 1
    return "${rc}"
}

write_target_manifest() {
    local target="$1" output="$2" tmp
    tmp="${output}.tmp"
    rm -f -- "${tmp}"
    if ! LC_ALL=C tukit_call "${target}" rpm -qa \
        --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}|%{ARCH}\n' |
        LC_ALL=C sort -u >"${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    sync "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${output}" || { rm -f -- "${tmp}"; return 1; }
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
    local sdboot_log="${4:-${LOG_ROOT}/${STATE_TXID:-unknown}.target-${target}.sdboot.log}"
    assert_source_unchanged
    snapshot_exists "${target}" || return 1
    snapshot_is_rw "${target}" || return 1
    write_target_manifest "${target}" "${post_manifest}" || return 1
    cmp -s -- "${expected_manifest}" "${post_manifest}" || return 1
    verify_target_packages "${target}" || return 1
    [[ "$(target_os_id "${target}")" == "${REQUIRED_OS_ID}" ]] || return 1
    snapshot_is_bootable "${STATE_SOURCE}" || return 1
    ensure_snapshot_bootable "${target}" "${sdboot_log}" || return 1
}

target_age_seconds() {
    local opened_epoch now_epoch
    [[ -n "${STATE_TARGET_OPENED_UTC}" ]] || return 1
    opened_epoch="$(date -u -d "${STATE_TARGET_OPENED_UTC}" +%s 2>/dev/null)" || return 1
    now_epoch="$(date -u +%s)"
    (( now_epoch >= opened_epoch )) || return 1
    printf '%s\n' "$(( now_epoch - opened_epoch ))"
}

assert_target_window() {
    local age
    age="$(target_age_seconds)" || die 'eta della TARGET non determinabile.'
    (( age <= TARGET_MAX_AGE_SECONDS )) ||
        die "TARGET aperta da ${age}s: supera il limite ${TARGET_MAX_AGE_SECONDS}s; abortire senza commit."
}

update_offline_target() {
    local target="$1" package_cache="$2" log_file="$3" had_errexit=0
    local -a pipeline_rc
    assert_source_unchanged
    target_cache_visible "${target}" "${package_cache}" ||
        die "cache ${package_cache} non visibile nella transazione tukit."

    configure_license_policy
    assert_target_window
    check_zypp_lock_hint
    check_transactional_update_idle
    # systemd-inhibit runs on the host; env and zypper run only inside TARGET.
    # /var is shared by tukit: zypp history/cookies can therefore remain visible
    # on SOURCE even if TARGET is later aborted. RPMDB and /usr stay in TARGET.
    [[ $- == *e* ]] && had_errexit=1
    set +e
    systemd-inhibit \
        --what=shutdown:sleep:idle \
        --who="${PROG}" \
        --why='aggiornamento atomico offline del target Btrfs' \
        --mode=block \
        tukit call "${target}" \
            env DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C \
            zypper --non-interactive --no-refresh \
            --pkg-cache-dir "${package_cache}" \
            --userdata "myslowroll-v4:${STATE_TXID}" dup \
            "${ZYPPER_LICENSE_ARGS[@]}" \
            --download-in-advance --no-recommends --no-allow-vendor-change \
        2>&1 | tee "${log_file}"
    pipeline_rc=("${PIPESTATUS[@]}")
    (( had_errexit == 0 )) || set -e
    sync "${log_file}" || warn "impossibile sincronizzare il log ${log_file}."
    (( pipeline_rc[1] == 0 )) || warn "tee del dup ha restituito rc=${pipeline_rc[1]}."
    return "${pipeline_rc[0]}"
}

commit_verified_target() {
    local source="$1" target="$2"
    [[ "$(active_snapshot)" == "${source}" ]] ||
        die 'SOURCE non e piu la snapshot attiva: commit rifiutato.'
    [[ "$(default_snapshot)" == "${source}" ]] ||
        die 'SOURCE non e piu la snapshot predefinita: commit rifiutato.'
    assert_source_unchanged
    snapshot_is_bootable "${source}" || die 'SOURCE non piu bootable: commit rifiutato.'
    ensure_snapshot_bootable "${target}" \
        "${LOG_ROOT}/${STATE_TXID:-unknown}.target-${target}.sdboot.log" ||
        die 'impossibile creare/verificare la entry di boot TARGET.'
    snapshot_is_rw "${target}" || die 'TARGET non RW prima del commit.'
    assert_target_window

    STATE_STATUS=committing
    STATE_UPDATED_UTC="$(date -u +%FT%TZ)"
    persist_state

    # Flush TARGET, manifest, log and durable state before changing the default
    # Btrfs subvolume. A close is never attempted after a failed sync barrier.
    sync || return 1
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
        [[ "${default}" == "${target}" ]] ||
            die "TARGET ${target} attiva ma default=${default:-?}: recovery automatica rifiutata."
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
    validate_configuration
    [[ "$(findmnt -no FSTYPE /)" == btrfs ]] || die 'root non Btrfs.'
    findmnt -no OPTIONS / | tr ',' '\n' | grep -qx rw || die 'root attiva non RW.'
    verify_tukit_cli_surface || die 'CLI tukit incompatibile o non caratterizzata.'
    snapper -c "${SNAPPER_CONFIG}" get-config >/dev/null 2>&1 ||
        die "configurazione Snapper ${SNAPPER_CONFIG} non disponibile."
    # /var itself is deliberately required to be external. The three durable
    # paths would technically suffice, but an internal /var would change the
    # documented tukit/ZYpp side-effect model. This workstation policy is
    # intentionally stricter and fails closed.
    path_is_outside_root_snapshot /var ||
        die '/var non e dimostrabilmente fuori dalla snapshot root.'
    path_is_outside_root_snapshot "${STATE_DIR}" ||
        die "STATE_DIR (${STATE_DIR}) non e fuori dalla snapshot root."
    path_is_outside_root_snapshot "${CACHE_ROOT}" ||
        die "CACHE_ROOT (${CACHE_ROOT}) non e fuori dalla snapshot root."
    path_is_outside_root_snapshot "${LOG_ROOT}" ||
        die "LOG_ROOT (${LOG_ROOT}) non e fuori dalla snapshot root."
    rpmdb_is_in_root_snapshot ||
        die 'RPMDB non e dimostrabilmente inclusa nella snapshot root.'
    check_transactional_update_idle
    check_zypp_lock_hint
    check_esp_space || die 'spazio ESP insufficiente o non determinabile.'
    local active default
    active="$(active_snapshot)"
    default="$(default_snapshot)"
    [[ "${active}" =~ ^[0-9]+$ ]] ||
        die 'la root attiva non e una snapshot numerata /.snapshots/N/snapshot: v4 richiede modalita snapshot-root RW (per esempio dopo snapper rollback), non subvol=/@.'
    [[ "${active}" == "${default}" ]] ||
        die "snapshot attiva/default non coincidono (${active:-?}/${default:-?})."
    snapshot_is_rw "${active}" || die "snapshot attiva ${active} non RW."
    snapshot_is_bootable "${active}" || die "snapshot attiva ${active} non bootable."
    log "Preflight preview superato: SOURCE ${active} RW e bootable; tukit disponibile."
}

show_design() {
    cat <<'EOF'
Flusso previsto:
  1. v3.4.9 plan A/B + pre-download + manifest atteso (invariati); se il
     piano e vuoto, chiudere confirmed senza aprire alcuna TARGET
  2. persist target-prepared prima di ogni modifica al TARGET
  3. tukit open da SOURCE RW
  4. verifica TARGET RW e cache /var/cache visibile
  5. persist target-updating; zypper dup dentro tukit call
  6. persist target-verifying; manifest e controlli dentro TARGET
  7. se necessario: sdbootutil add-all-kernels TARGET dall'host
  8. verifica bootability di SOURCE e TARGET sulla ESP reale
  9. persist committing; tukit close TARGET
 10. verifica default=TARGET, TARGET RW, entrambe le entry bootable
 11. persist pending-reboot; reboot; conferma solo da TARGET

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

Finestra di drift:
  il piano e il download precedono tukit open. Dal clone al commit non fare
  modifiche amministrative a /etc o /var; il commit viene rifiutato oltre il
  limite configurato (default 3600 secondi). Il fingerprint RPM della SOURCE
  viene salvato a open e confrontato prima del close. Un marker durevole rileva
  inoltre modifiche successive ai file regolari di /etc sulla SOURCE, eccetto
  resolv.conf, mtab e adjtime. La history/cookie ZYpp in /var puo registrare il
  tentativo anche quando TARGET viene abortita.

Matrice VM obbligatoria:
  - registrare versione tukit, tukit.conf e config Snapper effettiva;
  - caratterizzare esattamente output di open e semantica di close;
  - verificare visibilita della cache e del lock ZYpp con /run privato/condiviso;
  - inventariare tutti i mount /var e classificare ogni effetto persistente;
  - dup senza aggiornamento kernel: TARGET riceve comunque una entry BLS;
  - kill durante gli scriptlet kernel e inventario delle modifiche ESP;
  - piano senza operazioni: nessuna TARGET viene aperta;
  - kill durante tukit call;
  - poweroff durante close;
  - reboot spontaneo in ogni stato target-* e committing.
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
        plan|upgrade|recover|confirm|abort|prune) blocked_mutation ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
