#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
# Source without executing main, then mock only the external system boundaries.
source atomic-update/atomic-update-5.7.1.sh
STATE_TXID=11111111-1111-4111-8111-111111111111
STATE_SOURCE=10
STATE_TARGET=
STATE_STATUS=needs-inspection
STATE_INSPECTION_KIND=open-ambiguous

snapper() {
    printf '20,"mySlowrollOS atomic-update %s"\n' "${STATE_TXID}"
    printf '21,"other transaction"\n'
}
actual="$(find_owned_targets)"
[[ "${actual}" == 20 ]] || { echo "FAIL: TARGET missing from Snapper enumeration" >&2; exit 1; }
# Most importantly: last nonmatching row must not change the function status.
snapper() {
    printf '20,"mySlowrollOS atomic-update %s"\n' "${STATE_TXID}"
    return 9
}
if find_owned_targets >/dev/null 2>&1; then
    echo "FAIL: Snapper command failure incorrectly accepted" >&2
    exit 1
fi

preflight() { :; }
load_state() { :; }
active_snapshot() { printf '10\n'; }
default_snapshot() { printf '10\n'; }
persist_state_or_die() { printf 'UNSAFE_PERSIST\n'; }
history_or_warn() { :; }
snapshot_exists() { :; }
snapper() {
    printf '20,"mySlowrollOS atomic-update %s"\n' "${STATE_TXID}"
    printf '21,"not ours"\n'
}
out="$(recover_clear_opening 2>&1 || true)"
[[ "${out}" != *UNSAFE_PERSIST* ]] || { echo "FAIL: clear-opening ignored owned TARGET" >&2; exit 1; }
snapper() { return 9; }
out="$(recover_clear_opening 2>&1 || true)"
[[ "${out}" != *UNSAFE_PERSIST* ]] || { echo "FAIL: clear-opening ignored Snapper failure" >&2; exit 1; }

df() { return 9; }
if available_bytes /nope >/dev/null 2>&1; then
    echo "FAIL: df command failure lost" >&2; exit 1
fi
df() { printf 'Avail\n'; }
if available_bytes /nope >/dev/null 2>&1; then
    echo "FAIL: missing df numeric output accepted" >&2; exit 1
fi
unset -f df

tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
TX_CACHE_DIR="${tmp}"
RPMDB_EXPECTED_MANIFEST="${tmp}/expected.tsv"
RPMDB_POST_MANIFEST="${tmp}/post.tsv"
printf 'pkg|1-1|x86_64\n' >"${RPMDB_EXPECTED_MANIFEST}"
cp "${RPMDB_EXPECTED_MANIFEST}" "${RPMDB_POST_MANIFEST}"
STATE_PLAN_HASH="$(printf x | sha256sum | awk '{print $1}')"
STATE_RPMDB_POST_HASH="$(sha256sum "${RPMDB_POST_MANIFEST}" | awk '{print $1}')"
STATE_TARGET=20
snapshot_exists() { :; }
snapshot_is_rw() { :; }
snapshot_os_id() { printf 'opensuse-slowroll\n'; }
resolve_owned_target() { printf '20\n'; }
active_snapshot() { printf '20\n'; }
rpm() { :; }
write_rpm_manifest_host() { cp "${RPMDB_POST_MANIFEST}" "$1"; }
verified_target_evidence 20 || { echo "FAIL: valid TARGET verification evidence rejected" >&2; exit 1; }
write_rpm_manifest_host() { printf 'different|2-1|x86_64\n' >"$1"; }
if verified_target_evidence 20; then
    echo "FAIL: differing TARGET RPM manifest accepted" >&2; exit 1
fi
printf 'atomic-update mocked recovery regressions: PASS\n'
