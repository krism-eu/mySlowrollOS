#!/bin/bash
set -euo pipefail

STATE="/var/lib/microraku"
PACKAGES="$STATE/packages.list"
BASE_DB="$STATE/base-rpmdb"
PENDING="$STATE/rebuild-pending"
RECREATE="$STATE/recreate-pending"
PREVIOUS="$STATE/overlay/previous-upper"
ZYPP_CACHE="$STATE/cache/zypp"
PKG_CACHE="$STATE/cache/packages"
MODIFIED_BASE="$STATE/state/modified-base.tsv"
ETC_DRIFT="$STATE/state/etc-drift.log"

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
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

mkdir -p "$STATE/state" "$ZYPP_CACHE" "$PKG_CACHE"
touch "$PKG_CACHE/.keep_packages" "$PKG_CACHE/.no_auto_prune"

etc_signature() {
    if command -v sha256sum >/dev/null 2>&1; then
        LC_ALL=C find /etc -xdev -printf '%P\t%y\t%s\t%T@\n' 2>/dev/null | LC_ALL=C sort | sha256sum | awk '{print $1}'
    else
        printf 'unavailable\n'
    fi
}

refresh_modified_base() {
    local tmp name base_evr live_evr
    tmp="$(mktemp)"
    while IFS=$'\t' read -r name base_evr; do
        [[ -n "$name" ]] || continue
        live_evr="$(rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' -- "$name" 2>/dev/null || true)"
        if ! grep -qxF "$base_evr" <<< "$live_evr"; then
            live_evr="$(tr '\n' ',' <<< "$live_evr" | sed 's/,$//')"
            printf '%s\t%s\t%s\n' "$name" "$base_evr" "${live_evr:-<missing>}" >> "$tmp"
        fi
    done < <(rpm --dbpath "$BASE_DB" -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort -u)
    mv "$tmp" "$MODIFIED_BASE"
}

critical_override_present() {
    [[ -s "$MODIFIED_BASE" ]] || return 1
    awk -F '\t' '$1 ~ /^(filesystem|glibc|rpm|libzypp|zypper|transactional-update|systemd|dracut|snapper|btrfsprogs|grub2|grub2-.*|shim|kernel|kernel-.*|aaa_base)$/ { found=1 } END { exit !found }' "$MODIFIED_BASE"
}

mapfile -t DESIRED < <(grep -Ev '^[[:space:]]*(#|$)' "$PACKAGES" | LC_ALL=C sort -u)
TO_INSTALL=()
for pkg in "${DESIRED[@]}"; do
    if rpm --dbpath "$BASE_DB" -q -- "$pkg" >/dev/null 2>&1; then
        log "$pkg is provided by the current base"
    else
        TO_INSTALL+=("$pkg")
    fi
done

ZYPPER=(zypper --non-interactive --cache-dir "$ZYPP_CACHE" --pkg-cache-dir "$PKG_CACHE" --userdata microraku-sync)
ETC_BEFORE="$(etc_signature)"

if (( ${#TO_INSTALL[@]} > 0 )); then
    log "refreshing repositories into private cache"
    if ! "${ZYPPER[@]}" refresh; then
        log "WARNING: repository refresh failed; trying retained metadata/RPM cache"
    fi

    log "rebuilding overlay packages: ${TO_INSTALL[*]}"
    set +e
    "${ZYPPER[@]}" --no-refresh install --solver-focus Installed --no-force-resolution --no-recommends -- "${TO_INSTALL[@]}"
    RC=$?
    set -e
    if (( RC != 0 )); then
        touch "$RECREATE"
        log "ERROR: zypper returned $RC; keeping desired state and previous-upper, clean retry scheduled for next boot"
        exit "$RC"
    fi
else
    log "no overlay packages need installation for this base"
fi

refresh_modified_base
if critical_override_present; then
    touch "$RECREATE"
    log "ERROR: reconciliation overrode a critical MicroOS base package; clean retry scheduled"
    log "details: $MODIFIED_BASE"
    exit 4
fi

ETC_AFTER="$(etc_signature)"
if [[ "$ETC_BEFORE" != "unavailable" && "$ETC_AFTER" != "unavailable" && "$ETC_BEFORE" != "$ETC_AFTER" ]]; then
    printf '%s\tsync\t%s\n' "$(date -Iseconds)" "${TO_INSTALL[*]:-none}" >> "$ETC_DRIFT"
    log "WARNING: /etc changed during reconciliation; see $ETC_DRIFT"
fi

rm -f "$PENDING" "$RECREATE"
rm -rf "$PREVIOUS"
date -Iseconds > "$STATE/state/last-sync"
log "reconciliation complete"
