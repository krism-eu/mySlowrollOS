#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# mySlowrollOS atomic distribution upgrade v4.0.0-rc1
#
# RC1 integration layer:
#   - reuses the tested v3.4.9 planning/download/manifest engine;
#   - isolates v4 state/cache/log namespaces from the operational v3 baseline;
#   - performs zypper dup only inside an offline tukit TARGET;
#   - never changes SOURCE RPM content;
#   - commits TARGET only after manifest, package, OS and boot checks pass.
#
# IMPORTANT: destructive paths are gated for VM validation. Set
# MYSLOWROLL_RC1_ENABLE_MUTATIONS=1 explicitly for upgrade/recover/abort.

readonly RC1_VERSION='4.0.0-rc1'
readonly RC1_STATE_DIR=/var/lib/myslowroll/atomic-dup-v4-rc1
readonly RC1_CACHE_ROOT=/var/cache/myslowroll-atomic-dup-v4-rc1
readonly RC1_LOG_ROOT=/var/log/myslowroll-atomic-dup-v4-rc1
readonly RC1_LOCK_FILE=/run/myslowroll-atomic-dup-v4-rc1.lock
readonly RC1_TARGET_MAX_AGE_SECONDS="${MYSLOWROLL_TARGET_MAX_AGE_SECONDS:-3600}"
readonly RC1_MUTATIONS="${MYSLOWROLL_RC1_ENABLE_MUTATIONS:-0}"

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BASELINE="${SELF_DIR}/myslowroll-atomic-dup-v3.4.9-tested.sh"
[[ -r "${BASELINE}" ]] || {
    printf '[%s] ERRORE: baseline richiesta non trovata: %s\n' "${0##*/}" "${BASELINE}" >&2
    exit 1
}

# Import the tested v3.4.9 engine without modifying its file. Only its storage
# namespace is rewritten while sourcing so v3 and v4 can never share durable
# state, cache, logs or lock files.
# shellcheck disable=SC1090
source <(
    sed \
        -e "s#^readonly STATE_DIR=.*#readonly STATE_DIR=${RC1_STATE_DIR}#" \
        -e 's#^readonly STATE_FILE=.*#readonly STATE_FILE="${STATE_DIR}/state"#' \
        -e 's#^readonly HISTORY_FILE=.*#readonly HISTORY_FILE="${STATE_DIR}/history.log"#' \
        -e "s#^readonly CACHE_ROOT=.*#readonly CACHE_ROOT=${RC1_CACHE_ROOT}#" \
        -e "s#^readonly LOG_ROOT=.*#readonly LOG_ROOT=${RC1_LOG_ROOT}#" \
        -e "s#^readonly LOCK_FILE=.*#readonly LOCK_FILE=${RC1_LOCK_FILE}#" \
        "${BASELINE}"
)

readonly RC1_META_NAME=v4-rc1.meta
V4_PHASE=
V4_SOURCE_OPEN_HASH=
V4_TARGET_OPENED_UTC=

readonly -a V4_CRITICAL_PKGS=(
    criscore1 criscore2 btrfsprogs kernel-default rpm
    sdbootutil sdbootutil-kernel-install sdbootutil-snapper
    snapper systemd systemd-boot transactional-update tukit zypper
)

rc1_usage() {
    cat <<EOF_USAGE
Uso: ${PROG} COMMAND

Versione: ${RC1_VERSION}

Comandi:
  status      mostra stato v4 RC1 e fase tukit
  check       preflight v3 + prerequisiti tukit, nessuna snapshot
  plan        planning/pre-download/manifest della v3.4.9 nel namespace v4
  upgrade     crea TARGET, esegue dup offline, verifica e chiude TARGET
  confirm     conferma dopo boot effettivo nella TARGET
  recover     recovery fail-closed della TARGET
  abort       elimina una TARGET non attiva/non-default
  prune [N]   riusa il prune collaudato della v3 sul namespace v4
  design      mostra la state machine RC1

Per upgrade/recover/abort impostare esplicitamente:
  MYSLOWROLL_RC1_ENABLE_MUTATIONS=1

La v3.4.9 resta indipendente e usa il proprio namespace originale.
EOF_USAGE
}

rc1_mutations_enabled() {
    case "${RC1_MUTATIONS}" in
        1|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
}

require_rc1_mutations() {
    rc1_mutations_enabled ||
        die 'mutazioni RC1 bloccate: impostare MYSLOWROLL_RC1_ENABLE_MUTATIONS=1 solo nella VM di collaudo.'
}

active_snapshot_v4() {
    local opts
    opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
    sed -nE 's#.*subvol=/?.*\.snapshots/([0-9]+)/snapshot.*#\1#p' <<<"${opts}"
}

default_snapshot_v4() {
    local line
    line="$(btrfs subvolume get-default / 2>/dev/null || true)"
    sed -nE 's#.*path .*\.snapshots/([0-9]+)/snapshot.*#\1#p' <<<"${line}"
}

snapshot_path_v4() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    printf '/.snapshots/%s/snapshot\n' "$1"
}

snapshot_exists_v4() {
    [[ -d "$(snapshot_path_v4 "$1")" ]]
}

snapshot_is_rw_v4() {
    local value
    value="$(btrfs property get "$(snapshot_path_v4 "$1")" ro 2>/dev/null || true)"
    [[ "${value}" == ro=false ]]
}

snapshot_is_bootable_v4() {
    sdbootutil is-bootable "$1" >/dev/null 2>&1
}

esp_path_v4() {
    bootctl --print-esp-path 2>/dev/null
}

available_bytes_v4() {
    LC_ALL=C df -B1 --output=avail -- "$1" 2>/dev/null |
        awk 'NR == 2 && $1 ~ /^[0-9]+$/ { print $1 }'
}

check_esp_space_v4() {
    local esp available options
    esp="$(esp_path_v4)" || return 1
    [[ -n "${esp}" && -d "${esp}" ]] || return 1
    options="$(findmnt -n -o OPTIONS --target "${esp}" 2>/dev/null || true)"
    tr ',' '\n' <<<"${options}" | grep -qx rw || return 1
    available="$(available_bytes_v4 "${esp}")" || return 1
    [[ "${available}" =~ ^[0-9]+$ ]] || return 1
    (( available >= ESP_MIN_FREE_BYTES ))
}

check_transactional_update_idle_v4() {
    if systemctl is-enabled --quiet transactional-update.timer 2>/dev/null; then
        die 'transactional-update.timer deve essere disabilitato durante il collaudo RC1.'
    fi
    if systemctl is-active --quiet transactional-update.service 2>/dev/null; then
        die 'transactional-update.service e attivo.'
    fi
    if systemctl is-failed --quiet transactional-update.service 2>/dev/null; then
        die 'transactional-update.service e in stato failed.'
    fi
}

verify_tukit_cli_surface_v4() {
    local help version subcommand
    version="$(tukit --version 2>&1)" || return 1
    help="$(tukit --help 2>&1)" || return 1
    for subcommand in open call callext close abort; do
        grep -Eq "(^|[[:space:]])${subcommand}([[:space:]]|$)" <<<"${help}" || return 1
    done
    log "CLI tukit rilevata: ${version//$'\n'/ }"
}

require_v4_commands() {
    local cmd
    for cmd in bootctl tukit transactional-update; do
        command -v "${cmd}" >/dev/null 2>&1 || die "comando v4 richiesto non trovato: ${cmd}"
    done
}

preflight_v4() {
    preflight_new_transaction
    require_v4_commands
    verify_tukit_cli_surface_v4 || die 'CLI tukit incompatibile o non caratterizzata.'
    path_is_outside_root_snapshot /var ||
        die '/var non e dimostrabilmente fuori dalla snapshot root.'
    check_transactional_update_idle_v4
    check_esp_space_v4 || die 'ESP non RW o spazio libero insufficiente.'
    local active default
    active="$(active_snapshot_v4)"
    default="$(default_snapshot_v4)"
    [[ -n "${active}" && "${active}" == "${default}" ]] ||
        die "snapshot attiva/default non coincidono (${active:-?}/${default:-?})."
    snapshot_is_rw_v4 "${active}" || die "SOURCE ${active} non RW."
    snapshot_is_bootable_v4 "${active}" || die "SOURCE ${active} non bootable."
}

meta_path_v4() {
    [[ -n "${TX_CACHE_DIR:-}" ]] || return 1
    printf '%s/%s\n' "${TX_CACHE_DIR}" "${RC1_META_NAME}"
}

load_meta_v4() {
    V4_PHASE=
    V4_SOURCE_OPEN_HASH=
    V4_TARGET_OPENED_UTC=
    local path key value
    path="$(meta_path_v4 2>/dev/null || true)"
    [[ -n "${path}" && -f "${path}" ]] || return 0
    while IFS='=' read -r key value; do
        case "${key}" in
            phase) V4_PHASE="${value}" ;;
            source_open_hash) V4_SOURCE_OPEN_HASH="${value}" ;;
            target_opened_utc) V4_TARGET_OPENED_UTC="${value}" ;;
            ''|'#'*) ;;
            *) die "chiave meta v4 sconosciuta: ${key}" ;;
        esac
    done <"${path}"
}

persist_meta_v4() {
    local path tmp
    path="$(meta_path_v4)"
    install -d -o root -g root -m 0700 "${TX_CACHE_DIR}"
    tmp="$(mktemp "${TX_CACHE_DIR}/.${RC1_META_NAME}.XXXXXX")"
    {
        printf 'phase=%s\n' "${V4_PHASE}"
        printf 'source_open_hash=%s\n' "${V4_SOURCE_OPEN_HASH}"
        printf 'target_opened_utc=%s\n' "${V4_TARGET_OPENED_UTC}"
    } >"${tmp}"
    chmod 0600 "${tmp}"
    sync "${tmp}"
    mv -f -- "${tmp}" "${path}"
    sync "${TX_CACHE_DIR}"
}

set_phase_v4() {
    V4_PHASE="$1"
    persist_meta_v4
}

source_rpmdb_hash_v4() {
    local tmp hash
    tmp="$(mktemp /run/myslowroll-v4-source-rpmdb.XXXXXX)" || return 1
    if ! LC_ALL=C rpm -qa \
        --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}|%{ARCH}\n' |
        LC_ALL=C sort -u >"${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    hash="$(sha256sum "${tmp}" | awk '{print $1}')" || { rm -f -- "${tmp}"; return 1; }
    rm -f -- "${tmp}"
    [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${hash}"
}

assert_source_unchanged_v4() {
    local current
    [[ "${V4_SOURCE_OPEN_HASH}" =~ ^[0-9a-f]{64}$ ]] ||
        die 'fingerprint SOURCE all apertura assente o non valido.'
    current="$(source_rpmdb_hash_v4)" || die 'fingerprint RPM SOURCE corrente non calcolabile.'
    [[ "${current}" == "${V4_SOURCE_OPEN_HASH}" ]] ||
        die 'RPMDB SOURCE cambiata dopo tukit open: abortire TARGET e creare un nuovo piano.'
}

parse_tukit_open_output_v4() {
    local raw_file="$1" candidate count
    candidate="$(awk '
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        /^[0-9]+$/ { print }
    ' "${raw_file}")"
    count="$(wc -l <<<"${candidate}")"
    [[ "${count}" == 1 && "${candidate}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${candidate}"
}

open_target_v4() {
    local raw_file target description
    raw_file="${LOG_ROOT}/${STATE_TXID}.tukit-open.log"
    description="myslowroll-v4-rc1 txid=${STATE_TXID}"
    install -d -o root -g root -m 0700 "${LOG_ROOT}"

    STATE_STATUS=prepared
    STATE_TARGET=
    STATE_LAST_ERROR=
    persist_state
    set_phase_v4 target-opening

    if ! tukit --description "${description}" open >"${raw_file}" 2>&1; then
        sync "${raw_file}" || true
        STATE_LAST_ERROR="tukit open fallito/ambiguo; non riprovare automaticamente; output=${raw_file}"
        persist_state
        set_phase_v4 target-open-ambiguous
        die "tukit open non verificabile; ispezionare ${raw_file} e cercare txid=${STATE_TXID}."
    fi
    sync "${raw_file}"
    if ! target="$(parse_tukit_open_output_v4 "${raw_file}")"; then
        STATE_LAST_ERROR="tukit open riuscito ma TARGET non riconosciuta; output=${raw_file}"
        persist_state
        set_phase_v4 target-open-ambiguous
        die "TARGET forse creata ma numero non riconosciuto; non riprovare; vedere ${raw_file}."
    fi

    STATE_TARGET="${target}"
    V4_SOURCE_OPEN_HASH="$(source_rpmdb_hash_v4)" || die 'fingerprint SOURCE non acquisibile.'
    V4_TARGET_OPENED_UTC="$(date -u +%FT%TZ)"
    persist_state
    set_phase_v4 target-prepared
    printf '%s\n' "${target}"
}

target_age_seconds_v4() {
    local opened now
    [[ -n "${V4_TARGET_OPENED_UTC}" ]] || return 1
    opened="$(date -u -d "${V4_TARGET_OPENED_UTC}" +%s 2>/dev/null)" || return 1
    now="$(date -u +%s)"
    (( now >= opened )) || return 1
    printf '%s\n' "$((now-opened))"
}

assert_target_window_v4() {
    local age
    age="$(target_age_seconds_v4)" || die 'eta TARGET non determinabile.'
    (( age <= RC1_TARGET_MAX_AGE_SECONDS )) ||
        die "TARGET aperta da ${age}s: limite RC1 ${RC1_TARGET_MAX_AGE_SECONDS}s superato."
}

target_cache_visible_v4() {
    tukit call "$1" sh -c 'test -d "$1" && test -r "$1" && test -w "$1"' sh "$2"
}

write_target_manifest_v4() {
    local target="$1" output="$2" tmp="${2}.tmp"
    rm -f -- "${tmp}"
    if ! LC_ALL=C tukit call "${target}" rpm -qa \
        --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}|%{ARCH}\n' |
        LC_ALL=C sort -u >"${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    sync "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${output}"
    sync "${output%/*}"
}

target_os_id_v4() {
    tukit call "$1" awk -F= '$1 == "ID" { gsub(/^"|"$/, "", $2); print $2; exit }' /usr/lib/os-release
}

write_live_manifest_v4() {
    local output="$1" tmp="${1}.tmp"
    rm -f -- "${tmp}"
    if ! LC_ALL=C rpm -qa \
        --qf '%{NAME}|%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}|%{ARCH}\n' |
        LC_ALL=C sort -u >"${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    [[ -s "${tmp}" ]] || { rm -f -- "${tmp}"; return 1; }
    sync "${tmp}" || { rm -f -- "${tmp}"; return 1; }
    mv -f -- "${tmp}" "${output}"
    sync "${output%/*}"
}

verify_target_packages_v4() {
    local pkg
    for pkg in "${V4_CRITICAL_PKGS[@]}"; do
        tukit call "$1" rpm --quiet -q "${pkg}" || return 1
    done
}

ensure_snapshot_bootable_v4() {
    local snapshot="$1" log_file="${LOG_ROOT}/${STATE_TXID}.target-${1}.sdboot.log"
    snapshot_is_bootable_v4 "${snapshot}" && return 0
    check_esp_space_v4 || return 1
    (
        printf 'snapshot=%s action=sdbootutil-add-all-kernels\n' "${snapshot}"
        sdbootutil add-all-kernels "${snapshot}"
        sdbootutil is-bootable "${snapshot}"
    ) >"${log_file}" 2>&1 || return 1
    sync "${log_file}" || true
    snapshot_is_bootable_v4 "${snapshot}"
}

remove_target_boot_entries_v4() {
    local target="$1" log_file="${LOG_ROOT}/${STATE_TXID:-unknown}.target-${target}.sdboot-remove.log"
    [[ "${target}" =~ ^[0-9]+$ ]] || return 1
    [[ "$(active_snapshot_v4)" != "${target}" ]] || return 1
    [[ "$(default_snapshot_v4)" != "${target}" ]] || return 1
    (
        rc=0
        sdbootutil remove-all-kernels --disable-predictions "${target}" || rc=$?
        sdbootutil cleanup --disable-predictions "${target}" || { x=$?; (( rc != 0 )) || rc=$x; }
        exit "${rc}"
    ) >"${log_file}" 2>&1
}

abort_target_v4() {
    local target="$1" active default
    active="$(active_snapshot_v4)"
    default="$(default_snapshot_v4)"
    [[ -n "${active}" ]] || die 'snapshot attiva non determinabile.'
    [[ "${target}" != "${active}" ]] || die "rifiuto di abortire TARGET ${target}: e la root attiva."
    [[ "${target}" != "${default}" ]] || die "rifiuto di abortire TARGET ${target}: e la snapshot default."
    remove_target_boot_entries_v4 "${target}" || warn 'pulizia entry boot TARGET incompleta.'
    tukit abort "${target}"
}

run_dup_in_target_v4() {
    local target="$1" had_errexit=0
    local -a pipeline_rc
    assert_source_unchanged_v4
    assert_target_window_v4
    target_cache_visible_v4 "${target}" "${TX_PKG_CACHE}" ||
        die "cache ${TX_PKG_CACHE} non visibile nella TARGET."
    configure_update_policy
    check_transactional_update_idle_v4
    check_zypp_lock_hint
    STATE_STATUS=in-progress
    STATE_DUP_STARTED="$(date -u +%FT%TZ)"
    persist_state
    set_phase_v4 target-updating

    [[ $- == *e* ]] && had_errexit=1
    set +e
    systemd-inhibit \
        --what=shutdown:sleep:idle \
        --who="${PROG}" \
        --why='mySlowroll v4 RC1 offline TARGET update' \
        --mode=block \
        tukit call "${target}" \
            env DISABLE_SNAPPER_ZYPP_PLUGIN=1 LC_ALL=C \
            zypper --non-interactive --no-refresh \
            --pkg-cache-dir "${TX_PKG_CACHE}" \
            --userdata "myslowroll-v4-rc1:${STATE_TXID}" dup \
            "${ZYPPER_LICENSE_ARGS[@]}" \
            --download-in-advance --no-recommends --no-allow-vendor-change \
        2>&1 | tee "${DUP_LOG}"
    pipeline_rc=("${PIPESTATUS[@]}")
    (( had_errexit == 0 )) || set -e
    sync "${DUP_LOG}" || true
    (( pipeline_rc[1] == 0 )) || warn "tee dup rc=${pipeline_rc[1]}."
    return "${pipeline_rc[0]}"
}

verify_target_v4() {
    local target="$1"
    set_phase_v4 target-verifying
    assert_source_unchanged_v4
    assert_target_window_v4
    snapshot_exists_v4 "${target}" || die 'TARGET scomparsa.'
    snapshot_is_rw_v4 "${target}" || die 'TARGET non RW.'
    write_target_manifest_v4 "${target}" "${RPMDB_POST_MANIFEST}" || die 'manifest TARGET non generabile.'
    cmp -s -- "${RPMDB_EXPECTED_MANIFEST}" "${RPMDB_POST_MANIFEST}" ||
        die 'manifest RPM TARGET diverso dal manifest atteso del piano.'
    verify_target_packages_v4 "${target}" || die 'pacchetti critici mancanti nella TARGET.'
    [[ "$(target_os_id_v4 "${target}")" == "${REQUIRED_OS_ID}" ]] || die 'OS ID TARGET inatteso.'
    snapshot_is_bootable_v4 "${STATE_SOURCE}" || die 'SOURCE non piu bootable.'
    ensure_snapshot_bootable_v4 "${target}" || die 'TARGET non resa bootable.'
    STATE_RPMDB_POST_HASH="$(manifest_hash "${RPMDB_POST_MANIFEST}")" || die 'hash manifest TARGET non calcolabile.'
    STATE_FINISHED="$(date -u +%FT%TZ)"
    persist_state
    set_phase_v4 target-verified
}

commit_target_v4() {
    local target="$1"
    [[ "$(active_snapshot_v4)" == "${STATE_SOURCE}" ]] || die 'SOURCE non e piu attiva.'
    [[ "$(default_snapshot_v4)" == "${STATE_SOURCE}" ]] || die 'SOURCE non e piu default.'
    assert_source_unchanged_v4
    assert_target_window_v4
    snapshot_is_bootable_v4 "${STATE_SOURCE}" || die 'SOURCE non bootable prima del commit.'
    ensure_snapshot_bootable_v4 "${target}" || die 'TARGET non bootable prima del commit.'
    snapshot_is_rw_v4 "${target}" || die 'TARGET non RW prima del commit.'

    set_phase_v4 committing
    sync || die 'sync barrier fallita: close non eseguito.'
    tukit close "${target}" || die 'tukit close fallito; eseguire recover.'

    [[ "$(default_snapshot_v4)" == "${target}" ]] || die 'close concluso ma default non e TARGET; eseguire recover.'
    snapshot_is_rw_v4 "${target}" || die 'TARGET default ma non RW.'
    snapshot_is_bootable_v4 "${STATE_SOURCE}" || die 'SOURCE non bootable dopo close.'
    snapshot_is_bootable_v4 "${target}" || die 'TARGET non bootable dopo close.'

    STATE_STATUS=pending-reboot
    STATE_LAST_ERROR=
    persist_state
    set_phase_v4 pending-reboot
}

upgrade_v4() {
    local target answer
    require_rc1_mutations
    prepare_upgrade_plan
    require_v4_commands
    verify_tukit_cli_surface_v4 || die 'CLI tukit incompatibile.'
    path_is_outside_root_snapshot /var || die '/var deve essere esterna alla root snapshot.'
    check_transactional_update_idle_v4
    check_esp_space_v4 || die 'ESP non pronta.'

    load_state
    [[ "${STATE_STATUS}" == planned ]] || die "piano non pronto: stato=${STATE_STATUS}."
    set_tx_paths
    printf 'RC1: SOURCE=%s TXID=%s. Digita esattamente: AVVIA TARGET RC1 %s\n> ' \
        "${STATE_SOURCE}" "${STATE_TXID}" "${STATE_TXID}"
    IFS= read -r answer
    [[ "${answer}" == "AVVIA TARGET RC1 ${STATE_TXID}" ]] || die 'upgrade RC1 annullato.'

    STATE_BOOT_ID_BEFORE="$(current_boot_id)"
    persist_state
    target="$(open_target_v4)"
    load_meta_v4
    snapshot_exists_v4 "${target}" || die 'TARGET non trovata dopo open.'
    snapshot_is_rw_v4 "${target}" || die 'TARGET creata ma non RW.'

    if ! run_dup_in_target_v4 "${target}"; then
        STATE_LAST_ERROR='zypper dup nella TARGET fallito; TARGET non committata.'
        persist_state
        warn 'dup fallito: SOURCE non modificata. Eseguire abort o recover.'
        return 1
    fi

    verify_target_v4 "${target}"
    commit_target_v4 "${target}"
    log "TARGET ${target} verificata e resa default. Stato pending-reboot."
    log 'Riavviare la VM e poi eseguire confirm. La RC1 non riavvia automaticamente.'
}

confirm_v4() {
    local active default boot current_hash
    require_root
    acquire_lock
    require_confirm_commands
    require_v4_commands
    load_state
    [[ "${STATE_STATUS}" == pending-reboot ]] || die "confirm richiede pending-reboot, trovato ${STATE_STATUS}."
    set_tx_paths
    load_meta_v4
    active="$(active_snapshot_v4)"
    default="$(default_snapshot_v4)"
    [[ -n "${STATE_TARGET}" && "${active}" == "${STATE_TARGET}" && "${default}" == "${STATE_TARGET}" ]] ||
        die "non siamo nella TARGET attesa (active=${active:-?} default=${default:-?} target=${STATE_TARGET:-?})."
    boot="$(current_boot_id)"
    [[ -n "${STATE_BOOT_ID_BEFORE}" && "${boot}" != "${STATE_BOOT_ID_BEFORE}" ]] ||
        die 'boot_id non cambiato: conferma rifiutata prima di un reboot reale.'
    [[ "$(os_id)" == "${REQUIRED_OS_ID}" ]] || die 'OS ID corrente inatteso.'
    snapshot_is_rw_v4 "${active}" || die 'TARGET attiva non RW.'
    snapshot_is_bootable_v4 "${active}" || die 'TARGET attiva non bootable.'

    write_live_manifest_v4 "${RPMDB_POST_MANIFEST}.confirm" || die 'manifest corrente non generabile.'
    cmp -s -- "${RPMDB_EXPECTED_MANIFEST}" "${RPMDB_POST_MANIFEST}.confirm" ||
        die 'manifest corrente diverso dal manifest atteso: confirm rifiutato.'
    current_hash="$(manifest_hash "${RPMDB_POST_MANIFEST}.confirm")" || die 'hash manifest corrente non calcolabile.'
    [[ -z "${STATE_RPMDB_POST_HASH}" || "${current_hash}" == "${STATE_RPMDB_POST_HASH}" ]] ||
        die 'hash RPMDB corrente diverso dalla TARGET verificata prima del reboot.'

    STATE_STATUS=confirmed
    STATE_LAST_ERROR=
    STATE_FINISHED="$(date -u +%FT%TZ)"
    persist_state
    set_phase_v4 confirmed
    history_or_warn confirm-v4 "target=${STATE_TARGET} source=${STATE_SOURCE} rpmdb_post=${current_hash}"
    log "RC1 confermata sulla TARGET ${STATE_TARGET}; SOURCE ${STATE_SOURCE} conservata."
}

abort_v4() {
    require_rc1_mutations
    require_root
    acquire_lock
    require_recovery_commands
    require_v4_commands
    load_state
    set_tx_paths
    load_meta_v4
    case "${STATE_STATUS}" in
        prepared|in-progress) ;;
        *) die "abort consentito solo in prepared/in-progress, trovato ${STATE_STATUS}." ;;
    esac
    [[ -n "${STATE_TARGET}" ]] || die 'TARGET non nota: abort automatico rifiutato.'
    [[ "$(default_snapshot_v4)" == "${STATE_SOURCE}" ]] || die 'default non e SOURCE: abort rifiutato.'
    [[ "$(active_snapshot_v4)" == "${STATE_SOURCE}" ]] || die 'SOURCE non e attiva: abort rifiutato.'
    abort_target_v4 "${STATE_TARGET}"
    STATE_STATUS=aborted
    STATE_LAST_ERROR=
    persist_state
    set_phase_v4 aborted
    history_or_warn abort-v4 "target=${STATE_TARGET} source=${STATE_SOURCE}"
    log "TARGET ${STATE_TARGET} abortita; SOURCE ${STATE_SOURCE} invariata."
}

recover_v4() {
    local active default
    require_rc1_mutations
    require_root
    acquire_lock
    require_recovery_commands
    require_v4_commands
    load_state
    [[ -n "${STATE_TXID}" ]] && set_tx_paths
    load_meta_v4
    active="$(active_snapshot_v4)"
    default="$(default_snapshot_v4)"

    case "${STATE_STATUS}" in
        planned)
            log 'Piano valido presente; nessuna TARGET aperta da recuperare.'
            ;;
        prepared|in-progress)
            if [[ "${V4_PHASE}" == target-open-ambiguous && -z "${STATE_TARGET}" ]]; then
                die "tukit open ambiguo: cercare manualmente la TARGET con txid=${STATE_TXID}; nessun retry/abort automatico."
            fi
            [[ -n "${STATE_TARGET}" ]] || die 'TARGET assente nello stato: recovery automatica rifiutata.'
            if [[ "${active}" == "${STATE_TARGET}" ]]; then
                [[ "${default}" == "${STATE_TARGET}" ]] ||
                    die "TARGET attiva ma default=${default:-?}: recovery ambigua."
                STATE_STATUS=pending-reboot
                persist_state
                set_phase_v4 pending-reboot
                log 'TARGET gia attiva/default; passaggio a pending-reboot. Eseguire confirm.'
            elif [[ "${default}" == "${STATE_SOURCE}" && "${active}" == "${STATE_SOURCE}" ]]; then
                abort_target_v4 "${STATE_TARGET}"
                STATE_STATUS=aborted
                STATE_LAST_ERROR=
                persist_state
                set_phase_v4 aborted
                log 'TARGET non committata abortita; SOURCE invariata.'
            elif [[ "${default}" == "${STATE_TARGET}" && "${active}" == "${STATE_SOURCE}" ]]; then
                snapshot_is_rw_v4 "${STATE_TARGET}" || die 'TARGET default ma non RW.'
                snapshot_is_bootable_v4 "${STATE_SOURCE}" || die 'SOURCE non bootable.'
                snapshot_is_bootable_v4 "${STATE_TARGET}" || die 'TARGET non bootable.'
                STATE_STATUS=pending-reboot
                persist_state
                set_phase_v4 pending-reboot
                log 'Commit gia avvenuto; TARGET default e SOURCE ancora attiva. Riavviare e poi confirm.'
            else
                die "recovery ambigua: active=${active:-?} default=${default:-?} source=${STATE_SOURCE:-?} target=${STATE_TARGET:-?}."
            fi
            ;;
        pending-reboot)
            if [[ "${active}" == "${STATE_TARGET}" && "${default}" == "${STATE_TARGET}" ]]; then
                log 'Boot nella TARGET rilevato: eseguire confirm.'
            elif [[ "${active}" == "${STATE_SOURCE}" && "${default}" == "${STATE_TARGET}" ]]; then
                log 'TARGET e default ma SOURCE e ancora attiva: riavviare, poi confirm.'
            else
                die "pending-reboot incoerente: active=${active:-?} default=${default:-?}."
            fi
            ;;
        confirmed|aborted)
            log "Nessuna recovery pendente (${STATE_STATUS})."
            ;;
        '')
            log 'Nessuna transazione v4 RC1 registrata.'
            ;;
        *)
            die "stato ${STATE_STATUS} non gestito automaticamente dalla recovery RC1."
            ;;
    esac
}

status_v4() {
    require_root
    load_state
    [[ -n "${STATE_TXID}" ]] && set_tx_paths
    load_meta_v4
    printf 'Versione: %s\n' "${RC1_VERSION}"
    printf 'Snapshot attiva: %s\n' "$(active_snapshot_v4 || true)"
    printf 'Snapshot default: %s\n' "$(default_snapshot_v4 || true)"
    printf 'Stato: %s\n' "${STATE_STATUS:-nessuna transazione}"
    printf 'Fase v4: %s\n' "${V4_PHASE:-nessuna}"
    printf 'TXID: %s\n' "${STATE_TXID:-nessuno}"
    printf 'SOURCE: %s\n' "${STATE_SOURCE:-nessuna}"
    printf 'TARGET: %s\n' "${STATE_TARGET:-nessuna}"
    printf 'TARGET aperta UTC: %s\n' "${V4_TARGET_OPENED_UTC:-n/a}"
    printf 'Ultimo errore: %s\n' "${STATE_LAST_ERROR:-nessuno}"
    printf 'Mutazioni RC1: %s\n' "$(rc1_mutations_enabled && printf abilitate || printf bloccate)"
}

design_v4() {
    cat <<'EOF_DESIGN'
State machine RC1:
  plan -> planned
  upgrade -> prepared/target-opening -> target-prepared
          -> in-progress/target-updating -> target-verifying
          -> target-verified -> committing
          -> pending-reboot
  reboot -> confirm -> confirmed

Recovery fail-closed:
  SOURCE active/default + TARGET non committata -> abort TARGET
  SOURCE active + TARGET default               -> pending-reboot
  TARGET active/default                        -> pending-reboot, mai abort
  tukit open ambiguo                           -> nessun retry automatico
  ogni altra combinazione                      -> stop manuale
EOF_DESIGN
}

main() {
    local command="${1:-}"
    case "${command}" in
        status)  (( $# == 1 )) || die 'status non accetta argomenti.'; status_v4 ;;
        check)   (( $# == 1 )) || die 'check non accetta argomenti.'; preflight_v4; log 'Preflight v4 RC1 superato.' ;;
        plan)    (( $# == 1 )) || die 'plan non accetta argomenti.'; make_plan ;;
        upgrade) (( $# == 1 )) || die 'upgrade non accetta argomenti.'; upgrade_v4 ;;
        confirm) (( $# == 1 )) || die 'confirm non accetta argomenti.'; confirm_v4 ;;
        recover) (( $# == 1 )) || die 'recover non accetta argomenti.'; recover_v4 ;;
        abort)   (( $# == 1 )) || die 'abort non accetta argomenti.'; abort_v4 ;;
        prune)   (( $# <= 2 )) || die "uso: ${PROG} prune [GIORNI]"; prune_artifacts "${2:-30}" ;;
        design)  (( $# == 1 )) || die 'design non accetta argomenti.'; design_v4 ;;
        rollback) die 'rollback automatico non ancora abilitato in RC1; SOURCE resta bootable per recovery VM.' ;;
        -h|--help|help|'') rc1_usage ;;
        *) rc1_usage >&2; die "comando sconosciuto: ${command}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
