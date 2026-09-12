#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: run as root: sudo ./install.sh" >&2
    exit 1
fi

if ! command -v transactional-update >/dev/null 2>&1; then
    echo "ERROR: transactional-update not found. microRaku v0.1 targets openSUSE MicroOS only." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/microraku"
STAGE="/root/.microraku-stage-$$"

cleanup() {
    rm -rf "$STAGE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p \
    "$STATE_DIR/overlay/upper" \
    "$STATE_DIR/overlay/work" \
    "$STATE_DIR/state" \
    "$STATE_DIR/base-rpmdb"
touch "$STATE_DIR/packages.list"
chmod 755 "$STATE_DIR" "$STATE_DIR/state" "$STATE_DIR/base-rpmdb"
chmod 700 "$STATE_DIR/overlay" "$STATE_DIR/overlay/upper" "$STATE_DIR/overlay/work"
chmod 644 "$STATE_DIR/packages.list"

mkdir -p "$STAGE"
cp -a "$SCRIPT_DIR/dracut" "$STAGE/"
cp -a "$SCRIPT_DIR/lib" "$STAGE/"
cp -a "$SCRIPT_DIR/systemd" "$STAGE/"
cp -a "$SCRIPT_DIR/bin" "$STAGE/"

cat > "$STAGE/apply-root.sh" <<'APPLY'
#!/bin/bash
set -euo pipefail
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install -Dm755 "$BASE/dracut/module-setup.sh" /usr/lib/dracut/modules.d/90microraku/module-setup.sh
install -Dm755 "$BASE/dracut/mount-overlay.sh" /usr/lib/dracut/modules.d/90microraku/mount-overlay.sh
install -Dm755 "$BASE/lib/sync.sh" /usr/libexec/microraku/sync.sh
install -Dm644 "$BASE/systemd/microraku-sync.service" /usr/lib/systemd/system/microraku-sync.service

for tool in microraku-install microraku-list microraku-remove microraku-reset; do
    install -Dm755 "$BASE/bin/$tool" "/usr/bin/$tool"
done

install -d /etc/systemd/system/multi-user.target.wants
ln -sfn /usr/lib/systemd/system/microraku-sync.service \
    /etc/systemd/system/multi-user.target.wants/microraku-sync.service
APPLY
chmod 700 "$STAGE/apply-root.sh"

echo "==> Staging microRaku files in a new MicroOS snapshot..."
transactional-update run "$STAGE/apply-root.sh"

echo "==> Rebuilding initrd in the same transactional chain..."
transactional-update --continue initrd

echo
echo "microRaku v0.1 has been staged successfully."
echo "Reboot is required before using microraku-install."
echo "After reboot, verify with: findmnt /usr"
