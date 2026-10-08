#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# mySlowrollOS guarded offline distribution upgrade v5.7.1
#
# Unico motore supportato: barriera REVALIDATED, TARGET offline e recovery fail-closed.
#
# SOURCE is never the RPM transaction root.  All package changes happen only
# inside the offline tukit TARGET.  Unknown outcomes never trigger blind cleanup.

readonly PROG="${0##*/}"
readonly PROGRAM_VERSION='5.7.1-guarded'
readonly STATE_VERSION=1
readonly STATE_DIR=/var/lib/myslowroll/atomic-update
readonly STATE_FILE="${STATE_DIR}/state"
readonly HISTORY_FILE="${STATE_DIR}/history.log"
readonly CACHE_ROOT=/var/cache/myslowroll-atomic-update
readonly LOG_ROOT=/var/log/myslowroll-atomic-update
readonly LOCK_FILE=/run/myslowroll-atomic-update.lock
readonly SNAPPER_CONFIG=root
readonly REQUIRED_OS_ID=opensuse-slowroll
# Identificatore persistente delle TARGET; indipendente dalla versione dello schema.
readonly TUKIT_DESCRIPTION_PREFIX='mySlowrollOS atomic-update'

readonly PLAN_MAX_AGE_SECONDS="${MYSLOWROLL_PLAN_MAX_AGE_SECONDS:-86400}"
readonly TARGET_MAX_AGE_SECONDS="${MYSLOWROLL_TARGET_MAX_AGE_SECONDS:-14400}"
readonly CACHE_MIN_MARGIN_BYTES="${MYSLOWROLL_CACHE_MIN_MARGIN_BYTES:-536870912}"
readonly ROOT_MIN_MARGIN_BYTES="${MYSLOWROLL_ROOT_MIN_MARGIN_BYTES:-1073741824}"
readonly BOOT_MIN_FREE_BYTES="${MYSLOWROLL_BOOT_MIN_FREE_BYTES:-134217728}"
readonly AUTO_AGREE_LICENSES="${MYSLOWROLL_AUTO_AGREE_LICENSES:-0}"
readonly AUTO_REBOOT="${MYSLOWROLL_AUTO_REBOOT:-1}"
readonly OPERATION_TIMEOUT="${MYSLOWROLL_OPERATION_TIMEOUT:-300}"

readonly -a CRITICAL_PKGS=(
    atomic-update criscore1 criscore2 btrfsprogs kernel-default rpm
    sdbootutil sdbootutil-kernel-install sdbootutil-snapper
    snapper systemd systemd-boot tukit zypper
)

readonly -a VALID_STATES=(
    planning planned revalidated opening target verified committing
    pending-reboot needs-inspection rollback-pending
    confirmed aborted rolled-back
)

STATE_STATUS=
STATE_TXID=
STATE_SOURCE=
STATE_TARGET=
STATE_BOOT_ID_BEFORE=
STATE_PLAN_HASH=
STATE_SOURCE_FINGERPRINT=
STATE_RPMDB_POST_HASH=
STATE_CREATED=
STATE_TARGET_OPENED=
STATE_LAST_ERROR=
STATE_INSPECTION_KIND=

TX_CACHE_DIR=
PLAN_TXT=
PLAN_XML_PREPARED=
PLAN_XML_REVALIDATED=
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
  check                       preflight completo, nessuna modifica
  plan                        refresh + pre-download + singolo PREPARED verificato
  upgrade                     PREPARED -> REVALIDATED -> TARGET -> verifica -> reboot
  confirm                     conferma dopo il reboot sul TARGET
  recover                     recovery fail-closed automatica
  recover inspect             diagnostica read-only
  recover abort-target N      abort tipizzato della TARGET N
  recover adopt-target N      adotta N solo se gia default e verificabile
  recover clear-opening       archivia open ambiguo solo senza TARGET registrata
  rollback [SNAPSHOT]         rollback esplicito e reboot
  status                      stato corrente
  prune [GIORNI]              elimina vecchi cache/log, mai snapshot

Gli esiti ambigui convergono in needs-inspection: recover applica solo
classificazioni dimostrabili; altrimenti richiede una recovery tipizzata.
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
               mktemp mv pgrep readlink rm sdbootutil sed sha256sum sleep snapper sort sync \
               systemctl timeout tr tukit; do
        command -v "${cmd}" >/dev/null 2>&1 || die "comando richiesto non trovato: ${cmd}"
    done
}

require_commands() {
    require_recovery_commands
    local cmd
    for cmd in cmp comm cp env find rpm systemd-inhibit tee xmllint zypper; do
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
    for name in PLAN_MAX_AGE_SECONDS TARGET_MAX_AGE_SECONDS CACHE_MIN_MARGIN_BYTES ROOT_MIN_MARGIN_BYTES BOOT_MIN_FREE_BYTES OPERATION_TIMEOUT; do
        value="${!name}"
        [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} deve essere un intero non negativo."
    done
    (( PLAN_MAX_AGE_SECONDS > 0 && TARGET_MAX_AGE_SECONDS > 0 && OPERATION_TIMEOUT > 0 )) ||
        die 'TTL piano/TARGET e OPERATION_TIMEOUT devono essere > 0.'

    case "${AUTO_AGREE_LICENSES}" in
        0|no|false|off) ZYPPER_LICENSE_ARGS=() ;;
        1|yes|true|on)  ZYPPER_LICENSE_ARGS=(--auto-agree-with-licenses) ;;
        *) die 'MYSLOWROLL_AUTO_AGREE_LICENSES non valido.' ;;
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
    PLAN_XML_PREPARED="${TX_CACHE_DIR}/dup-plan-prepared.xml"
    PLAN_XML_REVALIDATED="${TX_CACHE_DIR}/dup-plan-revalidated.xml"
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
    STATE_PLAN_HASH= STATE_SOURCE_FINGERPRINT= STATE_RPMDB_POST_HASH=
    STATE_CREATED= STATE_TARGET_OPENED= STATE_LAST_ERROR= STATE_INSPECTION_KIND=
    TX_CACHE_DIR= PLAN_TXT= PLAN_XML_PREPARED= PLAN_XML_REVALIDATED= DOWNLOAD_LOG=
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
            source_fingerprint) STATE_SOURCE_FINGERPRINT="${value}" ;;
            rpmdb_post_hash) STATE_RPMDB_POST_HASH="${value}" ;;
            created_utc) STATE_CREATED="${value}" ;;
            target_opened_utc) STATE_TARGET_OPENED="${value}" ;;
            last_error) STATE_LAST_ERROR="${value}" ;;
            inspection_kind) STATE_INSPECTION_KIND="${value}" ;;
            ''|'#'*) ;;
            *) die "chiave state sconosciuta: ${key}" ;;
        esac
    done < "${STATE_FILE}"

    (( seen_version == 1 )) || die 'state privo di versione.'
    [[ "${file_version}" == "${STATE_VERSION}" ]] || die "schema state ${file_version} non supportato."
    [[ -n "${STATE_STATUS}" ]] || die 'state privo di status.'

    state_value_valid "${STATE_STATUS}" || die "state sconosciuto: ${STATE_STATUS}"
    [[ -z "${STATE_TXID}" ]] || is_uuid "${STATE_TXID}" || die 'txid non valido.'
    [[ -z "${STATE_SOURCE}" || "${STATE_SOURCE}" =~ ^[0-9]+$ ]] || die 'SOURCE non valida.'
    [[ -z "${STATE_TARGET}" || "${STATE_TARGET}" =~ ^[0-9]+$ ]] || die 'TARGET non valida.'
    local h
    for h in STATE_PLAN_HASH STATE_SOURCE_FINGERPRINT STATE_RPMDB_POST_HASH; do
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
        printf 'source_fingerprint=%s\n' "${STATE_SOURCE_FINGERPRINT}"
        printf 'rpmdb_post_hash=%s\n' "${STATE_RPMDB_POST_HASH}"
        printf 'created_utc=%s\n' "${STATE_CREATED}"
        printf 'target_opened_utc=%s\n' "${STATE_TARGET_OPENED}"
        printf 'last_error=%s\n' "${safe}"
        printf 'inspection_kind=%s\n' "${STATE_INSPECTION_KIND}"
    } > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    sync "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${STATE_FILE}" || { rm -f -- "${tmp}"; return 1; }
    sync "${STATE_DIR}" || return 1
}

persist_state_or_die() { persist_state || die 'impossibile rendere persistente lo state; operazione fermata.'; }

hist_log() {
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
history_or_warn() { hist_log "$@" || warn 'history.log non aggiornabile; state resta autoritativo.'; }

mark_aborted() {
    warn "$1"
    STATE_STATUS=aborted
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

available_bytes() {
    local available
    available="$(LC_ALL=C df -B1 --output=avail -- "$1" 2>/dev/null | awk 'NR==2 && $1~/^[0-9]+$/ {print $1}')" || return 1
    [[ "${available}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${available}"
}

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
    # The intended host does not require the transactional-update package.
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

normalize_rpm_manifest() {
    # libzypp omits a zero epoch; RPM may explicitly report it as 0:.
    # Preserve nonzero epochs and use identical normalization for host/TARGET.
    LC_ALL=C sed -E '/^gpg-pubkey\|/d; s/^([^|]+\|)0:/\1/' | LC_ALL=C sort -u
}

write_rpm_manifest_host() {
    local out="$1"
    local tmp="${out}.tmp"
    LC_ALL=C rpm -qa --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}|%{ARCH}\n' | normalize_rpm_manifest > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${out}"
}

rpmdb_hash_host() {
    local tmp
    local h
    tmp="$(mktemp /run/myslowroll-rpmdb.XXXXXX)" || return 1
    if ! LC_ALL=C rpm -qa --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}|%{ARCH}\n' | normalize_rpm_manifest >"${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    h="$(sha256sum "${tmp}" | awk '{print $1}')"; rm -f -- "${tmp}"
    [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || return 1; printf '%s\n' "${h}"
}

zypp_semantic_hash() {
    {
        printf 'solver.onlyRequires=%s\n' "$(zypp_value solver.onlyRequires)"
        printf 'solver.dupAllowVendorChange=%s\n' "$(zypp_value solver.dupAllowVendorChange)"
        LC_ALL=C zypper --non-interactive lr -u -p 2>/dev/null
    } | sed -E 's/[[:space:]]+$//' | sha256sum | awk '{print $1}'
}


source_fingerprint() {
    local rpmh zypph
    rpmh="$(rpmdb_hash_host)" || return 1
    zypph="$(zypp_semantic_hash)" || return 1
    printf 'rpm=%s\nzypp=%s\n' "${rpmh}" "${zypph}" |
        sha256sum | awk '{print $1}'
}

pkg_cache_has_rpms() {
    [[ -d "${TX_PKG_CACHE}" ]] || return 1
    find "${TX_PKG_CACHE}" -type f -name '*.rpm' -print -quit | grep -q .
}

verify_cli_surface() {
    local th sv rh ch sub
    th="$(LC_ALL=C tukit --help 2>&1 || true)"
    sv="$(LC_ALL=C sdbootutil --help 2>&1 || true)"
    rh="$(LC_ALL=C sdbootutil remove-all-kernels --help 2>&1 || true)"
    ch="$(LC_ALL=C sdbootutil cleanup --help 2>&1 || true)"
    [[ -n "${th}" && -n "${sv}" && -n "${rh}" && -n "${ch}" ]] || return 1
    grep -Fq -- '--description' <<<"${th}" || return 1
    for sub in open call close abort; do
        grep -Eq "(^|[[:space:]])${sub}([[:space:]]|$)" <<<"${th}" || return 1
    done
    for sub in add-all-kernels is-bootable remove-all-kernels cleanup; do
        grep -Eq "(^|[[:space:]])${sub}([[:space:]]|$)" <<<"${sv}" || return 1
    done
    grep -Fq -- '--disable-predictions' <<<"${rh}" || return 1
    grep -Fq -- '--disable-predictions' <<<"${ch}" || return 1
    return 0
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
    hash="$(LC_ALL=C xmllint --c14n "${tmp}" 2>/dev/null | sha256sum | awk '{print $1}')" || { rm -f -- "${tmp}"; return 1; }
    rm -f -- "${tmp}"
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

    local cache_uuid
    local root_uuid
    cache_uuid="$(findmnt -n -o UUID --target "${TX_PKG_CACHE}" 2>/dev/null)" || return 1
    root_uuid="$(findmnt -n -o UUID --target / 2>/dev/null)" || return 1
    [[ -n "${cache_uuid}" && -n "${root_uuid}" ]] || {
        warn 'UUID filesystem cache/root non determinabile: spazio condiviso non verificabile.'
        return 1
    }

    if [[ "${cache_uuid}" == "${root_uuid}" ]]; then
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
    local p a d
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

    # Recovery uses a reduced structural preflight so diagnosis/cleanup can
    # operate even when update-only policy or boot-space checks fail.
    # Confirm separately validates the booted TARGET, OS and RPM manifest.
    if [[ "${mode}" == update ]]; then
        check_boot_space || die 'spazio boot insufficiente/non determinabile.'
    fi

    verify_cli_surface || die 'CLI tukit/sdbootutil incompatibile.'

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
        planned|revalidated) return 0 ;;
        *) die "transazione ${STATE_TXID:-?} in stato ${STATE_STATUS}; usare recover/status prima di continuare." ;;
    esac
}

make_plan() {
    local already_locked="${1:-0}"
    local source_before source_after planh rpm_post a d
    local cache_avail root_avail has_installs
    local -a rc

    if (( already_locked == 0 )); then
        preflight
        check_state_for_new
    fi

    a="$(active_snapshot)"; d="$(default_snapshot)"
    [[ "${a}" == "${d}" ]] || die 'active/default cambiati durante preflight.'
    if [[ "${STATE_STATUS}" == planned || "${STATE_STATUS}" == revalidated ]]; then
        mark_aborted 'piano precedente sostituito'
    fi

    reset_state
    STATE_TXID="$(new_txid)"
    STATE_CREATED="$(date -u +%FT%TZ)"
    STATE_STATUS=planning
    STATE_SOURCE="${a}"
    set_tx_paths
    install -d -o root -g root -m 0700 "${STATE_DIR}" "${TX_CACHE_DIR}" "${TX_PKG_CACHE}" "${LOG_ROOT}" ||
        die 'creazione directory transazione fallita.'
    persist_state_or_die
    history_or_warn planning-started

    log 'Refresh repository...'
    zypper --non-interactive refresh || { mark_aborted 'refresh fallito'; return 1; }

    write_rpm_manifest_host "${RPMDB_PRE_MANIFEST}" ||
        { mark_aborted 'manifest RPM pre fallito'; return 1; }
    source_before="$(source_fingerprint)" ||
        { mark_aborted 'fingerprint SOURCE pre fallita'; return 1; }

    # Cheap margins before downloading.  Exact requirements are checked once,
    # against the canonical PREPARED plan generated after pre-download.
    cache_avail="$(available_bytes "${TX_PKG_CACHE}")" || { mark_aborted 'spazio cache non determinabile'; return 1; }
    root_avail="$(available_bytes /)" || { mark_aborted 'spazio root non determinabile'; return 1; }
    (( cache_avail >= CACHE_MIN_MARGIN_BYTES && root_avail >= ROOT_MIN_MARGIN_BYTES )) ||
        { mark_aborted 'margine minimo cache/root insufficiente prima del download'; return 1; }

    log 'Pre-download RPM...'
    set +e
    DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive dup         "${ZYPPER_LICENSE_ARGS[@]}" --download-only --no-recommends --no-allow-vendor-change 2>&1 | tee "${DOWNLOAD_LOG}"
    rc=("${PIPESTATUS[@]}")
    set -e
    (( rc[0] == 0 && rc[1] == 0 )) ||
        { mark_aborted "pre-download/log fallito zypper=${rc[0]} tee=${rc[1]}"; return 1; }
    sync "${DOWNLOAD_LOG}" || { mark_aborted 'sync download log fallito'; return 1; }
    sync -f "${TX_PKG_CACHE}" || { mark_aborted 'sync cache RPM fallito'; return 1; }

    source_after="$(source_fingerprint)" ||
        { mark_aborted 'fingerprint SOURCE post-download fallita'; return 1; }
    [[ "${source_before}" == "${source_after}" ]] ||
        { mark_aborted 'SOURCE/ZYpp cambiati durante pre-download'; return 1; }

    # One canonical PREPARED solver result.
    generate_xml_plan "${PLAN_XML_PREPARED}" ||
        { mark_aborted 'piano PREPARED fallito'; return 1; }
    scan_plan_for_critical_removals "${PLAN_XML_PREPARED}" ||
        { mark_aborted 'rimozioni critiche nel piano'; return 1; }
    planh="$(plan_hash "${PLAN_XML_PREPARED}")" ||
        { mark_aborted 'hash piano PREPARED fallito'; return 1; }
    check_plan_space "${PLAN_XML_PREPARED}" ||
        { mark_aborted 'spazio insufficiente'; return 1; }
    extract_plan_operations "${PLAN_XML_PREPARED}" "${PLAN_OPS}" ||
        { mark_aborted 'estrazione operazioni fallita'; return 1; }
    validate_plan_operation_count "${PLAN_XML_PREPARED}" "${PLAN_OPS}" ||
        { mark_aborted 'conteggio operazioni incoerente'; return 1; }

    has_installs="$(grep -cvE '^[[:space:]]*remove[[:space:]]' "${PLAN_OPS}" || true)"
    if (( has_installs > 0 )) && ! pkg_cache_has_rpms; then
        mark_aborted 'piano richiede pacchetti ma la cache RPM e vuota'
        return 1
    fi

    build_expected_manifest "${RPMDB_PRE_MANIFEST}" "${PLAN_OPS}" "${RPMDB_EXPECTED_MANIFEST}" ||
        { mark_aborted 'manifest atteso fallito'; return 1; }
    sync "${RPMDB_PRE_MANIFEST}" "${RPMDB_EXPECTED_MANIFEST}" "${PLAN_OPS}" ||
        { mark_aborted 'sync manifest fallito'; return 1; }

    if [[ ! -s "${PLAN_OPS}" ]]; then
        rpm_post="$(sha256sum "${RPMDB_PRE_MANIFEST}" | awk '{print $1}')"
        STATE_STATUS=confirmed
        STATE_PLAN_HASH="${planh}"
        STATE_SOURCE_FINGERPRINT="${source_after}"
        STATE_RPMDB_POST_HASH="${rpm_post}"
        persist_state_or_die
        history_or_warn plan-noop
        log 'Nessun aggiornamento disponibile.'
        return 0
    fi

    DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive dup         "${ZYPPER_LICENSE_ARGS[@]}" --dry-run --no-recommends --no-allow-vendor-change --details >"${PLAN_TXT}" ||
        { mark_aborted 'dry-run leggibile fallito'; return 1; }

    [[ "$(active_snapshot)" == "${STATE_SOURCE}" && "$(default_snapshot)" == "${STATE_SOURCE}" ]] ||
        { mark_aborted 'snapshot cambiata durante planning'; return 1; }

    STATE_STATUS=planned
    STATE_PLAN_HASH="${planh}"
    STATE_SOURCE_FINGERPRINT="${source_after}"
    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn planned "plan=${planh} source=${source_after}"
    log "Piano PREPARED stabile: ${planh}"
}


revalidate_plan() {
    local h ops source_now
    [[ "${STATE_STATUS}" == planned ]] || return 1
    planned_is_fresh || return 1
    verify_cli_surface || return 1
    [[ "${STATE_SOURCE_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]] || return 1

    source_now="$(source_fingerprint)" || return 1
    [[ "${source_now}" == "${STATE_SOURCE_FINGERPRINT}" ]] || return 1

    # Current repository metadata is authoritative at execution time.
    zypper --non-interactive refresh >/dev/null || return 1
    source_now="$(source_fingerprint)" || return 1
    [[ "${source_now}" == "${STATE_SOURCE_FINGERPRINT}" ]] || return 1

    generate_xml_plan "${PLAN_XML_REVALIDATED}" || return 1
    scan_plan_for_critical_removals "${PLAN_XML_REVALIDATED}" || return 1
    h="$(plan_hash "${PLAN_XML_REVALIDATED}")" || return 1
    [[ "${h}" == "${STATE_PLAN_HASH}" ]] || return 1

    ops="${TX_CACHE_DIR}/plan-operations.revalidate.tsv"
    extract_plan_operations "${PLAN_XML_REVALIDATED}" "${ops}" || return 1
    cmp -s -- "${PLAN_OPS}" "${ops}" || { rm -f -- "${ops}"; return 1; }
    rm -f -- "${ops}"

    # The solver result is unchanged; make the package cache complete again
    # before any TARGET exists. This avoids persisting a fragile cache hash.
    DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive dup         "${ZYPPER_LICENSE_ARGS[@]}" --download-only --no-recommends --no-allow-vendor-change >/dev/null ||
        return 1
    sync -f "${TX_PKG_CACHE}" || return 1

    source_now="$(source_fingerprint)" || return 1
    [[ "${source_now}" == "${STATE_SOURCE_FINGERPRINT}" ]]
}


prepare_plan_for_upgrade() {
    local source_now
    preflight update
    check_state_for_new
    if [[ "${STATE_STATUS}" == revalidated ]]; then
        # Crash between REVALIDATED and tukit open: no TARGET exists yet.
        # Return to PREPARED. The single full revalidation is performed only
        # after the user explicitly confirms the upgrade.
        STATE_STATUS=planned
        STATE_LAST_ERROR='REVALIDATED interrotto prima di tukit open; richiesta nuova revalidation'
        persist_state_or_die
    fi
    if [[ "${STATE_STATUS}" == planned ]]; then
        source_now="$(source_fingerprint || true)"
        if planned_is_fresh             && [[ "${source_now}" =~ ^[0-9a-f]{64}$ ]]             && [[ "${source_now}" == "${STATE_SOURCE_FINGERPRINT}" ]]; then
            log "Riutilizzo piano PREPARED ${STATE_TXID}; REVALIDATED verra eseguito dopo la conferma."
            return 0
        fi
        mark_aborted 'piano PREPARED non piu riutilizzabile'
    fi
    make_plan 1
    load_state
}

find_owned_targets() {
    local line number description wanted listing
    wanted="${1:-${TUKIT_DESCRIPTION_PREFIX} ${STATE_TXID}}"
    listing="$(LC_ALL=C snapper --csvout --no-headers -c "${SNAPPER_CONFIG}" \
        list --disable-used-space --columns number,description)" || return 1
    while IFS= read -r line; do
        line="${line//\"/}"
        number="${line%%,*}"
        description="${line#*,}"
        number="${number//[[:space:]]/}"
        description="${description#${description%%[![:space:]]*}}"
        description="${description%${description##*[![:space:]]}}"
        [[ "${number}" =~ ^[0-9]+$ ]] || continue
        if [[ "${description}" == "${wanted}" ]]; then
            printf '%s\n' "${number}" || return 1
        fi
    done <<<"${listing}"
    return 0
}

resolve_owned_target() {
    local matching
    local -a found=()
    matching="$(find_owned_targets)" || return 1
    [[ -n "${matching}" ]] || return 1
    mapfile -t found <<<"${matching}"
    (( ${#found[@]} == 1 )) || return 1
    printf '%s\n' "${found[0]}"
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
    same_boot || return 1
    [[ "${STATE_SOURCE_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(source_fingerprint)" == "${STATE_SOURCE_FINGERPRINT}" ]] || return 1
    [[ "$(active_snapshot)" == "${STATE_SOURCE}" ]] || return 1
    [[ "$(default_snapshot)" == "${STATE_SOURCE}" ]] || return 1
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

tukit_call() { local t="$1"; shift; tukit call "${t}" "$@"; }

open_target() {
    local target

    [[ "${STATE_STATUS}" == revalidated ]] ||
        die 'tukit open rifiutato: barriera REVALIDATED non persistita.'

    STATE_STATUS=opening
    STATE_TARGET=
    STATE_BOOT_ID_BEFORE="$(current_boot_id)"
    STATE_LAST_ERROR=
    persist_state_or_die

    : >"${TUKIT_OPEN_LOG}"
    chmod 0600 "${TUKIT_OPEN_LOG}"

    if ! timeout --signal=TERM --kill-after=10 "${OPERATION_TIMEOUT}"         tukit --description "${TUKIT_DESCRIPTION_PREFIX} ${STATE_TXID}" open         >"${TUKIT_OPEN_LOG}" 2>&1; then
        STATE_STATUS=needs-inspection
        STATE_INSPECTION_KIND=open-ambiguous
        STATE_LAST_ERROR="tukit open failed/timed out; inspect ${TUKIT_OPEN_LOG}"
        persist_state_or_die
        return 1
    fi
    sync "${TUKIT_OPEN_LOG}" || true

    if ! target="$(parse_tukit_open_output "${TUKIT_OPEN_LOG}")"; then
        # CLI wording may change.  Recover identity only from the exact
        # transaction description; never guess from arbitrary numbers.
        if target="$(resolve_owned_target)"; then
            log "TARGET ${target} recuperata dalla descrizione tukit."
        else
            STATE_STATUS=needs-inspection
            STATE_INSPECTION_KIND=open-ambiguous
            STATE_LAST_ERROR="tukit open output non parseabile e ownership non univoca; inspect ${TUKIT_OPEN_LOG}"
            persist_state_or_die
            return 1
        fi
    fi

    STATE_TARGET="${target}"
    local a d
    a="$(active_snapshot)"
    d="$(default_snapshot)"
    if ! snapshot_exists "${target}" ||
       ! snapshot_is_rw "${target}" ||
       [[ "${target}" == "${STATE_SOURCE}" ]] ||
       [[ "${target}" == "${a}" ]] ||
       [[ "${a}" != "${STATE_SOURCE}" ]] ||
       [[ "${d}" != "${STATE_SOURCE}" ]]; then
        STATE_STATUS=needs-inspection
        STATE_INSPECTION_KIND=post-open-invariants
        STATE_LAST_ERROR="post-open invariants failed: source=${STATE_SOURCE} active=${a:-?} default=${d:-?} target=${target}"
        persist_state_or_die
        return 1
    fi

    STATE_TARGET_OPENED="$(date -u +%FT%TZ)"
    STATE_STATUS=target
    STATE_LAST_ERROR=
    persist_state_or_die

    if ! source_unchanged; then
        STATE_LAST_ERROR='SOURCE cambiata tra PREPARED e apertura TARGET'
        persist_state_or_die
        return 1
    fi

    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn target-opened "target=${target}"
}

write_target_manifest() {
    local t="$1"
    local out="$2"
    local tmp="${out}.tmp"
    if ! LC_ALL=C tukit_call "${t}" rpm -qa --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}|%{ARCH}\n' | normalize_rpm_manifest >"${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${out}"
}

target_cache_visible() { tukit_call "$1" sh -c 'test -d "$1" && test -r "$1" && test -w "$1"' sh "$2"; }


run_target_dup() {
    local t="$1"
    local zrc trc zok=0
    local -a rc

    [[ "${STATE_STATUS}" == target ]] || return 1
    if ! verify_cli_surface; then
        STATE_LAST_ERROR='capability tukit/sdbootutil non disponibile prima del dup'
        persist_state_or_die
        return 1
    fi
    if ! source_unchanged; then
        STATE_LAST_ERROR='SOURCE cambiata o non verificabile prima del dup'
        persist_state_or_die
        return 1
    fi
    if ! target_window_valid; then
        STATE_LAST_ERROR='finestra TARGET scaduta o non determinabile prima del dup'
        persist_state_or_die
        return 1
    fi
    if ! target_cache_visible "${t}" "${TX_PKG_CACHE}"; then
        STATE_LAST_ERROR='cache pre-validata non visibile/scrivibile nella TARGET'
        persist_state_or_die
        return 1
    fi
    check_zypp_lock_hint || { STATE_LAST_ERROR='ZYpp concorrente rilevato prima del dup TARGET'; persist_state_or_die; return 1; }
    check_conflicting_update_units_idle || { STATE_LAST_ERROR='unita update in conflitto prima del dup TARGET'; persist_state_or_die; return 1; }
    : >"${DUP_LOG}" && chmod 0600 "${DUP_LOG}" || { STATE_LAST_ERROR='impossibile preparare il log dup'; persist_state_or_die; return 1; }

    STATE_LAST_ERROR=
    persist_state_or_die
    sync || { STATE_LAST_ERROR='sync barrier fallita prima del dup TARGET'; persist_state_or_die; return 1; }

    set +e
    systemd-inhibit --what=shutdown:sleep:idle --mode=block --who="${PROG}" --why='mySlowrollOS offline target update'       tukit call "${t}" env DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C       zypper --pkg-cache-dir "${TX_PKG_CACHE}" --no-refresh --non-interactive --userdata "myslowroll-atomic-update:${STATE_TXID}" dup         "${ZYPPER_LICENSE_ARGS[@]}" --download-in-advance --no-recommends --no-allow-vendor-change 2>&1 | tee "${DUP_LOG}"
    rc=("${PIPESTATUS[@]}")
    set -e

    zrc="${rc[0]}"; trc="${rc[1]}"
    sync "${DUP_LOG}" || trc=125
    case "${zrc}" in
        0) zok=1 ;;
        102|103)
            zok=1
            log "zypper rc=${zrc}: procedo solo alla verifica completa della TARGET."
            ;;
    esac

    if (( zok == 0 || trc != 0 )); then
        STATE_LAST_ERROR="target dup failed: zypper=${zrc} tee/sync=${trc}"
        persist_state_or_die
        history_or_warn target-update-failed "${STATE_LAST_ERROR}"
        return 1
    fi

    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn target-updated "zypper_rc=${zrc}"
}

verify_target_packages() { tukit_call "$1" rpm --quiet -q "${CRITICAL_PKGS[@]}"; }


verify_target() {
    local t="$1"
    [[ "${STATE_STATUS}" == target ]] || return 1
    STATE_LAST_ERROR=
    persist_state_or_die

    : >"${POSTCHECK_LOG}" && chmod 0600 "${POSTCHECK_LOG}" ||
        { STATE_LAST_ERROR='impossibile preparare il log verifiche TARGET'; persist_state_or_die; return 1; }

    verify_cli_surface ||
        { STATE_LAST_ERROR='capability tukit/sdbootutil non disponibile durante verify'; persist_state_or_die; return 1; }
    source_unchanged ||
        { STATE_LAST_ERROR='SOURCE cambiata o non verificabile durante verify'; persist_state_or_die; return 1; }
    target_window_valid ||
        { STATE_LAST_ERROR='finestra TARGET scaduta o non determinabile durante verify'; persist_state_or_die; return 1; }

    snapshot_exists "${t}" && snapshot_is_rw "${t}" ||
        { STATE_LAST_ERROR='TARGET missing/not RW'; persist_state_or_die; return 1; }
    write_target_manifest "${t}" "${RPMDB_POST_MANIFEST}" ||
        { STATE_LAST_ERROR='target manifest failed'; persist_state_or_die; return 1; }
    STATE_RPMDB_POST_HASH="$(sha256sum "${RPMDB_POST_MANIFEST}" | awk '{print $1}')" || return 1
    [[ "${STATE_RPMDB_POST_HASH}" =~ ^[0-9a-f]{64}$ ]] ||
        { STATE_LAST_ERROR='target manifest hash failed'; persist_state_or_die; return 1; }
    cmp -s -- "${RPMDB_EXPECTED_MANIFEST}" "${RPMDB_POST_MANIFEST}" ||
        { STATE_LAST_ERROR='target RPM manifest differs from expected solver result'; persist_state_or_die; return 1; }
    verify_target_packages "${t}" ||
        { STATE_LAST_ERROR='critical package missing in TARGET'; persist_state_or_die; return 1; }
    [[ "$(tukit_call "${t}" awk -F= '$1=="ID"{gsub(/^"|"$/,"",$2);print $2;exit}' /usr/lib/os-release)" == "${REQUIRED_OS_ID}" ]] ||
        { STATE_LAST_ERROR='TARGET OS ID invalid'; persist_state_or_die; return 1; }

    # Bootability is checked once at the actual pre-commit boundary.
    # Avoid repeating the same sdbootutil invariant during package verification.
    source_unchanged ||
        { STATE_LAST_ERROR='SOURCE changed during TARGET verification'; persist_state_or_die; return 1; }

    STATE_STATUS=verified
    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn target-verified "rpm=${STATE_RPMDB_POST_HASH}"
}

remove_target_boot_entries() {
    local t="$1"
    local rc=0
    local cmd_rc
    [[ "${t}" =~ ^[0-9]+$ ]] || return 1
    [[ "$(active_snapshot)" != "${t}" && "$(default_snapshot)" != "${t}" ]] || return 1
    install -d -o root -g root -m 0700 "${LOG_ROOT}" || return 1
    (
        if LC_ALL=C sdbootutil remove-all-kernels --disable-predictions "${t}"; then
            printf 'remove-all-kernels_rc=0\n'
        else
            cmd_rc=$?; printf 'remove-all-kernels_rc=%s\n' "${cmd_rc}"; rc="${cmd_rc}"
        fi
        if LC_ALL=C sdbootutil cleanup --disable-predictions "${t}"; then
            printf 'cleanup_rc=0\n'
        else
            cmd_rc=$?; printf 'cleanup_rc=%s\n' "${cmd_rc}"; (( rc != 0 )) || rc="${cmd_rc}"
        fi
        exit "${rc}"
    ) >>"${SDBOOT_LOG}" 2>&1
}

target_quiescent() {
    local t="$1"
    local target_path p root cwd
    [[ "${t}" =~ ^[0-9]+$ ]] || return 1
    [[ "$(active_snapshot)" != "${t}" && "$(default_snapshot)" != "${t}" ]] || return 1
    snapshot_exists "${t}" || return 0
    target_path="$(snapshot_path "${t}")"

    # Strong local proof: no live process may have root/cwd inside TARGET.
    for p in /proc/[0-9]*; do
        root="$(readlink -f "${p}/root" 2>/dev/null || true)"
        cwd="$(readlink -f "${p}/cwd" 2>/dev/null || true)"
        [[ "${root}" == "${target_path}" || "${root}" == "${target_path}/"* ]] && return 1
        [[ "${cwd}" == "${target_path}" || "${cwd}" == "${target_path}/"* ]] && return 1
    done

    # Additional transaction-specific guard.  A match means "not proven quiet".
    if pgrep -af '(zypper|rpm|tukit)' 2>/dev/null |
       grep -E -- "(${STATE_TXID}|${TUKIT_DESCRIPTION_PREFIX}[[:space:]]+${STATE_TXID}|snapshot[ =:]*${t})"        >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

abort_target_safe() {
    local t="$1"
    local a d a_after d_after rc cleanup_detail=ok
    [[ "${t}" =~ ^[0-9]+$ ]] || return 1
    a="$(active_snapshot)"; d="$(default_snapshot)"
    [[ -n "${a}" && -n "${d}" ]] || return 1
    [[ "${t}" != "${a}" && "${t}" != "${d}" ]] || return 1

    if snapshot_exists "${t}"; then
        if ! target_quiescent "${t}"; then
            STATE_STATUS=needs-inspection
            STATE_INSPECTION_KIND=target-not-quiescent
            STATE_LAST_ERROR="TARGET ${t} non dimostrabilmente quiescente; abort vietato"
            persist_state_or_die
            return 1
        fi

        set +e
        timeout --signal=TERM --kill-after=10 "${OPERATION_TIMEOUT}" tukit abort "${t}"
        rc=$?
        set -e
        if (( rc != 0 )); then
            STATE_STATUS=needs-inspection
            STATE_INSPECTION_KIND=abort-ambiguous
            STATE_LAST_ERROR="tukit abort ${t} fallito/timeout rc=${rc}; non riprovare alla cieca"
            persist_state_or_die
            return 1
        fi
    else
        # Crash after a successful abort but before state persistence:
        # do not repeat tukit abort. Accept only when SOURCE is still active/default.
        if [[ "${a}" != "${STATE_SOURCE}" || "${d}" != "${STATE_SOURCE}" ]]; then
            STATE_STATUS=needs-inspection
            STATE_INSPECTION_KIND=abort-ambiguous
            STATE_LAST_ERROR="TARGET ${t} assente, ma active/default non coincidono con SOURCE"
            persist_state_or_die
            return 1
        fi
        history_or_warn target-already-absent "target=${t}"
    fi

    a_after="$(active_snapshot)"; d_after="$(default_snapshot)"
    if snapshot_exists "${t}" || [[ "${a_after}" != "${a}" ]] || [[ "${d_after}" != "${d}" ]]; then
        STATE_STATUS=needs-inspection
        STATE_INSPECTION_KIND=abort-ambiguous
        STATE_LAST_ERROR="abort TARGET ${t} non verificabile: active=${a_after:-?}/${a:-?} default=${d_after:-?}/${d:-?}"
        persist_state_or_die
        return 1
    fi

    # Boot cleanup is permitted only after TARGET absence is proved.
    if ! remove_target_boot_entries "${t}"; then
        cleanup_detail=failed
        warn "TARGET ${t} assente; cleanup boot incompleto (best-effort)."
    fi
    STATE_STATUS=aborted
    STATE_INSPECTION_KIND=
    if [[ "${cleanup_detail}" == failed ]]; then
        STATE_LAST_ERROR="TARGET ${t} assente; cleanup boot incompleto, SOURCE intatta"
    else
        STATE_LAST_ERROR=
    fi
    persist_state_or_die
    history_or_warn target-aborted "target=${t} boot-cleanup=${cleanup_detail}"
}

precommit_target_valid() {
    local t="$1"
    [[ "${STATE_STATUS}" == verified ]] || return 1
    verify_cli_surface || return 1
    source_unchanged || return 1
    target_window_valid || return 1
    [[ "$(active_snapshot)" == "${STATE_SOURCE}" ]] || return 1
    [[ "$(default_snapshot)" == "${STATE_SOURCE}" ]] || return 1
    snapshot_is_bootable "${STATE_SOURCE}" || return 1
    ensure_snapshot_bootable "${t}" || return 1
    source_unchanged || return 1
    return 0
}

verified_target_evidence() {
    # A staged/default TARGET is adoptable only if the prior verified
    # manifest is intact and the TARGET still matches it exactly.
    local t="$1" owned observed rc
    [[ "${t}" =~ ^[0-9]+$ && "${STATE_PLAN_HASH}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "${STATE_RPMDB_POST_HASH}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -s "${RPMDB_POST_MANIFEST}" && -s "${RPMDB_EXPECTED_MANIFEST}" ]] || return 1
    [[ "$(sha256sum "${RPMDB_POST_MANIFEST}" | awk '{print $1}')" == "${STATE_RPMDB_POST_HASH}" ]] || return 1
    cmp -s -- "${RPMDB_EXPECTED_MANIFEST}" "${RPMDB_POST_MANIFEST}" || return 1
    snapshot_exists "${t}" && snapshot_is_rw "${t}" || return 1
    [[ "$(snapshot_os_id "${t}")" == "${REQUIRED_OS_ID}" ]] || return 1
    owned="$(resolve_owned_target)" || return 1
    [[ "${owned}" == "${t}" ]] || return 1

    observed="$(mktemp "${TX_CACHE_DIR}/.recover-rpm.XXXXXX")" || return 1
    if [[ "$(active_snapshot)" == "${t}" ]]; then
        rpm --quiet -q "${CRITICAL_PKGS[@]}" || { rm -f -- "${observed}"; return 1; }
        write_rpm_manifest_host "${observed}" || { rm -f -- "${observed}"; return 1; }
    else
        verify_target_packages "${t}" || { rm -f -- "${observed}"; return 1; }
        write_target_manifest "${t}" "${observed}" || { rm -f -- "${observed}"; return 1; }
    fi
    rc=0
    cmp -s -- "${RPMDB_POST_MANIFEST}" "${observed}" || rc=1
    rm -f -- "${observed}"
    (( rc == 0 ))
}

commit_target() {
    local t="$1"
    local rc

    if ! precommit_target_valid "${t}"; then
        STATE_LAST_ERROR='pre-commit invariants failed'
        persist_state_or_die
        return 2
    fi

    STATE_STATUS=committing
    STATE_INSPECTION_KIND=
    STATE_LAST_ERROR=
    persist_state_or_die
    if ! sync; then
        STATE_STATUS=needs-inspection
        STATE_INSPECTION_KIND=pre-close-sync-failed
        STATE_LAST_ERROR='sync barrier failed before tukit close'
        persist_state_or_die
        return 1
    fi

    set +e
    timeout --signal=TERM --kill-after=10 "${OPERATION_TIMEOUT}" tukit close "${t}"
    rc=$?
    set -e
    if (( rc != 0 )); then
        # close may have changed the default before returning/timing out.
        # Never infer "not committed" from the return code alone.
        STATE_STATUS=needs-inspection
        STATE_INSPECTION_KIND=close-ambiguous
        STATE_LAST_ERROR="tukit close failed/timed out rc=${rc}; classify observed default before any cleanup"
        persist_state_or_die
        return 1
    fi

    if [[ "$(default_snapshot)" != "${t}" ]] ||
       ! snapshot_is_rw "${t}"; then
        STATE_STATUS=needs-inspection
        STATE_INSPECTION_KIND=close-postcondition
        STATE_LAST_ERROR='tukit close returned success but default/RW postconditions failed'
        persist_state_or_die
        return 1
    fi

    STATE_STATUS=pending-reboot
    STATE_INSPECTION_KIND=
    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn pending-reboot "target=${t}"
}

reboot_or_finish() {
    local reason="${1:-upgrade}"
    if bool_true "${AUTO_REBOOT}"; then
        case "${reason}" in
            rollback) log 'Rollback preparato con successo. Avvio del reboot...' ;;
            *)        log 'Upgrade verificato con successo. Avvio del reboot...' ;;
        esac
        sync
        systemctl reboot || die 'reboot automatico fallito; non modificare la root ed eseguire reboot manuale.'
        while sleep 60; do :; done
    else
        case "${reason}" in
            rollback) log "Rollback preparato: TARGET ${STATE_TARGET} e default. Riavviare senza fare manutenzione intermedia." ;;
            *)        log "Upgrade verificato: TARGET ${STATE_TARGET} e default. Riavviare senza fare manutenzione intermedia." ;;
        esac
    fi
}

upgrade() {
    local answer
    prepare_plan_for_upgrade
    [[ "${STATE_STATUS}" == confirmed ]] && { log 'Nessun aggiornamento da applicare.'; return 0; }
    [[ "${STATE_STATUS}" == planned ]] || die 'piano non disponibile.'

    printf '\n=======================================================\n'
    printf 'RIASSUNTO PIANO AGGIORNAMENTO (%s)\n' "${STATE_TXID}"
    printf '=======================================================\n'
    if [[ -s "${PLAN_TXT}" ]]; then
        head -n 25 "${PLAN_TXT}"
        printf '... [Piano completo disponibile in: %s]\n' "${PLAN_TXT}"
    else
        printf 'Operazioni previste: %s pacchetti da modificare.\n' "$(awk 'END{print NR}' "${PLAN_OPS}")"
    fi
    printf '=======================================================\n'
    printf 'SOURCE: %s | I pacchetti saranno installati solo nella snapshot TARGET.\n' "${STATE_SOURCE}"
    printf 'Scrivi esattamente: AGGIORNA OFFLINE E RIAVVIA\n> '
    IFS= read -r answer || die 'EOF: nessuna TARGET creata.'
    [[ "${answer}" == 'AGGIORNA OFFLINE E RIAVVIA' ]] || die 'upgrade annullato.'

    revalidate_plan || { mark_aborted 'piano cambiato prima di tukit open'; die 'piano non piu valido.'; }
    [[ "$(active_snapshot)" == "${STATE_SOURCE}" && "$(default_snapshot)" == "${STATE_SOURCE}" ]] || { mark_aborted 'SOURCE cambiata prima di open'; die 'SOURCE cambiata.'; }

    # Durable boundary: after this write, a crash is distinguishable from an
    # ambiguous tukit open.  No TARGET exists yet.
    STATE_STATUS=revalidated
    STATE_LAST_ERROR=
    STATE_INSPECTION_KIND=
    persist_state_or_die
    history_or_warn revalidated "plan=${STATE_PLAN_HASH}"

    if ! open_target; then
        load_state
        if [[ "${STATE_STATUS}" == target && "${STATE_TARGET}" =~ ^[0-9]+$ ]]; then
            if abort_target_safe "${STATE_TARGET}"; then
                die 'post-open TARGET fallito; TARGET abortita, SOURCE invariata.'
            fi
            die 'post-open TARGET fallito e abort automatico non riuscito; usare recover.'
        fi
        die "tukit open ambiguo: stato needs-inspection; NON riprovare automaticamente. Usare '${PROG} recover inspect'."
    fi
    load_state
    if ! run_target_dup "${STATE_TARGET}"; then
        if abort_target_safe "${STATE_TARGET}"; then die 'dup TARGET fallito; TARGET abortita, SOURCE invariata.'; fi
        die 'dup TARGET fallito e abort automatico non sicuro; recovery manuale richiesta.'
    fi
    if ! verify_target "${STATE_TARGET}"; then
        if abort_target_safe "${STATE_TARGET}"; then die 'verifica TARGET fallita; TARGET abortita, SOURCE invariata.'; fi
        die 'verifica TARGET fallita e abort automatico non sicuro; recovery manuale richiesta.'
    fi
    local commit_rc
    if commit_target "${STATE_TARGET}"; then
        :
    else
        commit_rc=$?
        if (( commit_rc == 2 )); then
            if abort_target_safe "${STATE_TARGET}"; then
                die 'controlli pre-commit falliti; TARGET abortita, SOURCE invariata.'
            fi
            die 'controlli pre-commit falliti e TARGET non abortibile automaticamente; usare recover.'
        fi
        die "commit ambiguo. NON abortire alla cieca; eseguire '${PROG} recover'."
    fi
    reboot_or_finish upgrade
}

confirm_manifest_delta_allowed() {
    # $1 = manifest verificato sulla TARGET, $2 = manifest osservato dopo il reboot.
    # Ammesso SOLO: nessuna riga aggiunta; ogni riga rimossa appartiene a un
    # pacchetto kernel-* di cui resta installata un'altra versione.
    local post="$1"
    local now="$2"
    local added removed line name
    added="$(LC_ALL=C comm -13 "${post}" "${now}")" || return 1
    if [[ -n "${added}" ]]; then
        warn 'dopo il reboot risultano pacchetti nuovi/cambiati rispetto al manifest verificato:'
        printf '%s\n' "${added}" >&2
        return 1
    fi
    removed="$(LC_ALL=C comm -23 "${post}" "${now}")" || return 1
    [[ -n "${removed}" ]] || return 1
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        name="${line%%|*}"
        if [[ ! "${name}" =~ ^kernel-[A-Za-z0-9_+.-]+$ ]]; then
            warn "rimozione post-boot non ammessa: ${line}"
            return 1
        fi
        if ! awk -F'|' -v n="${name}" '$1==n {f=1} END{exit !f}' "${now}"; then
            warn "rimozione post-boot dell'ultima versione di ${name}: non ammessa."
            return 1
        fi
        log "rimozione post-boot tollerata (kernel purge): ${line}"
    done <<<"${removed}"
}

confirm() {
    local boot
    local manifest
    local hash
    local tolerated=0
    preflight confirm >/dev/null
    load_state
    [[ "${STATE_STATUS}" == pending-reboot ]] || die 'nessuna transazione pending-reboot.'
    boot="$(current_boot_id)"; [[ "${boot}" != "${STATE_BOOT_ID_BEFORE}" ]] || die 'reboot non ancora osservato.'
    [[ "$(active_snapshot)" == "${STATE_TARGET}" && "$(default_snapshot)" == "${STATE_TARGET}" ]] || die 'TARGET non e active/default.'
    snapshot_is_rw "${STATE_TARGET}" || die 'TARGET attiva non RW.'
    snapshot_is_bootable "${STATE_TARGET}" || die 'TARGET attiva non bootable.'
    [[ "$(os_id)" == "${REQUIRED_OS_ID}" ]] || die 'OS ID post reboot errato.'
    manifest="${TX_CACHE_DIR}/rpmdb-confirm.tsv"; write_rpm_manifest_host "${manifest}" || die 'manifest conferma fallito.'
    hash="$(sha256sum "${manifest}" | awk '{print $1}')"
    if [[ "${hash}" != "${STATE_RPMDB_POST_HASH}" ]]; then
        [[ -s "${RPMDB_POST_MANIFEST}" ]] || die 'RPMDB post reboot diversa e manifest verificato non disponibile.'
        [[ "$(sha256sum "${RPMDB_POST_MANIFEST}" | awk '{print $1}')" == "${STATE_RPMDB_POST_HASH}" ]] \
            || die 'manifest verificato alterato rispetto allo state.'
        confirm_manifest_delta_allowed "${RPMDB_POST_MANIFEST}" "${manifest}" \
            || die 'RPMDB post reboot diversa da quella verificata.'
        tolerated=1
    fi
    # All confirmation checks are complete. Persist directly to the terminal state;
    # a crash before this write leaves pending-reboot and confirm is safely repeatable.
    STATE_STATUS=confirmed; STATE_LAST_ERROR=; persist_state_or_die; history_or_warn confirmed "target=${STATE_TARGET} rpm=${hash} kernel-purge-tolerated=${tolerated}"
    log "Upgrade ${STATE_TXID} confermato sulla TARGET ${STATE_TARGET}. SOURCE ${STATE_SOURCE} disponibile per recovery finche Snapper la conserva."
}


rollback_recovery_allowed() {
    local requested="$1" a d
    [[ "${STATE_STATUS}" == needs-inspection ]] || return 1
    case "${STATE_INSPECTION_KIND}" in
        boot-mismatch|target-active-or-default) ;;
        *) return 1 ;;
    esac
    [[ "${STATE_SOURCE}" =~ ^[0-9]+$ && "${STATE_TARGET}" =~ ^[0-9]+$ ]] || return 1
    [[ "${STATE_SOURCE}" != "${STATE_TARGET}" && "${requested}" == "${STATE_SOURCE}" ]] || return 1
    a="$(active_snapshot)"; d="$(default_snapshot)"
    [[ "${a}" == "${STATE_SOURCE}" || "${a}" == "${STATE_TARGET}" ]] || return 1
    [[ "${d}" == "${STATE_SOURCE}" || "${d}" == "${STATE_TARGET}" ]]
}

rollback_target_owned() {
    local owned
    owned="$(find_owned_targets "${TUKIT_DESCRIPTION_PREFIX} rollback ${STATE_TXID} source=${STATE_SOURCE}")" || return 1
    grep -Fxq -- "$1" <<<"${owned}"
}

prepare_rollback() {
    local source="$1"
    local recovery="${2:-0}"
    local out old active target
    local -a rollback_args=()
    snapshot_exists "${source}" || return 1
    check_boot_space || return 1
    [[ "$(snapshot_os_id "${source}")" == "${REQUIRED_OS_ID}" ]] || return 1
    ensure_snapshot_bootable "${source}" || return 1
    active="$(active_snapshot)"; old="$(default_snapshot)"
    [[ "${active}" =~ ^[0-9]+$ ]] || return 1
    if (( recovery )); then
        rollback_recovery_allowed "${source}" || return 1
    else
        [[ "${old}" == "${active}" ]] || return 1
    fi

    STATE_SOURCE="${source}"
    STATE_BOOT_ID_BEFORE="$(current_boot_id)"
    STATE_STATUS=needs-inspection
    if (( recovery )); then
        # Keep the failed TARGET and TXID until Snapper stages a new default.
        # A crash before that must not adopt the failed TARGET as a rollback.
        STATE_INSPECTION_KIND=rollback-recovery
        rollback_args=(--description "${TUKIT_DESCRIPTION_PREFIX} rollback ${STATE_TXID} source=${source}")
    else
        STATE_TARGET=
        STATE_INSPECTION_KIND=rollback-ambiguous
    fi
    STATE_LAST_ERROR='rollback avviato; esito non ancora classificato'
    persist_state_or_die
    history_or_warn rollback-preparing "source=${source} old-default=${old}"

    if ! out="$(LC_ALL=C snapper -c "${SNAPPER_CONFIG}" rollback "${rollback_args[@]}" "${source}" 2>&1)"; then
        STATE_LAST_ERROR="snapper rollback failed/ambiguous: ${out//$'\n'/ }"
        persist_state_or_die
        return 1
    fi

    target="$(default_snapshot)"
    [[ "${target}" =~ ^[0-9]+$ && "${target}" != "${old}" ]] ||
        { STATE_LAST_ERROR='rollback default ambiguous'; persist_state_or_die; return 1; }
    if (( recovery )); then
        [[ "${target}" != "${STATE_SOURCE}" && "${target}" != "${STATE_TARGET}" ]] ||
            { STATE_LAST_ERROR='rollback did not stage a new snapshot'; persist_state_or_die; return 1; }
        rollback_target_owned "${target}" ||
            { STATE_LAST_ERROR='rollback TARGET ownership not verified'; persist_state_or_die; return 1; }
    fi
    STATE_TARGET="${target}"
    STATE_INSPECTION_KIND=rollback-ambiguous
    snapshot_exists "${target}" && snapshot_is_rw "${target}" ||
        { STATE_TARGET="${target}"; STATE_LAST_ERROR='rollback TARGET invalid'; persist_state_or_die; return 1; }
    ensure_snapshot_bootable "${target}" ||
        { STATE_TARGET="${target}"; STATE_LAST_ERROR='rollback TARGET not bootable'; persist_state_or_die; return 1; }
    [[ "$(active_snapshot)" == "${active}" ]] ||
        { STATE_TARGET="${target}"; STATE_LAST_ERROR='active snapshot changed while preparing rollback'; persist_state_or_die; return 1; }

    STATE_TARGET="${target}"
    STATE_STATUS=rollback-pending
    STATE_INSPECTION_KIND=
    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn rollback-pending "source=${source} target=${target}"
}

rollback() {
    local requested="${1:-}"
    local source
    local answer
    local recovery=0
    preflight recovery >/dev/null
    load_state
    source="${requested:-${STATE_SOURCE}}"; [[ "${source}" =~ ^[0-9]+$ ]] || die 'specificare una snapshot numerica.'

    # Consistency gate: refuse to overwrite an active or unresolved transaction
    case "${STATE_STATUS}" in
        ''|confirmed|aborted|rolled-back|planned|revalidated) ;;
        needs-inspection)
            rollback_recovery_allowed "${source}" ||
                die 'rollback di recovery ammesso solo verso SOURCE per boot-mismatch/target-active-or-default, con active/default appartenenti alla transazione.'
            recovery=1
            ;;
        *)
            die "Impossibile eseguire rollback: transazione ${STATE_TXID:-?} attiva in stato '${STATE_STATUS}'. Eseguire prima '${PROG} recover'."
            ;;
    esac

    if [[ "${STATE_STATUS}" == planned || "${STATE_STATUS}" == revalidated ]]; then
        warn "Esiste un piano pendente (${STATE_TXID}); confermando il rollback verra invalidato."
    fi

    printf 'Rollback verso snapshot %s. Scrivi esattamente: ROLLBACK %s E RIAVVIA\n> ' "${source}" "${source}"
    IFS= read -r answer || die 'rollback annullato.'
    [[ "${answer}" == "ROLLBACK ${source} E RIAVVIA" ]] || die 'rollback annullato.'

    if (( recovery )); then
        rollback_recovery_allowed "${source}" || die 'contesto recovery cambiato durante la conferma.'
        # Do not persist "aborted" first: interruption in that gap would lose
        # the typed recovery route while the failed TARGET may still be default.
        history_or_warn rollback-resolves-update "source=${source} failed-target=${STATE_TARGET}"
        prepare_rollback "${source}" 1 || die 'rollback non verificabile; non riavvio.'
        reboot_or_finish rollback
        return 0
    fi

    # State mutation happens strictly after user confirmation
    if [[ "${STATE_STATUS}" == planned || "${STATE_STATUS}" == revalidated ]]; then
        mark_aborted 'piano invalidato da rollback manuale'
    fi

    reset_state
    STATE_TXID="$(new_txid)"
    STATE_CREATED="$(date -u +%FT%TZ)"
    set_tx_paths
    prepare_rollback "${source}" || die 'rollback non verificabile; non riavvio.'
    reboot_or_finish rollback
}

recover() {
    preflight recovery >/dev/null
    load_state
    local a d boot
    [[ -n "${STATE_STATUS}" ]] || { log 'Nessuna transazione registrata.'; return 0; }
    a="$(active_snapshot)"; d="$(default_snapshot)"; boot="$(current_boot_id)"

    case "${STATE_STATUS}" in
        planning)
            mark_aborted 'planning interrotto; cache non fidata'
            log 'Planning archiviato come aborted.'
            ;;
        planned)
            log 'Esiste solo un piano PREPARED; SOURCE non modificata.'
            ;;
        revalidated)
            STATE_STATUS=planned
            STATE_LAST_ERROR='REVALIDATED interrotto prima di tukit open; richiesta nuova revalidation'
            persist_state_or_die
            log 'Nessuna TARGET aperta: stato riportato a PREPARED.'
            ;;
        opening)
            STATE_STATUS=needs-inspection
            STATE_INSPECTION_KIND=open-ambiguous
            STATE_LAST_ERROR='processo interrotto durante tukit open'
            persist_state_or_die
            die "open TARGET ambiguo; usare '${PROG} recover inspect'."
            ;;
        target|verified)
            [[ "${STATE_TARGET}" =~ ^[0-9]+$ ]] || die 'TARGET sconosciuta.'
            if [[ "${a}" == "${STATE_TARGET}" || "${d}" == "${STATE_TARGET}" ]]; then
                STATE_STATUS=needs-inspection
                STATE_INSPECTION_KIND=target-active-or-default
                STATE_LAST_ERROR='TARGET incompleta risulta active/default; abort automatico vietato'
                persist_state_or_die
                die "TARGET active/default; usare '${PROG} recover inspect'."
            fi
            abort_target_safe "${STATE_TARGET}" || die 'abort TARGET non riuscito in modo verificabile.'
            log 'TARGET incompleta abortita; SOURCE invariata.'
            ;;
        committing)
            [[ "${STATE_TARGET}" =~ ^[0-9]+$ ]] || die 'committing senza TARGET.'
            if [[ "${d}" == "${STATE_SOURCE}" && "${a}" != "${STATE_TARGET}" ]]; then
                abort_target_safe "${STATE_TARGET}" || die 'commit non avvenuto ma abort TARGET non riuscito.'
                log 'Commit non avvenuto; TARGET abortita.'
            elif [[ "${d}" == "${STATE_TARGET}" ]] \
                && snapshot_is_bootable "${STATE_SOURCE}" \
                && snapshot_is_bootable "${STATE_TARGET}" \
                && verified_target_evidence "${STATE_TARGET}"; then
                STATE_STATUS=pending-reboot
                STATE_LAST_ERROR=
                persist_state_or_die
                log 'Close avvenuto: TARGET riclassificata pending-reboot.'
            else
                STATE_STATUS=needs-inspection
                STATE_INSPECTION_KIND=close-ambiguous
                STATE_LAST_ERROR="committing non classificabile: active=${a:-?} default=${d:-?}"
                persist_state_or_die
                die "commit ambiguo; usare '${PROG} recover inspect'."
            fi
            ;;
        pending-reboot)
            if [[ "${boot}" == "${STATE_BOOT_ID_BEFORE}" ]]; then
                log 'TARGET preparata; reboot ancora da fare.'
            elif [[ "${a}" == "${STATE_TARGET}" && "${d}" == "${STATE_TARGET}" ]]; then
                log "Reboot sulla TARGET osservato; eseguire '${PROG} confirm'."
            else
                STATE_STATUS=needs-inspection
                STATE_INSPECTION_KIND=boot-mismatch
                STATE_LAST_ERROR="reboot su snapshot inattesa: active=${a:-?} default=${d:-?} target=${STATE_TARGET:-?}"
                persist_state_or_die
                die "boot mismatch; usare '${PROG} recover inspect'."
            fi
            ;;
        rollback-pending)
            [[ "${boot}" != "${STATE_BOOT_ID_BEFORE}" ]] || { log 'Rollback preparato; reboot ancora da fare.'; return 0; }
            if [[ "${a}" == "${STATE_TARGET}" && "${d}" == "${STATE_TARGET}" ]] \
                && snapshot_is_rw "${STATE_TARGET}" \
                && snapshot_is_bootable "${STATE_TARGET}"; then
                STATE_STATUS=rolled-back
                STATE_LAST_ERROR=
                persist_state_or_die
                history_or_warn rolled-back "target=${STATE_TARGET}"
                log 'Rollback confermato.'
            else
                STATE_STATUS=needs-inspection
                STATE_INSPECTION_KIND=rollback-ambiguous
                STATE_LAST_ERROR="rollback post-reboot mismatch active=${a:-?} default=${d:-?}"
                persist_state_or_die
                die "rollback ambiguo; usare '${PROG} recover inspect'."
            fi
            ;;
        needs-inspection)
            case "${STATE_INSPECTION_KIND}" in
                rollback-recovery)
                    # SOURCE/TARGET still identify the failed update, not the
                    # new rollback snapshot. Never adopt either as its result.
                    if [[ "${boot}" == "${STATE_BOOT_ID_BEFORE}" ]] \
                        && [[ "${a}" == "${STATE_SOURCE}" || "${a}" == "${STATE_TARGET}" ]] \
                        && ! pgrep -af '[s]napper.*rollback' >/dev/null 2>&1; then
                        if [[ "${d}" == "${STATE_SOURCE}" || "${d}" == "${STATE_TARGET}" ]]; then
                            if [[ "${a}" == "${STATE_SOURCE}" ]]; then
                                STATE_INSPECTION_KIND=boot-mismatch
                            else
                                STATE_INSPECTION_KIND=target-active-or-default
                            fi
                            STATE_LAST_ERROR='rollback non staged; ripetere rollback con conferma esplicita'
                            persist_state_or_die
                            log 'Rollback non staged; ripristinato il percorso di recovery con conferma.'
                            return 0
                        fi
                        if [[ "${d}" =~ ^[0-9]+$ ]] \
                            && rollback_target_owned "${d}" \
                            && snapshot_exists "${d}" && snapshot_is_rw "${d}" \
                            && [[ "$(snapshot_os_id "${d}")" == "${REQUIRED_OS_ID}" ]] \
                            && ensure_snapshot_bootable "${d}"; then
                            STATE_TARGET="${d}"
                            STATE_STATUS=rollback-pending
                            STATE_INSPECTION_KIND=
                            STATE_LAST_ERROR=
                            persist_state_or_die
                            history_or_warn rollback-pending "source=${STATE_SOURCE} target=${d} recovered=1"
                            log "Rollback classificato: TARGET ${d}; reboot ancora da fare."
                            return 0
                        fi
                    fi
                    ;;
                close-ambiguous|close-postcondition|pre-close-sync-failed)
                    [[ "${STATE_TARGET}" =~ ^[0-9]+$ ]] ||
                        die 'close ambiguo senza TARGET registrata.'

                    if [[ "${d}" == "${STATE_SOURCE}" && "${a}" != "${STATE_TARGET}" ]]; then
                        abort_target_safe "${STATE_TARGET}" ||
                            die 'close non committed, ma abort TARGET non riuscito in modo verificabile.'
                        log 'Close non committed: TARGET abortita, SOURCE invariata.'
                        return 0
                    fi

                    if [[ "${STATE_INSPECTION_KIND}" != pre-close-sync-failed ]] \
                        && [[ "${d}" == "${STATE_TARGET}" ]] \
                        && snapshot_exists "${STATE_TARGET}" \
                        && snapshot_is_rw "${STATE_TARGET}" \
                        && snapshot_is_bootable "${STATE_SOURCE}" \
                        && snapshot_is_bootable "${STATE_TARGET}" \
                        && verified_target_evidence "${STATE_TARGET}"; then
                        STATE_STATUS=pending-reboot
                        STATE_INSPECTION_KIND=
                        STATE_LAST_ERROR=
                        persist_state_or_die
                        history_or_warn close-recovered "target=${STATE_TARGET}"
                        log 'Close classificato automaticamente: TARGET staged/default; pending-reboot.'
                        return 0
                    fi
                    ;;

                rollback-ambiguous)
                    # Same boot + active==default + no TARGET means snapper did
                    # not stage a rollback. Archive the interrupted intent.
                    if [[ "${boot}" == "${STATE_BOOT_ID_BEFORE}" \
                        && "${d}" == "${a}" \
                        && -z "${STATE_TARGET}" ]] \
                        && ! pgrep -af '[s]napper.*rollback' >/dev/null 2>&1; then
                        STATE_STATUS=aborted
                        STATE_INSPECTION_KIND=
                        STATE_LAST_ERROR='rollback interrotto prima di creare/stagiare una TARGET; active/default invariati'
                        persist_state_or_die
                        history_or_warn rollback-aborted-no-default "source=${STATE_SOURCE}"
                        log 'Rollback non staged: active/default invariati; intento archiviato come aborted.'
                        return 0
                    fi

                    if [[ "${boot}" == "${STATE_BOOT_ID_BEFORE}" \
                        && "${d}" =~ ^[0-9]+$ \
                        && "${d}" != "${a}" ]] \
                        && snapshot_exists "${d}" \
                        && snapshot_is_rw "${d}" \
                        && [[ "$(snapshot_os_id "${d}")" == "${REQUIRED_OS_ID}" ]] \
                        && ensure_snapshot_bootable "${d}"; then
                        STATE_TARGET="${d}"
                        STATE_STATUS=rollback-pending
                        STATE_INSPECTION_KIND=
                        STATE_LAST_ERROR=
                        persist_state_or_die
                        history_or_warn rollback-pending "source=${STATE_SOURCE} target=${STATE_TARGET} recovered=1"
                        log "Rollback classificato: TARGET ${STATE_TARGET}; reboot ancora da fare."
                        return 0
                    fi
                    ;;
            esac

            die "stato needs-inspection (${STATE_INSPECTION_KIND:-unknown}); usare '${PROG} recover inspect'."
            ;;
        confirmed|aborted|rolled-back)
            log 'Nessuna recovery pendente.'
            ;;
    esac
}

prune() {
    local days="${1:-30}"
    local p
    local base
    local -a files=()
    require_root; acquire_lock; require_recovery_commands; command -v find >/dev/null 2>&1 || die 'comando richiesto non trovato: find'; [[ "${days}" =~ ^[0-9]+$ ]] || die 'GIORNI non valido.'; load_state
    case "${STATE_STATUS}" in
        ''|confirmed|aborted|rolled-back|planned) ;;
        *) die "prune bloccato in stato ${STATE_STATUS:-sconosciuto}." ;;
    esac
    [[ -d "${CACHE_ROOT}" ]] && while IFS= read -r p; do base="${p##*/}"; is_uuid "${base}" || continue; [[ "${base}" == "${STATE_TXID}" && "${STATE_STATUS}" == planned ]] || files+=("${p}"); done < <(find "${CACHE_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime "+${days}" -print)
    [[ -d "${LOG_ROOT}" ]] && while IFS= read -r p; do files+=("${p}"); done < <(find "${LOG_ROOT}" -mindepth 1 -maxdepth 1 -type f -mtime "+${days}" -print)
    printf 'Artefatti candidati: %s. Snapshot Btrfs: mai eliminate da prune.\n' "${#files[@]}"
    (( ${#files[@]} )) || return 0
    printf 'Scrivi esattamente: PRUNE ATOMIC-UPDATE %s\n> ' "${days}"; local ans; IFS= read -r ans || die 'prune annullato.'; [[ "${ans}" == "PRUNE ATOMIC-UPDATE ${days}" ]] || die 'prune annullato.'
    for p in "${files[@]}"; do [[ -d "${p}" ]] && rm -rf -- "${p}" || rm -f -- "${p}"; done
    history_or_warn prune "days=${days} files=${#files[@]}"
}

status() {
    require_root; load_state
    printf 'mySlowrollOS: %s\n' "${PROGRAM_VERSION}"
    printf 'OS: %s\n' "$(os_id)"
    printf 'Boot ID: %s\n' "$(current_boot_id 2>/dev/null || echo sconosciuto)"
    printf 'Active: %s\n' "$(active_snapshot || true)"
    printf 'Default: %s\n' "$(default_snapshot || true)"
    printf 'State: %s\n' "${STATE_STATUS:-nessuna transazione}"
    printf 'TXID: %s\n' "${STATE_TXID:-nessuno}"
    printf 'SOURCE: %s\n' "${STATE_SOURCE:-nessuna}"
    printf 'TARGET: %s\n' "${STATE_TARGET:-nessuna}"
    printf 'Created: %s\n' "${STATE_CREATED:-sconosciuto}"
    if [[ "${STATE_STATUS}" == planned ]]; then
        local age
        age="$(plan_age_seconds || echo sconosciuta)"
        printf 'Plan age: %ss (riutilizzabile: %s, max %ss)\n' "${age}" "$(planned_is_fresh && echo 'si' || echo 'no')" "${PLAN_MAX_AGE_SECONDS}"
    fi
    printf 'Target opened: %s\n' "${STATE_TARGET_OPENED:-sconosciuto}"
    printf 'Inspection kind: %s\n' "${STATE_INSPECTION_KIND:-nessuno}"
    printf 'Last error: %s\n' "${STATE_LAST_ERROR:-nessuno}"
    if [[ -n "${DUP_LOG}" ]]; then
        printf 'Dup log: %s\n' "${DUP_LOG}"
    fi
    return 0
}

recover_inspect() {
    preflight recovery >/dev/null
    load_state
    local a d
    a="$(active_snapshot || true)"; d="$(default_snapshot || true)"
    printf 'State: %s\n' "${STATE_STATUS:-none}"
    printf 'Inspection kind: %s\n' "${STATE_INSPECTION_KIND:-none}"
    printf 'TXID: %s\n' "${STATE_TXID:-none}"
    printf 'SOURCE: %s | TARGET: %s | active: %s | default: %s\n'         "${STATE_SOURCE:-none}" "${STATE_TARGET:-none}" "${a:-?}" "${d:-?}"
    printf 'Last error: %s\n' "${STATE_LAST_ERROR:-none}"
    printf 'Owned TARGETs by description:'
    local owned
    if ! owned="$(find_owned_targets | tr '\n' ' ')"; then
        printf ' unknown (Snapper enumeration failed)\n'
        warn 'Elenco Snapper non verificabile: impossibile determinare le TARGET della transazione.'
        return 1
    fi
    printf ' %s\n' "${owned:-none}"
    if [[ "${STATE_TARGET}" =~ ^[0-9]+$ ]]; then
        if target_quiescent "${STATE_TARGET}"; then
            printf 'TARGET quiescent: yes\n'
        else
            printf 'TARGET quiescent: no/unproven\n'
        fi
    fi
    [[ -n "${TUKIT_OPEN_LOG}" ]] && printf 'Open log: %s\n' "${TUKIT_OPEN_LOG}"
    [[ -n "${DUP_LOG}" ]] && printf 'Dup log: %s\n' "${DUP_LOG}"
    [[ -n "${SDBOOT_LOG}" ]] && printf 'Boot log: %s\n' "${SDBOOT_LOG}"
    return 0
}

recover_typed_abort() {
    local t="$1"
    local owned=
    preflight recovery >/dev/null
    load_state
    [[ "${STATE_STATUS}" == needs-inspection ]] || die 'abort-target ammesso solo da needs-inspection.'
    [[ "${t}" =~ ^[0-9]+$ ]] || die 'TARGET richiesta non numerica.'

    if [[ -n "${STATE_TARGET}" ]]; then
        [[ "${STATE_TARGET}" == "${t}" ]] ||
            die 'snapshot richiesta diversa dalla TARGET registrata.'
    else
        owned="$(resolve_owned_target || true)"
        [[ "${owned}" == "${t}" ]] ||
            die 'TARGET non registrata e ownership descrizione/txid non univoca per la snapshot richiesta.'
        STATE_TARGET="${t}"
        persist_state_or_die
        history_or_warn target-adopted-for-abort "target=${t} source=description"
    fi

    abort_target_safe "${t}" ||
        die 'abort-target non concluso in modo verificabile; rieseguire recover inspect.'
}

recover_adopt_target() {
    local t="$1"
    preflight recovery >/dev/null
    load_state
    [[ "${STATE_STATUS}" == needs-inspection ]] || die 'adopt-target ammesso solo da needs-inspection.'
    case "${STATE_INSPECTION_KIND}" in
        close-ambiguous|close-postcondition) ;;
        *) die 'adopt-target richiede una TARGET gia verificata e una close ambigua.' ;;
    esac
    [[ "${STATE_TARGET}" == "${t}" ]] || die 'snapshot richiesta diversa dalla TARGET registrata.'
    [[ "$(default_snapshot)" == "${t}" ]] || die 'TARGET non e la snapshot default.'
    snapshot_is_bootable "${STATE_SOURCE}" && snapshot_is_bootable "${t}" ||
        die 'SOURCE/TARGET non entrambe bootable.'
    verified_target_evidence "${t}" ||
        die 'non verificabili proprieta, provenienza o manifest RPM della TARGET: adozione vietata.'
    STATE_STATUS=pending-reboot
    STATE_INSPECTION_KIND=
    STATE_LAST_ERROR=
    persist_state_or_die
    history_or_warn adopted-target "target=${t}"
    log 'TARGET verificata e adottata; completare reboot/confirm.'
}

recover_clear_opening() {
    preflight recovery >/dev/null
    load_state
    [[ "${STATE_STATUS}" == needs-inspection && "${STATE_INSPECTION_KIND}" == open-ambiguous ]] ||
        die 'clear-opening ammesso solo per open-ambiguous.'
    [[ "$(active_snapshot)" == "${STATE_SOURCE}" && "$(default_snapshot)" == "${STATE_SOURCE}" ]] ||
        die 'SOURCE non e piu active/default.'
    # Fail closed: clear only when neither state nor Snapper reveal a TARGET
    # owned by this TXID.  A parse failure is not proof that open created none.
    [[ -z "${STATE_TARGET}" ]] || die 'TARGET numerica registrata: usare inspect/abort-target.'
    local owned
    owned="$(find_owned_targets)" || die 'Elenco Snapper non verificabile: clear-opening vietato.'
    [[ -z "${owned}" ]] ||
        die 'Esiste almeno una snapshot con la descrizione di questa transazione: clear-opening vietato.'
    STATE_STATUS=aborted
    STATE_INSPECTION_KIND=
    STATE_LAST_ERROR='opening archiviato manualmente dopo ispezione: nessuna TARGET registrata'
    persist_state_or_die
    history_or_warn clear-opening
}

main() {
    local c="${1:-}"
    case "${c}" in
        check)
            (( $#==1 )) || die 'check non accetta argomenti'
            preflight update >/dev/null
            load_state
            if [[ -n "${STATE_STATUS}" && ! "${STATE_STATUS}" =~ ^(confirmed|aborted|rolled-back)$ ]]; then
                warn "Esiste una transazione attiva in stato '${STATE_STATUS}' (TXID: ${STATE_TXID:-?})."
            fi
            log "Preflight ${PROGRAM_VERSION} superato."
            ;;
        plan) (( $#==1 )) || die 'plan non accetta argomenti'; make_plan ;;
        upgrade) (( $#==1 )) || die 'upgrade non accetta argomenti'; upgrade ;;
        confirm) (( $#==1 )) || die 'confirm non accetta argomenti'; confirm ;;
        recover)
            case "${2:-}" in
                '') (( $#==1 )) || die 'uso: recover [inspect|abort-target N|adopt-target N|clear-opening]'; recover ;;
                inspect) (( $#==2 )) || die 'uso: recover inspect'; recover_inspect ;;
                abort-target) (( $#==3 )) || die 'uso: recover abort-target N'; recover_typed_abort "${3}" ;;
                adopt-target) (( $#==3 )) || die 'uso: recover adopt-target N'; recover_adopt_target "${3}" ;;
                clear-opening) (( $#==2 )) || die 'uso: recover clear-opening'; recover_clear_opening ;;
                *) die 'uso: recover [inspect|abort-target N|adopt-target N|clear-opening]' ;;
            esac
            ;;
        rollback) (( $#<=2 )) || die "uso: ${PROG} rollback [SNAPSHOT]"; rollback "${2:-}" ;;
        prune) (( $#<=2 )) || die "uso: ${PROG} prune [GIORNI]"; prune "${2:-30}" ;;
        status) (( $#==1 )) || die 'status non accetta argomenti'; status ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; die "comando sconosciuto: ${c}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
