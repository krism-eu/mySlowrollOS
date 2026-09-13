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
readonly PREVIEW_VERSION='4.0.5-tukit-preview'
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
            source_open_hash) STATE_SOURCE_OPEN_HASH="${value}" ;;
            created_utc)     STATE_CREATED_UTC="${value}" ;;
            target_opened_utc) STATE_TARGET_OPENED_UTC="${value}" ;;
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
        printf 'source_open_hash=%s\n' "${STATE_SOURCE_OPEN_HASH}"
        printf 'created_utc=%s\n' "${STATE_CREATED_UTC}"
        printf 'target_opened_utc=%s\n' "${STATE_TARGET_OPENED_UTC}"
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

state_is_outside_root_snapshot() {
    # /var itself is deliberately required to be external. The three durable
    # paths would technically be sufficient, but accepting an internal /var
    # would change the documented tukit/ZYpp side-effect model. This stricter
    # workstation policy therefore fails closed even with separately mounted
    # STATE_DIR, CACHE_ROOT and LOG_ROOT.
    path_is_outside_root_snapshot /var &&
    path_is_outside_root_snapshot "${STATE_DIR}" &&
    path_is_outside_root_snapshot "${CACHE_ROOT}" &&
    path_is_outside_root_snapshot "${LOG_ROOT}"
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

record_source_hash_at_target_open() {
    # Called immediately after tukit open in the final orchestrator.
    STATE_SOURCE_OPEN_HASH="$(source_rpmdb_hash)" ||
        die 'impossibile acquisire il fingerprint RPM della SOURCE.'
    [[ "${STATE_SOURCE_OPEN_HASH}" =~ ^[0-9a-f]{64}$ ]] ||
        die 'fingerprint RPM SOURCE non valido.'
    STATE_TARGET_OPENED_UTC="$(date -u +%FT%TZ)"
    persist_state
}

assert_source_unchanged() {
    local current
    [[ "${STATE_SOURCE_OPEN_HASH}" =~ ^[0-9a-f]{64}$ ]] ||
        die 'fingerprint SOURCE all apertura assente o non valido.'
    current="$(source_rpmdb_hash)" || die 'fingerprint RPM SOURCE corrente non calcolabile.'
    [[ "${current}" == "${STATE_SOURCE_OPEN_HASH}" ]] ||
        die 'RPMDB della SOURCE cambiata dopo tukit open: chiudere YaST/Zypper, abortire la TARGET e creare un nuovo piano.'
}

check_transactional_update_idle() {
    if systemctl is-enabled --quiet transactional-update.timer 2>/dev/null; then
        die 'transactional-update.timer deve essere disabilitato: eseguire systemctl disable --now transactional-update.timer.'
    fi
    if systemctl is-active --quiet transactional-update.service 2>/dev/null; then
        die 'transactional-update.service e attivo: attendere che termini.'
    fi
    if systemctl is-failed --quiet transactional-update.service 2>/dev/null; then
        die 'transactional-update.service e in stato failed: esaminare systemctl status e journalctl prima di continuare.'
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
    tukit --description "${description}" open >"${raw_file}" 2>&1 || return 1
    sync "${raw_file}"
    target="$(parse_tukit_open_output "${raw_file}")" || return 1
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
    tukit_call "${target}" sh -c \
        'test -d "$1" && test -r "$1" && test -w "$1"' sh "${cache}"
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
    local target="$1" package_cache="$2" log_file="$3"
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
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) || return "${rc}"
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
    findmnt -no OPTIONS / | tr ',' '\n' | grep -qx rw || die 'root attiva non RW.'
    verify_tukit_cli_surface || die 'CLI tukit incompatibile o non caratterizzata.'
    snapper -c "${SNAPPER_CONFIG}" get-config >/dev/null 2>&1 ||
        die "configurazione Snapper ${SNAPPER_CONFIG} non disponibile."
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
  viene inoltre salvato a open e confrontato prima del close. La history/cookie
  ZYpp in /var puo registrare il tentativo anche quando TARGET viene abortita.

Matrice VM obbligatoria:
  - registrare versione tukit, tukit.conf e config Snapper effettiva;
  - caratterizzare esattamente output di open e semantica di close;
  - verificare visibilita della cache e del lock ZYpp con /run privato/condiviso;
  - inventariare tutti i mount /var e classificare ogni effetto persistente;
  - dup senza aggiornamento kernel: TARGET riceve comunque una entry BLS;
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
