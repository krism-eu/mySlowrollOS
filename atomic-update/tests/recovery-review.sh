#!/usr/bin/env bash
# No real snapshots, RPM transactions, boot writes or reboot calls.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
export MYSLOWROLL_AUTO_REBOOT=0
export MYSLOWROLL_CACHE_MIN_MARGIN_BYTES=10
export MYSLOWROLL_ROOT_MIN_MARGIN_BYTES=20
source atomic-update/atomic-update-5.7.1.sh
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
run() {
    if ( "$2" ); then
        printf 'PASS: %s\n' "$1"
        passed=$((passed + 1))
    else
        fail "$1"
    fi
}

rollback_fixture() {
    fixture="$(mktemp -d "${test_root}/rollback.XXXXXX")"
    printf '10\n' >"${fixture}/active"
    printf '20\n' >"${fixture}/default"
    STATE_STATUS=needs-inspection
    STATE_INSPECTION_KIND=boot-mismatch
    STATE_SOURCE=10
    STATE_TARGET=20
    STATE_TXID=11111111-1111-4111-8111-111111111111
    STATE_BOOT_ID_BEFORE=22222222-2222-4222-8222-222222222222
    mode=success
    preflight() { :; }
    load_state() {
        if [[ -s "${fixture}/state" ]]; then
            IFS='|' read -r STATE_STATUS STATE_INSPECTION_KIND STATE_SOURCE STATE_TARGET STATE_BOOT_ID_BEFORE <"${fixture}/state"
        fi
    }
    persist_state_or_die() {
        printf '%s|%s|%s|%s|%s\n' "$STATE_STATUS" "$STATE_INSPECTION_KIND" "$STATE_SOURCE" "$STATE_TARGET" "$STATE_BOOT_ID_BEFORE" >"${fixture}/state"
        printf '%s\n' "$STATE_STATUS" >>"${fixture}/states"
    }
    history_or_warn() { :; }
    active_snapshot() { cat "${fixture}/active"; }
    default_snapshot() { cat "${fixture}/default"; }
    current_boot_id() { printf '22222222-2222-4222-8222-222222222222\n'; }
    snapshot_exists() { :; }
    snapshot_is_rw() { :; }
    snapshot_os_id() { printf 'opensuse-slowroll\n'; }
    snapshot_is_bootable() { :; }
    check_boot_space() { :; }
    ensure_snapshot_bootable() { :; }
    pgrep() { return 1; }
    snapper() {
        if [[ "$1" == --csvout ]]; then
            [[ ! -e "${fixture}/owned" ]] || cat "${fixture}/owned"
            return 0
        fi
        [[ "$*" == "-c root rollback --description mySlowrollOS atomic-update rollback ${STATE_TXID} source=10 10" ]] || fail "unexpected snapper call: $*"
        printf 'called\n' >>"${fixture}/snapper-calls"
        [[ "$mode" != before-error ]] || return 9
        printf '30,"mySlowrollOS atomic-update rollback %s source=10"\n' "$STATE_TXID" >"${fixture}/owned"
        printf '30\n' >"${fixture}/default"
        [[ "$mode" != after-error ]] || return 9
    }
}

rollback_failed_boot() {
    rollback_fixture
    rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' >/dev/null || fail 'rollback rejected'
    assert_eq "$STATE_STATUS" rollback-pending
    assert_eq "$STATE_TARGET" 30
    ! grep -qx aborted "${fixture}/states" || fail 'unsafe terminal-state gap'
    printf '30\n' >"${fixture}/active"
    current_boot_id() { printf '33333333-3333-4333-8333-333333333333\n'; }
    recover >/dev/null || fail 'rollback confirmation failed'
    assert_eq "$STATE_STATUS" rolled-back
}
rollback_active_target() {
    rollback_fixture
    STATE_INSPECTION_KIND=target-active-or-default
    printf '20\n' >"${fixture}/active"
    rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' >/dev/null || fail 'active TARGET recovery rejected'
    assert_eq "$STATE_STATUS" rollback-pending
}
rollback_cancel() {
    rollback_fixture
    if ( rollback 10 <<< 'NO' ) >/dev/null 2>&1; then fail 'cancellation accepted'; fi
    [[ ! -e "${fixture}/state" && ! -e "${fixture}/snapper-calls" ]] || fail 'cancellation mutated state'
}
rollback_guards() {
    rollback_fixture
    for kind in open-ambiguous close-ambiguous pre-close-sync-failed abort-ambiguous; do
        STATE_INSPECTION_KIND="$kind"
        if ( rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' ) >/dev/null 2>&1; then fail "accepted $kind"; fi
    done
    STATE_INSPECTION_KIND=boot-mismatch
    if ( rollback 11 <<< 'ROLLBACK 11 E RIAVVIA' ) >/dev/null 2>&1; then fail 'accepted foreign rollback source'; fi
    printf '99\n' >"${fixture}/default"
    if ( rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' ) >/dev/null 2>&1; then fail 'accepted foreign default'; fi
    [[ ! -e "${fixture}/snapper-calls" ]] || fail 'guard invoked snapper'
}
rollback_before_stage() {
    rollback_fixture
    mode=before-error
    if ( rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' ) >/dev/null 2>&1; then fail 'failed snapper accepted'; fi
    load_state
    assert_eq "$STATE_INSPECTION_KIND" rollback-recovery
    assert_eq "$STATE_TARGET" 20
    recover >/dev/null || fail 'interrupted rollback recovery failed'
    assert_eq "$STATE_INSPECTION_KIND" boot-mismatch
    assert_eq "$STATE_TARGET" 20
    mode=success
    rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' >/dev/null || fail 'retry with confirmation failed'
    assert_eq "$STATE_TARGET" 30
}
rollback_after_stage() {
    rollback_fixture
    mode=after-error
    if ( rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' ) >/dev/null 2>&1; then fail 'ambiguous snapper accepted'; fi
    recover >/dev/null || fail 'staged rollback recovery failed'
    assert_eq "$STATE_STATUS" rollback-pending
    assert_eq "$STATE_TARGET" 30
}
rollback_foreign_default() {
    rollback_fixture
    mode=before-error
    if ( rollback 10 <<< 'ROLLBACK 10 E RIAVVIA' ) >/dev/null 2>&1; then fail 'failed snapper accepted'; fi
    printf '99\n' >"${fixture}/default"
    if ( recover ) >/dev/null 2>&1; then fail 'foreign default adopted as rollback'; fi
    load_state
    assert_eq "$STATE_INSPECTION_KIND" rollback-recovery
    assert_eq "$STATE_TARGET" 20
}
ordinary_rollback_stays_strict() {
    rollback_fixture
    STATE_STATUS=confirmed
    if prepare_rollback 10 >/dev/null 2>&1; then fail 'ordinary rollback accepted active/default mismatch'; fi
    [[ ! -e "${fixture}/snapper-calls" ]] || fail 'ordinary rollback called snapper'
}

space_fixture() {
    TX_PKG_CACHE=/test/cache
    fixture_cache_uuid=shared
    fixture_root_uuid=shared
    free_bytes=100
    xml_summary_attribute() { case "$2" in download-size) printf '70\n';; space-usage-installed) printf '60\n';; esac; }
    available_bytes() { printf '%s\n' "$free_bytes"; }
    findmnt() {
        [[ "$*" == '-n -o UUID --target '* ]] || fail 'pool check did not use UUID'
        case "${*: -1}" in /) printf '%s\n' "$fixture_root_uuid";; *) printf '%s\n' "$fixture_cache_uuid";; esac
    }
}
shared_pool() {
    space_fixture
    if check_plan_space ignored >/dev/null 2>&1; then fail 'shared pool counted twice'; fi
    free_bytes=160
    check_plan_space ignored || fail 'sufficient shared pool rejected'
}
separate_pools() {
    space_fixture
    fixture_cache_uuid=separate
    check_plan_space ignored || fail 'independent pools rejected'
    fixture_root_uuid=
    if check_plan_space ignored >/dev/null 2>&1; then fail 'unknown UUID accepted'; fi
}

epoch_normalization() {
    fixture="$(mktemp -d "${test_root}/manifest.XXXXXX")"
    rpm() { printf '%s\n' 'zero|0:1-1|x86_64' 'absent|1-1|noarch' 'nonzero|2:1-1|x86_64' 'gpg-pubkey|1-1|noarch'; }
    tukit_call() { shift; "$@"; }
    write_rpm_manifest_host "${fixture}/host" || fail 'host manifest failed'
    write_target_manifest 20 "${fixture}/target" || fail 'target manifest failed'
    cmp -s "${fixture}/host" "${fixture}/target" || fail 'host/TARGET normalization differs'
    printf '%s\n' 'absent|1-1|noarch' 'nonzero|2:1-1|x86_64' 'zero|1-1|x86_64' >"${fixture}/expected"
    cmp -s "${fixture}/host" "${fixture}/expected" || fail 'epoch normalization incorrect'
    assert_eq "$(rpmdb_hash_host)" "$(sha256sum "${fixture}/expected" | awk '{print $1}')"
    rpm() { return 9; }
    if write_rpm_manifest_host "${fixture}/bad"; then fail 'RPM failure swallowed'; fi
}
critical_batch() {
    fixture="$(mktemp -d "${test_root}/packages.XXXXXX")"
    tukit_call() {
        printf 'called\n' >>"${fixture}/calls"
        assert_eq "$1 $2 $3 $4" '20 rpm --quiet -q'
        shift 4
        assert_eq "$*" "${CRITICAL_PKGS[*]}"
    }
    verify_target_packages 20 || fail 'batched package query failed'
    assert_eq "$(wc -l <"${fixture}/calls")" 1
    tukit_call() { return 1; }
    if verify_target_packages 20; then fail 'missing critical package accepted'; fi
}
description_capability() {
    tukit() { printf 'open call close abort\n'; }
    sdbootutil() { printf 'add-all-kernels is-bootable remove-all-kernels cleanup --disable-predictions\n'; }
    if verify_cli_surface; then fail 'missing --description accepted'; fi
    tukit() { printf 'open call close abort --description\n'; }
    verify_cli_surface || fail 'supported CLI rejected'
}
hash_failure() {
    TX_CACHE_DIR="$(mktemp -d "${test_root}/hash.XXXXXX")"
    install_summary_count() { printf '1\n'; }
    xmllint() { case "$1" in --xpath) printf '<install-summary/>';; --c14n) return 9;; esac; }
    if plan_hash ignored >/dev/null; then fail 'failed canonicalization accepted'; fi
}
aborted_message() {
    fixture="$(mktemp -d "${test_root}/message.XXXXXX")"
    persist_state_or_die() { :; }
    history_or_warn() { :; }
    mark_aborted 'download failed' 2>"${fixture}/stderr"
    assert_eq "$STATE_STATUS" aborted
    assert_eq "$STATE_LAST_ERROR" 'download failed'
    grep -Fq 'download failed' "${fixture}/stderr" || fail 'reason not printed'
}
inspect_failure() {
    rollback_fixture
    find_owned_targets() { return 9; }
    if recover_inspect >"${fixture}/out" 2>&1; then fail 'failed enumeration reported success'; fi
    grep -Fq 'unknown (Snapper enumeration failed)' "${fixture}/out" || fail 'missing diagnostic'
    ! grep -Fq 'Owned TARGETs by description: none' "${fixture}/out" || fail 'false empty list'
}

run 'failed boot -> explicit rollback -> reboot -> rolled-back' rollback_failed_boot
run 'explicit rollback from active TARGET' rollback_active_target
run 'cancel leaves state/default unchanged' rollback_cancel
run 'unrelated recovery kinds and snapshots refused' rollback_guards
run 'interruption before default change permits confirmed retry' rollback_before_stage
run 'interruption after default change recovers staged rollback' rollback_after_stage
run 'foreign default not adopted after interrupted rollback' rollback_foreign_default
run 'ordinary rollback retains active/default equality' ordinary_rollback_stays_strict
run 'shared pool budget and exact boundary' shared_pool
run 'separate pools and missing UUID' separate_pools
run 'epoch absent/zero/nonzero and RPM failures' epoch_normalization
run 'one critical-package query with failure propagation' critical_batch
run 'tukit --description capability required' description_capability
run 'XML canonicalization failure rejected' hash_failure
run 'aborted reason printed and retained' aborted_message
run 'Snapper enumeration failure reported as unknown' inspect_failure
printf 'Focused review regressions: %s PASS\n' "$passed"
