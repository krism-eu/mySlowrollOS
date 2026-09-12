#!/bin/bash
set -euo pipefail

STATE="/var/lib/microraku"
PACKAGES="$STATE/packages.list"
BASE_DB="$STATE/base-rpmdb"
PENDING="$STATE/rebuild-pending"
PREVIOUS="$STATE/overlay/previous-upper"

log() { echo "[microraku-sync] $*"; }

if ! findmnt -n -o FSTYPE /usr 2>/dev/null | grep -qx overlay; then
    log "ERROR: /usr is not an overlay mount"
    exit 1
fi

[[ -e "$PENDING" ]] || exit 0
[[ -f "$PACKAGES" ]] || touch "$PACKAGES"

LOCKDIR="/run/microraku.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "ERROR: another microRaku operation is active"
    exit 75
fi
cleanup() { rmdir "$LOCKDIR" 2>/dev/null || true; }
on_error() {
    local rc=$?
    touch "$STATE/recreate-pending"
    log "reconciliation failed; a clean rebuild is scheduled for next boot"
    return "$rc"
}
trap cleanup EXIT
trap on_error ERR

mapfile -t DESIRED < <(grep -Ev '^[[:space:]]*(#|$)' "$PACKAGES" | sort -u)
TO_INSTALL=()

for pkg in "${DESIRED[@]}"; do
    # If the current MicroOS lower already provides the requested package,
    # leave it entirely to the base. Keeping it in packages.list is useful:
    # a later rollback to a base without it will cause it to be installed again.
    if rpm --dbpath "$BASE_DB" -q -- "$pkg" >/dev/null 2>&1; then
        log "$pkg is provided by the current base"
    else
        TO_INSTALL+=("$pkg")
    fi
done

if (( ${#TO_INSTALL[@]} > 0 )); then
    log "refreshing repositories"
    zypper --non-interactive refresh
    log "rebuilding overlay packages: ${TO_INSTALL[*]}"
    zypper --non-interactive install --no-recommends -- "${TO_INSTALL[@]}"
else
    log "no overlay packages need installation for this base"
fi

rm -f "$PENDING" "$STATE/recreate-pending"
rm -rf "$PREVIOUS"
date -Iseconds > "$STATE/state/last-sync"
log "reconciliation complete"
