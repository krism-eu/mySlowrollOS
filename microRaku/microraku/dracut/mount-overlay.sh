#!/bin/bash
# Fail-safe dracut pre-pivot hook for openSUSE MicroOS.
# The system must remain bootable when microRaku cannot mount its overlay.
set -u

[[ -f /lib/dracut-lib.sh ]] && . /lib/dracut-lib.sh

mr_info() {
    if declare -F info >/dev/null 2>&1; then info "microRaku: $*"; else echo "microRaku: $*"; fi
}
mr_warn() {
    if declare -F warn >/dev/null 2>&1; then warn "microRaku: $*"; else echo "microRaku WARNING: $*" >&2; fi
}

NEWROOT="${NEWROOT:-/sysroot}"
STATE="$NEWROOT/var/lib/microraku"
OVERLAY="$STATE/overlay"
UPPER="$OVERLAY/upper"
WORK="$OVERLAY/work"
PREVIOUS="$OVERLAY/previous-upper"
BASE_DB="$STATE/base-rpmdb"
BASE_ID_FILE="$STATE/state/base-id"
REBUILD_PENDING="$STATE/rebuild-pending"
RESET_PENDING="$STATE/reset-pending"
RECREATE_PENDING="$STATE/recreate-pending"
PACKAGES_LIST="$STATE/packages.list"
LOWER="$NEWROOT/usr"
BASE_DB_SRC="$LOWER/lib/sysimage/rpm"

if command -v getargbool >/dev/null 2>&1; then
    if getargbool 0 microraku=0 || getargbool 0 nomicroraku; then
        mr_info "disabled by kernel command line"
        exit 0
    fi
fi

if ! findmnt -n "$NEWROOT/var" >/dev/null 2>&1; then
    mr_warn "/var is not mounted in initrd; continuing without overlay"
    exit 0
fi

if [[ ! -d "$BASE_DB_SRC" ]]; then
    mr_warn "base RPM database not found at $BASE_DB_SRC; continuing without overlay"
    exit 0
fi

mkdir -p "$STATE/state" "$OVERLAY" "$UPPER" "$WORK"
touch "$PACKAGES_LIST"

# Reset is intentionally deferred to initrd so we never delete the mounted
# live upper directory from a running system.
if [[ -e "$RESET_PENDING" ]]; then
    mr_info "reset requested; discarding persistent package layer"
    rm -rf "$UPPER" "$WORK" "$PREVIOUS"
    mkdir -p "$UPPER" "$WORK"
    : > "$PACKAGES_LIST"
    rm -f "$REBUILD_PENDING" "$RECREATE_PENDING" "$RESET_PENDING"
fi

# Package removal is applied as a clean upper-layer rebuild on the next boot.
# This avoids OverlayFS whiteouts over files owned by the immutable lower.
if [[ -e "$RECREATE_PENDING" ]]; then
    mr_info "clean rebuild requested"
    rm -rf "$PREVIOUS"
    if [[ -d "$UPPER" && -n "$(find "$UPPER" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        mv "$UPPER" "$PREVIOUS"
    else
        rm -rf "$UPPER"
    fi
    rm -rf "$WORK"
    mkdir -p "$UPPER" "$WORK"
    rm -f "$RECREATE_PENDING"
    touch "$REBUILD_PENDING"
fi

CURRENT_ID="$(findmnt -nr -o FSROOT "$NEWROOT" 2>/dev/null || true)"
if [[ -z "$CURRENT_ID" ]]; then
    CURRENT_ID="$(findmnt -nr -o SOURCE "$NEWROOT" 2>/dev/null || true)"
fi
if [[ -z "$CURRENT_ID" ]]; then
    mr_warn "cannot identify active MicroOS root snapshot; continuing without overlay"
    exit 0
fi

SAVED_ID="$(cat "$BASE_ID_FILE" 2>/dev/null || true)"
BASE_CHANGED=0
[[ "$CURRENT_ID" != "$SAVED_ID" ]] && BASE_CHANGED=1

if [[ $BASE_CHANGED -eq 1 || -z "$(find "$BASE_DB" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    mr_info "new base snapshot detected: $CURRENT_ID"

    TMP_DB="$STATE/base-rpmdb.new"
    rm -rf "$TMP_DB"
    mkdir -p "$TMP_DB"
    if ! cp -a "$BASE_DB_SRC/." "$TMP_DB/"; then
        rm -rf "$TMP_DB"
        mr_warn "failed to snapshot base RPM database; continuing without overlay"
        exit 0
    fi
    rm -rf "$BASE_DB"
    mv "$TMP_DB" "$BASE_DB"

    # Never carry arbitrary upper files blindly across a base update/rollback.
    # Preserve one backup for recovery and rebuild the active layer from the
    # desired package list after userspace/network are available.
    if [[ -d "$UPPER" && -n "$(find "$UPPER" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        rm -rf "$PREVIOUS"
        mv "$UPPER" "$PREVIOUS"
    else
        rm -rf "$UPPER"
    fi
    rm -rf "$WORK"
    mkdir -p "$UPPER" "$WORK"
    touch "$REBUILD_PENDING"
fi

mr_info "mounting persistent overlay on $LOWER"
if mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" \
    "$LOWER"; then
    printf '%s\n' "$CURRENT_ID" > "$BASE_ID_FILE"
    date -Iseconds > "$STATE/state/last-mount"
    mr_info "overlay mounted"
    exit 0
fi

mr_warn "overlay mount failed; booting clean MicroOS base"
exit 0
