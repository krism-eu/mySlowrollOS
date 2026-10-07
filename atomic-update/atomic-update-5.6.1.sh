#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# mySlowrollOS guarded offline distribution upgrade v5.6.1
#
# Intended host:
#   - openSUSE Slowroll, classic read-write Btrfs root
#   - Snapper root configuration
#   - systemd-boot managed by sdbootutil
#   - tukit available directly; transactional-update package may be absent
#
# Safety policy:
#   - No timer, daemon or unattended scheduling is installed by this script.
#   - Any unknown state, changed CLI surface, changed SOURCE or ambiguous tukit
#     result fails closed.
#   - SOURCE is never used as the RPM transaction root.
#   - The ESP/boot storage and shared /var are external side-effect domains;
#     SOURCE and TARGET bootability are checked explicitly.
#   - Storage space validation is additive when cache and root share the same filesystem pool.
#   - Volatile runtime files (resolv.conf, leases, locks) and gpg-pubkey pseudo-packages
#     are excluded from strict host consistency barriers to avoid false positives.
#   - /home is required to stay outside the root snapshot on this workstation.
#   - If TARGET is active, recovery never aborts/deletes it.
#   - Confirm verifies post-reboot state without requiring spare boot capacity.
#   - Rollback aborts existing plans only after explicit user confirmation.
#   - SIGINT/SIGTERM are not auto-cleaned: durable state + explicit recover is
#     safer than asynchronous cleanup during an RPM transaction.
#   - This file deliberately uses a v5 namespace and never consumes v3/v4 state.
#   - v5.6.1: zypper exit 102/103 (reboot/restart required) count as a completed
#     dup; the TARGET still has to pass the full manifest verification.
#   - v5.6.1: confirm tolerates ONLY post-boot removal of versions of a
#     kernel-* package that still has another version installed (purge-kernels).
#     Any addition or any other difference vs the verified manifest still fails.

readonly PROG="${0##*/}"
readonly PROGRAM_VERSION='5.6.1-guarded'
readonly STATE_VERSION=5
readonly STATE_DIR=/var/lib/myslowroll/atomic-dup-v5
readonly STATE_FILE="${STATE_DIR}/state"
readonly HISTORY_FILE="${STATE_DIR}/history.log"
readonly CACHE_ROOT=/var/cache/myslowroll-atomic-dup-v5
readonly LOG_ROOT=/var/log/myslowroll-atomic-dup-v5
readonly LOCK_FILE=/run/myslowroll-atomic-dup-v5.lock
readonly SNAPPER_CONFIG=root
readonly REQUIRED_OS_ID=opensuse-slowroll

readonly PLAN_MAX_AGE_SECONDS="${MYSLOWROLL_PLAN_MAX_AGE_SECONDS:-86400}"
readonly TARGET_MAX_AGE_SECONDS="${MYSLOWROLL_TARGET_MAX_AGE_SECONDS:-14400}"
readonly CACHE_MIN_MARGIN_BYTES="${MYSLOWROLL_CACHE_MIN_MARGIN_BYTES:-536870912}"
readonly ROOT_MIN_MARGIN_BYTES="${MYSLOWROLL_ROOT_MIN_MARGIN_BYTES:-1073741824}"
readonly BOOT_MIN_FREE_BYTES="${MYSLOWROLL_BOOT_MIN_FREE_BYTES:-134217728}"
readonly AUTO_AGREE_LICENSES="${MYSLOWROLL_AUTO_AGREE_LICENSES:-0}"
readonly VERIFY_PAYLOADS="${MYSLOWROLL_VERIFY_PAYLOADS:-0}"
readonly AUTO_REBOOT="${MYSLOWROLL_AUTO_REBOOT:-1}"

readonly -a CRITICAL_PKGS=(
    atomic-update criscore1 criscore2 btrfsprogs kernel-default rpm
    sdbootutil sdbootutil-kernel-install sdbootutil-snapper
    snapper systemd systemd-boot tukit zypper
)

readonly -a VALID_STATES=(
    planning planned
    target-opening target-open-ambiguous target-prepared
    target-updating target-update-failed target-updated
    target-verifying target-verification-failed target-verified
    committing pending-reboot confirmed
    aborting aborted rollback-preparing rollback-pending rolled-back rollback-unverified
)

STATE_STATUS=
STATE_TXID=
STATE_SOURCE=
STATE_TARGET=
STATE_BOOT_ID_BEFORE=
STATE_PLAN_HASH=
STATE_RPMDB_HASH=
STATE_ZYPP_HASH=
STATE_CACHE_HASH=
STATE_SOURCE_OPEN_RPM_HASH=
STATE_SOURCE_OPEN_ETC_HASH=
STATE_RPMDB_POST_HASH=
STATE_TOOLCHAIN_HASH=
PREFLIGHT_TOOLCHAIN_HASH=
STATE_CREATED=
STATE_TARGET_OPENED=
STATE_DUP_STARTED=
STATE_FINISHED=
STATE_LAST_ERROR=

TX_CACHE_DIR=
PLAN_TXT=
PLAN_XML_A=
PLAN_XML_B=
PLAN_XML_FINAL=
DOWNLOAD_LOG=
TX_PKG_CACHE=
DUP_LOG=
TUKIT_OPEN_LOG=
SDBOOT_LOG=
POSTCHECK_LOG=
RPMDB_PRE_MANIFEST=
RPMDB_EXPECTED_MANIFEST=
RPMDB_POST_MANIFEST=
PLAN_OPS=

declare -a ZYPPER_LICENSE_ARGS=()

log()  { printf '[%s] %s\n' "${PROG}" "$*"; }
warn() { printf '[%s] ATTENZIONE: %s\n' "${PROG}" "$*" >&2; }
die()  { printf '[%s] ERRORE: %s\n' "${PROG}" "$*" >&2; exit 1; }

usage() {
    cat <<EOF_USAGE
Uso: ${PROG} COMMAND

Comandi:
  check               preflight completo, nessuna modifica
  plan                refresh + doppio piano + pre-download + fingerprint
  upgrade             piano (o riuso) + TARGET offline + dup + verifiche + reboot
  confirm             conferma dopo il reboot sul TARGET
  recover             recovery fail-closed di una transazione interrotta
  rollback [SNAPSHOT] rollback esplicito verso una snapshot e reboot
  status              stato corrente
  prune [GIORNI]      elimina vecchi cache/log v5 (default 30), mai snapshot

Stati bloccanti come target-open-ambiguous, aborting e rollback-unverified
richiedono recover/ispezione; non rilanciare upgrade alla cieca.
EOF_USAGE
}

require_root() { (( EUID == 0 )) || die 'eseguire come root.'; }

acquire_lock() {
    exec 9>"${LOCK_FILE}"
    flock -n 9 || die "un'altra istanza di ${PROG} e' gia' in esecuzione."
}

require_recovery_commands() {
    local cmd
    for cmd in awk bootctl btrfs cat chmod date df findmnt flock grep head install \
               mktemp mv readlink rm sdbootutil sed sha256sum sleep snapper sort sync \
               systemctl tr tukit; do
        command -v "${cmd}" >/dev/null 2>&1 || die "comando richiesto non trovato: ${cmd}"
    done
}

require_commands() {
    require_recovery_commands
    local cmd
    for cmd in cmp comm cp env find rpm stat systemd-inhibit tee wc xargs xmllint zypper; do
        command -v "${cmd}" >/dev/null 2>&1 || die "comando richiesto non trovato: ${cmd}"
    done
}

is_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

current_boot_id() {
    local id
    id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    is_uuid "${id}" || return 1
    printf '%s\n' "${id}"
}

new_txid() {
    local id
    id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    is_uuid "${id}" || die 'impossibile generare transaction id.'
    printf '%s\n' "${id}"
}

bool_true()  { case "${1:-}" in 1|yes|true|on) return 0 ;; *) return 1 ;; esac; }
bool_false() { case "${1:-}" in 0|no|false|off) return 0 ;; *) return 1 ;; esac; }

validate_policy() {
    local name
    local value
    for name in PLAN_MAX_AGE_SECONDS TARGET_MAX_AGE_SECONDS CACHE_MIN_MARGIN_BYTES ROOT_MIN_MARGIN_BYTES BOOT_MIN_FREE_BYTES; do
        value="${!name}"
        [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} deve essere un intero non negativo."
    done
    (( PLAN_MAX_AGE_SECONDS > 0 && TARGET_MAX_AGE_SECONDS > 0 )) || die 'TTL piano/TARGET deve essere > 0.'

    case "${AUTO_AGREE_LICENSES}" in
        0|no|false|off) ZYPPER_LICENSE_ARGS=() ;;
        1|yes|true|on)  ZYPPER_LICENSE_ARGS=(--auto-agree-with-licenses) ;;
        *) die 'MYSLOWROLL_AUTO_AGREE_LICENSES non valido.' ;;
    esac
    case "${VERIFY_PAYLOADS}" in
        0|no|false|off|1|yes|true|on) ;;
        *) die 'MYSLOWROLL_VERIFY_PAYLOADS non valido.' ;;
    esac
    case "${AUTO_REBOOT}" in
        0|no|false|off|1|yes|true|on) ;;
        *) die 'MYSLOWROLL_AUTO_REBOOT non valido.' ;;
    esac
}

state_value_valid() {
    local wanted="$1"
    local item
    for item in "${VALID_STATES[@]}"; do [[ "${item}" == "${wanted}" ]] && return 0; done
    return 1
}

set_tx_paths() {
    [[ -n "${STATE_TXID}" ]] || return 0
    TX_CACHE_DIR="${CACHE_ROOT}/${STATE_TXID}"
    PLAN_TXT="${TX_CACHE_DIR}/dup-plan.txt"
    PLAN_XML_A="${TX_CACHE_DIR}/dup-plan-a.xml"
    PLAN_XML_B="${TX_CACHE_DIR}/dup-plan-b.xml"
    PLAN_XML_FINAL="${TX_CACHE_DIR}/dup-plan-final.xml"
    DOWNLOAD_LOG="${TX_CACHE_DIR}/download.log"
    TX_PKG_CACHE="${TX_CACHE_DIR}/packages"
    RPMDB_PRE_MANIFEST="${TX_CACHE_DIR}/rpmdb-pre.tsv"
    RPMDB_EXPECTED_MANIFEST="${TX_CACHE_DIR}/rpmdb-expected-post.tsv"
    RPMDB_POST_MANIFEST="${TX_CACHE_DIR}/rpmdb-post.tsv"
    PLAN_OPS="${TX_CACHE_DIR}/plan-operations.tsv"
    DUP_LOG="${LOG_ROOT}/${STATE_TXID}.dup.log"
    TUKIT_OPEN_LOG="${LOG_ROOT}/${STATE_TXID}.tukit-open.log"
    SDBOOT_LOG="${LOG_ROOT}/${STATE_TXID}.sdboot.log"
    POSTCHECK_LOG="${LOG_ROOT}/${STATE_TXID}.postcheck.log"
}

reset_state() {
    STATE_STATUS= STATE_TXID= STATE_SOURCE= STATE_TARGET= STATE_BOOT_ID_BEFORE=
    STATE_PLAN_HASH= STATE_RPMDB_HASH= STATE_ZYPP_HASH= STATE_CACHE_HASH=
    STATE_SOURCE_OPEN_RPM_HASH= STATE_SOURCE_OPEN_ETC_HASH= STATE_RPMDB_POST_HASH=
    STATE_TOOLCHAIN_HASH= STATE_CREATED= STATE_TARGET_OPENED= STATE_DUP_STARTED=
    STATE_FINISHED= STATE_LAST_ERROR=
    TX_CACHE_DIR= PLAN_TXT= PLAN_XML_A= PLAN_XML_B= PLAN_XML_FINAL= DOWNLOAD_LOG=
    TX_PKG_CACHE= DUP_LOG= TUKIT_OPEN_LOG= SDBOOT_LOG= POSTCHECK_LOG=
    RPMDB_PRE_MANIFEST= RPMDB_EXPECTED_MANIFEST= RPMDB_POST_MANIFEST= PLAN_OPS=
}

load_state() {
    local key
    local value
    local seen_version=0
    local file_version=
    reset_state
    [[ -f "${STATE_FILE}" ]] || return 0
    while IFS='=' read -r key value; do
        case "${key}" in
            version) (( seen_version == 0 )) || die 'version duplicata nello state'; seen_version=1; file_version="${value}" ;;
            status) STATE_STATUS="${value}" ;;
            txid) STATE_TXID="${value}" ;;
            source_snapshot) STATE_SOURCE="${value}" ;;
            target_snapshot) STATE_TARGET="${value}" ;;
            boot_id_before) STATE_BOOT_ID_BEFORE="${value}" ;;
            plan_hash) STATE_PLAN_HASH="${value}" ;;
            rpmdb_hash) STATE_RPMDB_HASH="${value}" ;;
            zypp_hash) STATE_ZYPP_HASH="${value}" ;;
            cache_hash) STATE_CACHE_HASH="${value}" ;;
            source_open_rpm_hash) STATE_SOURCE_OPEN_RPM_HASH="${value}" ;;
            source_open_etc_hash) STATE_SOURCE_OPEN_ETC_HASH="${value}" ;;
            rpmdb_post_hash) STATE_RPMDB_POST_HASH="${value}" ;;
            toolchain_hash) STATE_TOOLCHAIN_HASH="${value}" ;;
            created_utc) STATE_CREATED="${value}" ;;
            target_opened_utc) STATE_TARGET_OPENED="${value}" ;;
            dup_started_utc) STATE_DUP_STARTED="${value}" ;;
            finished_utc) STATE_FINISHED="${value}" ;;
            last_error) STATE_LAST_ERROR="${value}" ;;
            ''|'#'*) ;;
            *) die "chiave state sconosciuta: ${key}" ;;
        esac
    done < "${STATE_FILE}"

    (( seen_version == 1 )) || die 'state privo di versione.'
    [[ "${file_version}" == "${STATE_VERSION}" ]] || die "state v${file_version} incompatibile con v${STATE_VERSION}."
    [[ -n "${STATE_STATUS}" ]] || die 'state privo di status.'
    # v5.5 could persist an intermediate confirming state. v5.6 never writes it:
    # treat it as pending-reboot so confirm can be safely repeated after a crash.
    [[ "${STATE_STATUS}" == confirming ]] && STATE_STATUS=pending-reboot
    state_value_valid "${STATE_STATUS}" || die "state sconosciuto: ${STATE_STATUS}"
    [[ -z "${STATE_TXID}" ]] || is_uuid "${STATE_TXID}" || die 'txid non valido.'
    [[ -z "${STATE_SOURCE}" || "${STATE_SOURCE}" =~ ^[0-9]+$ ]] || die 'SOURCE non valida.'
    [[ -z "${STATE_TARGET}" || "${STATE_TARGET}" =~ ^[0-9]+$ ]] || die 'TARGET non valida.'
    local h
    for h in STATE_PLAN_HASH STATE_RPMDB_HASH STATE_ZYPP_HASH STATE_CACHE_HASH STATE_SOURCE_OPEN_RPM_HASH STATE_SOURCE_OPEN_ETC_HASH STATE_RPMDB_POST_HASH STATE_TOOLCHAIN_HASH; do
        [[ -z "${!h}" || "${!h}" =~ ^[0-9a-f]{64}$ ]] || die "hash non valido: ${h}"
    done
    set_tx_paths
}

persist_state() {
    local tmp
    local safe
    install -d -o root -g root -m 0700 "${STATE_DIR}" || return 1
    tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")" || return 1
    chmod 0600 "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    safe="${STATE_LAST_ERROR//$'\n'/ }"; safe="${safe//$'\r'/ }"; safe="${safe//$'\t'/ }"
    {
        printf 'version=%s\n' "${STATE_VERSION}"
        printf 'status=%s\n' "${STATE_STATUS}"
        printf 'txid=%s\n' "${STATE_TXID}"
        printf 'source_snapshot=%s\n' "${STATE_SOURCE}"
        printf 'target_snapshot=%s\n' "${STATE_TARGET}"
        printf 'boot_id_before=%s\n' "${STATE_BOOT_ID_BEFORE}"
        printf 'plan_hash=%s\n' "${STATE_PLAN_HASH}"
        printf 'rpmdb_hash=%s\n' "${STATE_RPMDB_HASH}"
        printf 'zypp_hash=%s\n' "${STATE_ZYPP_HASH}"
        printf 'cache_hash=%s\n' "${STATE_CACHE_HASH}"
        printf 'source_open_rpm_hash=%s\n' "${STATE_SOURCE_OPEN_RPM_HASH}"
        printf 'source_open_etc_hash=%s\n' "${STATE_SOURCE_OPEN_ETC_HASH}"
        printf 'rpmdb_post_hash=%s\n' "${STATE_RPMDB_POST_HASH}"
        printf 'toolchain_hash=%s\n' "${STATE_TOOLCHAIN_HASH}"
        printf 'created_utc=%s\n' "${STATE_CREATED}"
        printf 'target_opened_utc=%s\n' "${STATE_TARGET_OPENED}"
        printf 'dup_started_utc=%s\n' "${STATE_DUP_STARTED}"
        printf 'finished_utc=%s\n' "${STATE_FINISHED}"
        printf 'last_error=%s\n' "${safe}"
    } > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    sync "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${STATE_FILE}" || { rm -f -- "${tmp}"; return 1; }
    sync "${STATE_DIR}" || return 1
}

persist_state_or_die() { persist_state || die 'impossibile rendere persistente lo state; operazione fermata.'; }

history() {
    local event="$1"
    local detail="${2:-}"
    local stamp
    stamp="$(date -u +%FT%TZ)" || return 1
    detail="${detail//$'\n'/ }"; detail="${detail//$'\t'/ }"
    install -d -o root -g root -m 0700 "${STATE_DIR}" || return 1
    printf '%s\t%s\t%s\tstatus=%s\tsource=%s\ttarget=%s\t%s\n' \
        "${stamp}" "${STATE_TXID:-none}" "${event}" "${STATE_STATUS:-none}" \
        "${STATE_SOURCE:-none}" "${STATE_TARGET:-none}" "${detail}" >> "${HISTORY_FILE}" || return 1
    chmod 0600 "${HISTORY_FILE}" || return 1
    sync "${HISTORY_FILE}" || return 1
}
history_or_warn() { history "$@" || warn 'history.log non aggiornabile; state resta autoritativo.'; }

mark_aborted() {
    STATE_STATUS=aborted
    STATE_FINISHED="$(date -u +%FT%TZ)"
    STATE_LAST_ERROR="$1"
    persist_state_or_die
    history_or_warn aborted "$1"
}

snapshot_path() { [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1; printf '/.snapshots/%s/snapshot\n' "$1"; }
active_snapshot() {
    local opts
    opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
    sed -nE 's#.*subvol=/?.*\.snapshots/([0-9]+)/snapshot.*#\1#p' <<<"${opts}" | head -n1
}
default_snapshot() {
    local line
    line="$(btrfs subvolume get-default / 2>/dev/null || true)"
    sed -nE 's#.*path .*\.snapshots/([0-9]+)/snapshot.*#\1#p' <<<"${line}" | head -n1
}
snapshot_exists() { [[ -d "$(snapshot_path "$1")" ]]; }
snapshot_is_rw() { [[ "$(btrfs property get "$(snapshot_path "$1")" ro 2>/dev/null || true)" == 'ro=false' ]]; }
snapshot_os_id() {
    awk -F= '$1=="ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$(snapshot_path "$1")/usr/lib/os-release" 2>/dev/null || true
}
snapshot_is_bootable() { sdbootutil is-bootable "$1" >/dev/null 2>&1; }

os_id() { awk -F= '$1=="ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true; }

nearest_existing_storage_path() {
    local p="$1"
    [[ "${p}" == /* ]] || return 1
    while [[ ! -e "${p}" && ! -L "${p}" ]]; do
        [[ "${p}" != / ]] || break
        p="${p%/*}"; [[ -n "${p}" ]] || p=/
    done
    readlink -f -- "${p}" 2>/dev/null
}

path_is_outside_root_snapshot() {
    local wanted="$1"
    local path
    local root_dev path_dev root_fs path_fs root_id path_id
    path="$(nearest_existing_storage_path "${wanted}")" || return 1
    root_dev="$(findmnt -n -o MAJ:MIN --target / 2>/dev/null || true)"
    path_dev="$(findmnt -n -o MAJ:MIN --target "${path}" 2>/dev/null || true)"
    [[ -n "${root_dev}" && -n "${path_dev}" ]] || return 1
    [[ "${root_dev}" != "${path_dev}" ]] && return 0
    root_fs="$(findmnt -n -o FSTYPE --target / 2>/dev/null || true)"
    path_fs="$(findmnt -n -o FSTYPE --target "${path}" 2>/dev/null || true)"
    [[ "${root_fs}" == btrfs && "${path_fs}" == btrfs ]] || return 1
    root_id="$(btrfs inspect-internal rootid / 2>/dev/null || true)"
    path_id="$(btrfs inspect-internal rootid "${path}" 2>/dev/null || true)"
    [[ "${root_id}" =~ ^[0-9]+$ && "${path_id}" =~ ^[0-9]+$ && "${root_id}" != "${path_id}" ]]
}

rpmdb_is_in_root_snapshot() {
    local p
    local root_dev db_dev root_id db_id
    p="$(rpm --eval '%{_dbpath}' 2>/dev/null || true)"
    [[ "${p}" == /* ]] || return 1
    p="$(readlink -f -- "${p}" 2>/dev/null || true)"
    [[ -d "${p}" ]] || return 1
    root_dev="$(findmnt -n -o MAJ:MIN --target / 2>/dev/null || true)"
    db_dev="$(findmnt -n -o MAJ:MIN --target "${p}" 2>/dev/null || true)"
    [[ -n "${root_dev}" && "${root_dev}" == "${db_dev}" ]] || return 1
    root_id="$(btrfs inspect-internal rootid / 2>/dev/null || true)"
    db_id="$(btrfs inspect-internal rootid "${p}" 2>/dev/null || true)"
    [[ "${root_id}" =~ ^[0-9]+$ && "${root_id}" == "${db_id}" ]]
}

available_bytes() { LC_ALL=C df -B1 --output=avail -- "$1" 2>/dev/null | awk 'NR==2 && $1~/^[0-9]+$/ {print $1}'; }

check_one_boot_storage() {
    local label="$1"
    local p="$2"
    local avail opts
    [[ -n "${p}" && -d "${p}" ]] || return 1
    opts="$(findmnt -n -o OPTIONS --target "${p}" 2>/dev/null || true)"
    tr ',' '\n' <<<"${opts}" | grep -qx rw || { warn "${label} ${p} non montato read-write."; return 1; }
    avail="$(available_bytes "${p}")" || return 1
    [[ "${avail}" =~ ^[0-9]+$ ]] || return 1
    (( avail >= BOOT_MIN_FREE_BYTES )) || { warn "spazio ${label} insufficiente su ${p}: ${avail} < ${BOOT_MIN_FREE_BYTES}"; return 1; }
}

check_boot_space() {
    local boot
    local esp
    local boot_r esp_r
    boot="$(bootctl --print-boot-path 2>/dev/null || true)"
    esp="$(bootctl --print-esp-path 2>/dev/null || true)"
    [[ -n "${boot}" && -d "${boot}" ]] || return 1
    [[ -n "${esp}" && -d "${esp}" ]] || return 1
    check_one_boot_storage BOOT "${boot}" || return 1
    boot_r="$(readlink -f -- "${boot}" 2>/dev/null || true)"
    esp_r="$(readlink -f -- "${esp}" 2>/dev/null || true)"
    [[ -n "${boot_r}" && -n "${esp_r}" ]] || return 1
    [[ "${boot_r}" == "${esp_r}" ]] || check_one_boot_storage ESP "${esp}" || return 1
}

check_zypp_lock_hint() {
    local f pid
    for f in /run/zypp.pid /run/zypp-rpm.pid; do
        [[ -r "${f}" ]] || continue
        pid=
        read -r pid < "${f}" || true
        if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            warn "ZYpp risulta gia in uso dal PID ${pid} (${f})."
            return 1
        fi
    done
    return 0
}

systemd_unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

check_conflicting_update_units_idle() {
    # The intended v5.6 host does not require the transactional-update package.
    # If stale/optional units exist, they must not be enabled/active/failed.
    if systemd_unit_exists transactional-update.timer \
       && systemctl is-enabled --quiet transactional-update.timer 2>/dev/null; then
        warn 'transactional-update.timer presente e abilitato; conflitto con il flusso tukit diretto.'
        return 1
    fi
    if systemd_unit_exists transactional-update.service; then
        if systemctl is-active --quiet transactional-update.service 2>/dev/null; then
            warn 'transactional-update.service presente e attivo.'
            return 1
        fi
        if systemctl is-failed --quiet transactional-update.service 2>/dev/null; then
            warn 'transactional-update.service presente in stato failed.'
            return 1
        fi
    fi
    return 0
}

zypp_config_files() {
    local vendor=/usr/etc/zypp
    local system=/etc/zypp
    local p n
    if [[ -e "${system}/zypp.conf" || -L "${system}/zypp.conf" ]]; then printf '%s\n' "${system}/zypp.conf";
    elif [[ -e "${vendor}/zypp.conf" || -L "${vendor}/zypp.conf" ]]; then printf '%s\n' "${vendor}/zypp.conf"; fi
    { for p in "${vendor}"/zypp.conf.d/*.conf "${system}"/zypp.conf.d/*.conf; do [[ -e "${p}" || -L "${p}" ]] && printf '%s\n' "${p##*/}"; done; } |
      LC_ALL=C sort -u | while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        if [[ -e "${system}/zypp.conf.d/${n}" || -L "${system}/zypp.conf.d/${n}" ]]; then printf '%s\n' "${system}/zypp.conf.d/${n}";
        elif [[ -e "${vendor}/zypp.conf.d/${n}" || -L "${vendor}/zypp.conf.d/${n}" ]]; then printf '%s\n' "${vendor}/zypp.conf.d/${n}"; fi
      done
}

zypp_value() {
    local wanted="$1"
    local -a files=()
    mapfile -t files < <(zypp_config_files)
    if (( ${#files[@]} == 0 )); then case "${wanted}" in solver.onlyRequires|solver.dupAllowVendorChange) printf 'false\n';; esac; return 0; fi
    awk -F= -v wanted="${wanted}" '
      /^[[:space:]]*#/ {next}
      NF>=2 { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if(k==wanted){v=$2; sub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); out=tolower(v); seen=1}}
      END { if(seen) print out; else if(wanted=="solver.onlyRequires" || wanted=="solver.dupAllowVendorChange") print "false" }
    ' "${files[@]}" 2>/dev/null || true
}

write_rpm_manifest_host() {
    local out="$1"
    local tmp="${out}.tmp"
    LC_ALL=C rpm -qa --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}|%{ARCH}\n' | grep -v '^gpg-pubkey|' | LC_ALL=C sort -u > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${out}"
}

rpmdb_hash_host() {
    local tmp
    local h
    tmp="$(mktemp /run/myslowroll-rpmdb.XXXXXX)" || return 1
    if ! LC_ALL=C rpm -qa --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}|%{ARCH}\n' | grep -v '^gpg-pubkey|' | LC_ALL=C sort -u >"${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    h="$(sha256sum "${tmp}" | awk '{print $1}')"; rm -f -- "${tmp}"
    [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || return 1; printf '%s\n' "${h}"
}

etc_tree_hash() {
    local tmp1
    local tmp2
    local h
    tmp1="$(mktemp /run/myslowroll-etc-meta.XXXXXX)" || return 1
    tmp2="$(mktemp /run/myslowroll-etc-files.XXXXXX)" || { rm -f -- "${tmp1}"; return 1; }

    # Exclude volatile runtime state and DHCP/netconfig managed resolv.conf files
    LC_ALL=C find /etc -xdev \
        ! -path '/etc/resolv.conf*' \
        ! -path '/etc/adjtime' \
        ! -path '/etc/machine-info' \
        ! -name '*.lease' \
        ! -name '*.lock' \
        ! -name '*.tmp' \
        -printf '%y|%m|%U|%G|%p|%l\0' |
        LC_ALL=C sort -z |
        sha256sum |
        awk '{print $1}' >"${tmp1}" || { rm -f -- "${tmp1}" "${tmp2}"; return 1; }

    LC_ALL=C find /etc -xdev \
        ! -path '/etc/resolv.conf*' \
        ! -path '/etc/adjtime' \
        ! -path '/etc/machine-info' \
        ! -name '*.lease' \
        ! -name '*.lock' \
        ! -name '*.tmp' \
        -type f -print0 |
        LC_ALL=C sort -z |
        xargs -0 -r sha256sum -- |
        sha256sum |
        awk '{print $1}' >"${tmp2}" || { rm -f -- "${tmp1}" "${tmp2}"; return 1; }

    h="$(cat "${tmp1}" "${tmp2}" | sha256sum | awk '{print $1}')"
    rm -f -- "${tmp1}" "${tmp2}"
    [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${h}"
}

zypp_semantic_hash() {
    {
        printf 'solver.onlyRequires=%s\n' "$(zypp_value solver.onlyRequires)"
        printf 'solver.dupAllowVendorChange=%s\n' "$(zypp_value solver.dupAllowVendorChange)"
        LC_ALL=C zypper --non-interactive lr -u -p 2>/dev/null
    } | sed -E 's/[[:space:]]+$//' | sha256sum | awk '{print $1}'
}

pkg_cache_hash() {
    [[ -d "${TX_PKG_CACHE}" ]] || return 1
    local f
    local tmp
    local hash
    tmp="$(mktemp "${TX_CACHE_DIR}/.cache-hash.XXXXXX")" || return 1
    while IFS= read -r -d '' f; do
        sha256sum "${f}" >>"${tmp}" || { rm -f -- "${tmp}"; return 1; }
    done < <(find "${TX_PKG_CACHE}" -type f -name '*.rpm' -print0 | LC_ALL=C sort -z)
    hash="$(sha256sum "${tmp}" | awk '{print $1}')"
    rm -f -- "${tmp}"
    [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${hash}"
}

pkg_cache_has_rpms() {
    [[ -d "${TX_PKG_CACHE}" ]] || return 1
    find "${TX_PKG_CACHE}" -type f -name '*.rpm' -print -quit | grep -q .
}

verify_cli_surface() {
    local th tv sv rh ch sub
    tv="$(LC_ALL=C tukit --version 2>&1 || true)"
    th="$(LC_ALL=C tukit --help 2>&1 || true)"
    sv="$(LC_ALL=C sdbootutil --help 2>&1 || true)"
    rh="$(LC_ALL=C sdbootutil remove-all-kernels --help 2>&1 || true)"
    ch="$(LC_ALL=C sdbootutil cleanup --help 2>&1 || true)"
    [[ -n "${tv}" && -n "${th}" && -n "${sv}" && -n "${rh}" && -n "${ch}" ]] || return 1
    for sub in open call close abort; do grep -Eq "(^|[[:space:]])${sub}([[:space:]]|$)" <<<"${th}" || return 1; done
    for sub in add-all-kernels is-bootable remove-all-kernels cleanup; do grep -Eq "(^|[[:space:]])${sub}([[:space:]]|$)" <<<"${sv}" || return 1; done
    grep -Fq -- '--disable-predictions' <<<"${rh}" || return 1
    grep -Fq -- '--disable-predictions' <<<"${ch}" || return 1
    printf '%s\n---\n%s\n---\n%s\n---\n%s\n---\n%s\n' "${tv}" "${th}" "${sv}" "${rh}" "${ch}" | sha256sum | awk '{print $1}'
}

toolchain_unchanged() {
    local now
    now="$(verify_cli_surface)" || return 1
    [[ "${STATE_TOOLCHAIN_HASH}" == "${now}" ]]
}

assert_toolchain_unchanged() {
    toolchain_unchanged || die 'toolchain tukit/sdbootutil cambiata o non piu compatibile.'
}

ensure_snapshot_bootable() {
    local snap="$1"
    local out
    snapshot_is_bootable "${snap}" && return 0
    check_boot_space || return 1
    if ! out="$(LC_ALL=C sdbootutil add-all-kernels "${snap}" 2>&1)"; then
        printf '[add-all-kernels %s FAILED]\n%s\n' "${snap}" "${out}" >>"${SDBOOT_LOG}" 2>/dev/null || true
        return 1
    fi
    printf '[add-all-kernels %s OK]\n%s\n' "${snap}" "${out}" >>"${SDBOOT_LOG}" 2>/dev/null || true
    sync "${SDBOOT_LOG}" 2>/dev/null || true
    snapshot_is_bootable "${snap}"
}

install_summary_count() { LC_ALL=C xmllint --xpath 'count(//*[local-name()="install-summary"])' "$1" 2>/dev/null; }
xml_summary_attribute() { LC_ALL=C xmllint --xpath "string(//*[local-name()='install-summary']/@$2)" "$1" 2>/dev/null; }

plan_hash() {
    local plan="$1"
    local count
    local tmp
    local hash
    count="$(install_summary_count "${plan}")" || return 1
    [[ "${count}" == 1 || "${count}" == 1.0 ]] || return 1
    tmp="$(mktemp "${TX_CACHE_DIR}/.planhash.XXXXXX")" || return 1
    { printf '<myslowroll-plan>'; LC_ALL=C xmllint --xpath '//*[local-name()="install-summary"]' "${plan}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }; printf '</myslowroll-plan>\n'; } >"${tmp}"
    sed -E -i 's/[[:space:]]+download-size="[0-9]+"//' "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    hash="$(LC_ALL=C xmllint --c14n "${tmp}" 2>/dev/null | sha256sum | awk '{print $1}')"; rm -f -- "${tmp}"
    [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1; printf '%s\n' "${hash}"
}

generate_xml_plan() {
    local raw="$1"
    local tmp="${raw}.tmp"
    DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive --xmlout dup \
        "${ZYPPER_LICENSE_ARGS[@]}" --dry-run --no-recommends --no-allow-vendor-change --details > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    # Fail-closed deterministic XML formatting
    LC_ALL=C xmllint --format "${tmp}" > "${raw}" 2>/dev/null || { rm -f -- "${tmp}" "${raw}"; return 1; }
    rm -f -- "${tmp}"
}

extract_plan_operations() {
    local plan="$1"
    local out="$2"
    LC_ALL=C awk '
      function attr(s,key, token){token=key "=\"[^\"]*\""; if(match(s,token)){return substr(s,RSTART+length(key)+2,RLENGTH-length(key)-3)} return ""}
      /<to-(install|remove|upgrade|downgrade|upgrade-change-arch|downgrade-change-arch|reinstall|change-arch)>/ {line=$0; sub(/^.*<to-/,"",line); sub(/>.*/,"",line); op=line; next}
      /<\/to-(install|remove|upgrade|downgrade|upgrade-change-arch|downgrade-change-arch|reinstall|change-arch)>/ {op=""; next}
      op!="" && /<solvable[[:space:]]/ {kind=attr($0,"type"); if(kind=="") kind=attr($0,"kind"); if(kind!="package") next; n=attr($0,"name"); e=attr($0,"edition"); a=attr($0,"arch"); oe=attr($0,"edition-old"); oa=attr($0,"arch-old"); if(n==""||e==""||a=="") exit 42; print op "\t" n "\t" e "\t" a "\t" oe "\t" oa}
    ' "${plan}" >"${out}"
}

validate_plan_operation_count() {
    local expected
    local actual
    expected="$(xml_summary_attribute "$1" packages-to-change)" || return 1
    actual="$(awk 'END{print NR+0}' "$2")" || return 1
    [[ "${expected}" =~ ^[0-9]+$ && "${expected}" == "${actual}" ]]
}

parser_selftest() {
    local xml
    local ops
    xml="$(mktemp /run/myslowroll-plan-selftest.XXXXXX.xml)" || return 1
    ops="$(mktemp /run/myslowroll-plan-selftest.XXXXXX.tsv)" || { rm -f -- "${xml}"; return 1; }
    cat >"${xml}" <<'EOF_XML_SELFTEST'
<stream>
  <install-summary packages-to-change="3" download-size="123" space-usage-installed="456">
    <to-install>
      <solvable type="package" name="pkg-a" edition="1-1" arch="x86_64"/>
    </to-install>
    <to-upgrade>
      <solvable type="package" name="pkg-b" edition="2-1" arch="x86_64" edition-old="1-1" arch-old="x86_64"/>
    </to-upgrade>
    <to-remove>
      <solvable type="package" name="pkg-c" edition="3-1" arch="noarch"/>
    </to-remove>
  </install-summary>
</stream>
EOF_XML_SELFTEST
    extract_plan_operations "${xml}" "${ops}" || { rm -f -- "${xml}" "${ops}"; return 1; }
    validate_plan_operation_count "${xml}" "${ops}" || { rm -f -- "${xml}" "${ops}"; return 1; }
    [[ "$(xml_summary_attribute "${xml}" download-size)" == 123 ]] || { rm -f -- "${xml}" "${ops}"; return 1; }
    [[ "$(xml_summary_attribute "${xml}" space-usage-installed)" == 456 ]] || { rm -f -- "${xml}" "${ops}"; return 1; }
    awk -F '\t' '
        NR==1 { ok = ($1=="install" && $2=="pkg-a" && $3=="1-1" && $4=="x86_64") }
        NR==2 { ok = ok && ($1=="upgrade" && $2=="pkg-b" && $3=="2-1" && $4=="x86_64" && $5=="1-1" && $6=="x86_64") }
        NR==3 { ok = ok && ($1=="remove" && $2=="pkg-c" && $3=="3-1" && $4=="noarch") }
        END { exit !(ok && NR==3) }
    ' "${ops}" || { rm -f -- "${xml}" "${ops}"; return 1; }
    rm -f -- "${xml}" "${ops}"
}

build_expected_manifest() {
    local pre="$1"
    local ops="$2"
    local out="$3"
    local work="${out}.work"
    local next="${out}.next"
    local op
    local name
    local edition
    local arch
    local oldedition
    local oldarch
    local oldline
    local newline
    cp -- "${pre}" "${work}" || return 1
    while IFS=$'\t' read -r op name edition arch oldedition oldarch; do
        [[ -n "${op}" ]] || continue; newline="${name}|${edition}|${arch}"
        case "${op}" in
            install) printf '%s\n' "${newline}" >>"${work}" || return 1; continue ;;
            remove) oldline="${newline}" ;;
            upgrade|downgrade|upgrade-change-arch|downgrade-change-arch|reinstall|change-arch)
                [[ -n "${oldedition}" ]] || oldedition="${edition}"; [[ -n "${oldarch}" ]] || oldarch="${arch}"; oldline="${name}|${oldedition}|${oldarch}" ;;
            *) return 1 ;;
        esac
        grep -Fxq -- "${oldline}" "${work}" || return 1
        awk -v t="${oldline}" '$0!=t' "${work}" >"${next}" || return 1
        mv -f -- "${next}" "${work}" || return 1
        [[ "${op}" == remove ]] || printf '%s\n' "${newline}" >>"${work}" || return 1
    done <"${ops}"
    LC_ALL=C sort -u "${work}" >"${out}" || return 1
    rm -f -- "${work}" "${next}"
}

check_plan_space() {
    local download
    local installed
    local cache_avail
    local root_avail
    download="$(xml_summary_attribute "$1" download-size)" || return 1
    installed="$(xml_summary_attribute "$1" space-usage-installed)" || return 1
    [[ "${download}" =~ ^[0-9]+$ && "${installed}" =~ ^[0-9]+$ ]] || return 1

    cache_avail="$(available_bytes "${TX_PKG_CACHE}")" || return 1
    root_avail="$(available_bytes /)" || return 1

    local cache_dev
    local root_dev
    cache_dev="$(findmnt -n -o MAJ:MIN --target "${TX_PKG_CACHE}" 2>/dev/null || true)"
    root_dev="$(findmnt -n -o MAJ:MIN --target / 2>/dev/null || true)"

    if [[ -n "${cache_dev}" && "${cache_dev}" == "${root_dev}" ]]; then
        local total_needed=$(( download + installed + CACHE_MIN_MARGIN_BYTES + ROOT_MIN_MARGIN_BYTES ))
        (( root_avail >= total_needed )) || {
            warn "spazio su pool condiviso insufficiente: disponibili ${root_avail} byte, richiesti ${total_needed} byte."
            return 1
        }
    else
        (( cache_avail >= download + CACHE_MIN_MARGIN_BYTES )) || return 1
        (( root_avail >= installed + ROOT_MIN_MARGIN_BYTES )) || return 1
    fi
}

scan_plan_for_critical_removals() {
    local pkg
    local xpath
    local count
    for pkg in "${CRITICAL_PKGS[@]}"; do
        xpath="count(//*[local-name()='install-summary']/*[local-name()='to-remove']//*[local-name()='solvable'][@name='${pkg}'])"
        count="$(LC_ALL=C xmllint --xpath "${xpath}" "$1" 2>/dev/null)" || return 1
        case "${count}" in 0|0.0) ;; *) warn "piano rimuove pacchetto critico ${pkg}"; return 1;; esac
    done
}

preflight() {
    local mode="${1:-update}"
    local p a d toolhash
    PREFLIGHT_TOOLCHAIN_HASH=
    require_root; acquire_lock
    if [[ "${mode}" == recovery ]]; then require_recovery_commands; else require_commands; fi
    validate_policy

    [[ "$(findmnt -n -o FSTYPE --target / 2>/dev/null || true)" == btrfs ]] || die 'root non Btrfs.'
    findmnt -n -o OPTIONS --target / | tr ',' '\n' | grep -qx rw || die 'root non RW.'
    snapper -c "${SNAPPER_CONFIG}" get-config >/dev/null 2>&1 || die 'Snapper root non disponibile.'
    path_is_outside_root_snapshot "${STATE_DIR}" || die 'STATE_DIR non persistente fuori root snapshot.'
    path_is_outside_root_snapshot "${CACHE_ROOT}" || die 'CACHE_ROOT non persistente fuori root snapshot.'
    path_is_outside_root_snapshot "${LOG_ROOT}" || die 'LOG_ROOT non persistente fuori root snapshot.'
    grep -qi systemd-boot <<<"$(sdbootutil bootloader 2>/dev/null || true)" || die 'systemd-boot non rilevato.'

    # Boot storage capacity is enforced during update planning, but omitted in recovery and confirm
    # to avoid deadlocks when confirming or cleaning up.
    if [[ "${mode}" == update ]]; then
        check_boot_space || die 'spazio boot insufficiente/non determinabile.'
    fi

    toolhash="$(verify_cli_surface)" || die 'CLI tukit/sdbootutil incompatibile.'
    PREFLIGHT_TOOLCHAIN_HASH="${toolhash}"

    [[ "${mode}" == recovery ]] && return 0
    [[ "${mode}" =~ ^(update|confirm)$ ]] || die "modalita preflight sconosciuta: ${mode}"

    [[ "$(os_id)" == "${REQUIRED_OS_ID}" ]] || die 'questo tool e limitato a openSUSE Slowroll.'
    path_is_outside_root_snapshot /var || die '/var deve essere fuori dalla root snapshot per questa policy.'
    path_is_outside_root_snapshot /home || die '/home deve essere fuori dalla root snapshot su questa workstation.'
    rpmdb_is_in_root_snapshot || die 'RPMDB non inclusa nella root snapshot.'
    parser_selftest || die 'self-test parser XML/plan fallito.'
    [[ ! -e /run/criscore.allow-removal ]] || die 'token criscore.allow-removal presente.'
    for p in "${CRITICAL_PKGS[@]}"; do rpm --quiet -q "${p}" || die "pacchetto critico richiesto mancante: ${p}"; done

    # Transient locking checks are required only before planning or modifying packages
    if [[ "${mode}" == update ]]; then
        bool_true "$(zypp_value solver.onlyRequires)" || die 'solver.onlyRequires deve essere true.'
        bool_false "$(zypp_value solver.dupAllowVendorChange)" || die 'solver.dupAllowVendorChange deve essere false.'
        check_conflicting_update_units_idle || die 'unita transactional-update opzionali/stale in conflitto con tukit diretto.'
        check_zypp_lock_hint || die 'ZYpp risulta gia in uso.'
    fi

    a="$(active_snapshot)"; d="$(default_snapshot)"
    [[ -n "${a}" && "${a}" == "${d}" ]] || die "active/default non coincidono (${a:-?}/${d:-?})."
    snapshot_is_rw "${a}" || die "snapshot attiva ${a} non RW."
    snapshot_is_bootable "${a}" || die "snapshot attiva ${a} non potenzialmente bootable."
}

plan_age_seconds() {
    local c
    local n
    c="$(date -u -d "${STATE_CREATED}" +%s 2>/dev/null)" || return 1
    n="$(date -u +%s)"
    (( n>=c )) || return 1
    printf '%s\n' "$((n-c))"
}

planned_is_fresh() { [[ "${STATE_STATUS}" == planned ]] || return 1; local a; a="$(plan_age_seconds)" || return 1; (( a <= PLAN_MAX_AGE_SECONDS )); }

check_state_for_new() {
    load_state
    case "${STATE_STATUS}" in
        ''|confirmed|aborted|rolled-back) return 0 ;;
        planned) return 0 ;;
        *) die "transazione v5 ${STATE_TXID:-?} in stato ${STATE_STATUS}; usare recover/status prima di continuare." ;;
    esac
}

make_plan() {
    local already_locked="${1:-0}"
    local toolhash
    local hash_a hash_b rpm_a rpm_b zypp_a zypp_b cache_b a d
    local -a rc
    if (( already_locked == 0 )); then
        preflight
        check_state_for_new
    fi
    toolhash="${PREFLIGHT_TOOLCHAIN_HASH}"
    a="$(active_snapshot)"; d="$(default_snapshot)"; [[ "${a}" == "${d}" ]] || die 'active/default cambiati durante preflight.'
    if [[ "${STATE_STATUS}" == planned ]]; then mark_aborted 'piano precedente sostituito'; fi
    # A new TXID must never inherit transaction-specific fields from the previous state.
    reset_state
    STATE_TXID="$(new_txid)"; STATE_CREATED="$(date -u +%FT%TZ)"; STATE_STATUS=planning; STATE_SOURCE="${a}"; STATE_TARGET=
    STATE_TOOLCHAIN_HASH="${toolhash}"; STATE_LAST_ERROR=; set_tx_paths
    install -d -o root -g root -m 0700 "${STATE_DIR}" "${TX_CACHE_DIR}" "${TX_PKG_CACHE}" "${LOG_ROOT}" || die 'creazione directory transazione fallita.'
    persist_state_or_die; history_or_warn planning-started

    log 'Refresh repository...'; zypper --non-interactive refresh || { mark_aborted 'refresh fallito'; return 1; }
    write_rpm_manifest_host "${RPMDB_PRE_MANIFEST}" || { mark_aborted 'manifest RPM pre fallito'; return 1; }
    rpm_a="$(sha256sum "${RPMDB_PRE_MANIFEST}" | awk '{print $1}')"; zypp_a="$(zypp_semantic_hash)"

    generate_xml_plan "${PLAN_XML_A}" || { mark_aborted 'piano XML A fallito'; return 1; }
    scan_plan_for_critical_removals "${PLAN_XML_A}" || { mark_aborted 'rimozioni critiche nel piano'; return 1; }
    hash_a="$(plan_hash "${PLAN_XML_A}")" || { mark_aborted 'hash piano A fallito'; return 1; }
    check_plan_space "${PLAN_XML_A}" || { mark_aborted 'spazio insufficiente'; return 1; }

    log 'Pre-download RPM...'
    set +e
    DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive dup \
        "${ZYPPER_LICENSE_ARGS[@]}" --download-only --no-recommends --no-allow-vendor-change 2>&1 | tee "${DOWNLOAD_LOG}"
    rc=("${PIPESTATUS[@]}"); set -e
    (( rc[0] == 0 && rc[1] == 0 )) || { mark_aborted "pre-download/log fallito zypper=${rc[0]} tee=${rc[1]}"; return 1; }
    sync "${DOWNLOAD_LOG}" || { mark_aborted 'sync download log fallito'; return 1; }
    sync -f "${TX_PKG_CACHE}" || { mark_aborted 'sync cache RPM fallito'; return 1; }

    rpm_b="$(rpmdb_hash_host)"; zypp_b="$(zypp_semantic_hash)"
    [[ "${rpm_a}" == "${rpm_b}" && "${zypp_a}" == "${zypp_b}" ]] || { mark_aborted 'SOURCE/ZYpp cambiati durante pre-download'; return 1; }
    cache_b="$(pkg_cache_hash)" || { mark_aborted 'hash cache fallito'; return 1; }

    generate_xml_plan "${PLAN_XML_B}" || { mark_aborted 'piano XML B fallito'; return 1; }
    hash_b="$(plan_hash "${PLAN_XML_B}")" || { mark_aborted 'hash piano B fallito'; return 1; }
    [[ "${hash_a}" == "${hash_b}" ]] || { mark_aborted 'piano cambiato dopo download'; return 1; }
    extract_plan_operations "${PLAN_XML_B}" "${PLAN_OPS}" || { mark_aborted 'estrazione operazioni fallita'; return 1; }
    validate_plan_operation_count "${PLAN_XML_B}" "${PLAN_OPS}" || { mark_aborted 'conteggio operazioni incoerente'; return 1; }

    local has_installs
    has_installs="$(grep -cvE '^[[:space:]]*remove[[:space:]]' "${PLAN_OPS}" || true)"
    if (( has_installs > 0 )) && ! pkg_cache_has_rpms; then
        mark_aborted 'piano richiede pacchetti ma la cache RPM e vuota'
        return 1
    fi

    build_expected_manifest "${RPMDB_PRE_MANIFEST}" "${PLAN_OPS}" "${RPMDB_EXPECTED_MANIFEST}" || { mark_aborted 'manifest atteso fallito'; return 1; }
    sync "${RPMDB_PRE_MANIFEST}" "${RPMDB_EXPECTED_MANIFEST}" "${PLAN_OPS}" || { mark_aborted 'sync manifest fallito'; return 1; }

    if [[ ! -s "${PLAN_OPS}" ]]; then
        STATE_STATUS=confirmed; STATE_PLAN_HASH="${hash_b}"; STATE_RPMDB_HASH="${rpm_b}"; STATE_ZYPP_HASH="${zypp_b}"; STATE_CACHE_HASH="${cache_b}"; STATE_RPMDB_POST_HASH="${rpm_b}"; STATE_FINISHED="$(date -u +%FT%TZ)"; persist_state_or_die; history_or_warn plan-noop; log 'Nessun aggiornamento disponibile.'; return 0
    fi

    DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive dup \
        "${ZYPPER_LICENSE_ARGS[@]}" --dry-run --no-recommends --no-allow-vendor-change --details >"${PLAN_TXT}" || { mark_aborted 'dry-run leggibile fallito'; return 1; }

    [[ "$(active_snapshot)" == "${STATE_SOURCE}" && "$(default_snapshot)" == "${STATE_SOURCE}" ]] || { mark_aborted 'snapshot cambiata durante planning'; return 1; }
    STATE_STATUS=planned; STATE_PLAN_HASH="${hash_b}"; STATE_RPMDB_HASH="${rpm_b}"; STATE_ZYPP_HASH="${zypp_b}"; STATE_CACHE_HASH="${cache_b}"; STATE_LAST_ERROR=
    persist_state_or_die; history_or_warn planned "plan=${hash_b} cache=${cache_b}"; log "Piano stabile: ${hash_b}"
}

revalidate_plan() {
    [[ "${STATE_STATUS}" == planned ]] || return 1
    planned_is_fresh || return 1
    assert_toolchain_unchanged
    [[ "$(rpmdb_hash_host)" == "${STATE_RPMDB_HASH}" ]] || return 1
    [[ "$(zypp_semantic_hash)" == "${STATE_ZYPP_HASH}" ]] || return 1
    [[ "$(pkg_cache_hash)" == "${STATE_CACHE_HASH}" ]] || return 1
    generate_xml_plan "${PLAN_XML_FINAL}" || return 1
    local h
    local ops="${TX_CACHE_DIR}/plan-operations.revalidate.tsv"
    h="$(plan_hash "${PLAN_XML_FINAL}")" || return 1
    [[ "${h}" == "${STATE_PLAN_HASH}" ]] || return 1
    extract_plan_operations "${PLAN_XML_FINAL}" "${ops}" || return 1
    cmp -s -- "${PLAN_OPS}" "${ops}" || { rm -f -- "${ops}"; return 1; }
    rm -f -- "${ops}"
}

prepare_plan_for_upgrade() {
    local toolhash
    preflight update
    toolhash="${PREFLIGHT_TOOLCHAIN_HASH}"
    check_state_for_new
    if [[ "${STATE_STATUS}" == planned ]]; then
        [[ "${STATE_TOOLCHAIN_HASH}" == "${toolhash}" ]] && revalidate_plan && { log "Riutilizzo piano ${STATE_TXID}."; return 0; }
        mark_aborted 'piano esistente non piu riutilizzabile'
    fi
    make_plan 1
    load_state
}

parse_tukit_open_output() {
    local raw="$1"
    local line
    local count=0
    local candidate=
    while IFS= read -r line; do
        line="${line#${line%%[![:space:]]*}}"; line="${line%${line##*[![:space:]]}}"
        if [[ "${line}" =~ ^(ID:[[:space:]]*)?([0-9]+)$ ]]; then
            candidate="${BASH_REMATCH[2]}"
            ((count+=1))
        fi
    done <"${raw}"
    (( count == 1 )) || return 1
    printf '%s\n' "${candidate}"
}

same_boot() {
    local now
    [[ -n "${STATE_BOOT_ID_BEFORE}" ]] || return 1
    now="$(current_boot_id)" || return 1
    [[ "${now}" == "${STATE_BOOT_ID_BEFORE}" ]]
}

source_unchanged() {
    local r
    local e
    same_boot || return 1
    [[ "${STATE_SOURCE_OPEN_RPM_HASH}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "${STATE_SOURCE_OPEN_ETC_HASH}" =~ ^[0-9a-f]{64}$ ]] || return 1
    r="$(rpmdb_hash_host)" || return 1
    e="$(etc_tree_hash)" || return 1
    [[ "${r}" == "${STATE_SOURCE_OPEN_RPM_HASH}" ]] || return 1
    [[ "${e}" == "${STATE_SOURCE_OPEN_ETC_HASH}" ]]
}

assert_source_unchanged() {
    source_unchanged || die 'SOURCE cambiata o non verificabile dopo apertura TARGET.'
}

target_age_seconds() {
    local a
    local n
    a="$(date -u -d "${STATE_TARGET_OPENED}" +%s 2>/dev/null)" || return 1
    n="$(date -u +%s)"
    (( n >= a )) || return 1
    printf '%s\n' "$((n-a))"
}

target_window_valid() {
    local a
    a="$(target_age_seconds)" || return 1
    (( a <= TARGET_MAX_AGE_SECONDS ))
}