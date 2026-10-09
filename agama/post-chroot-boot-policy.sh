#!/usr/bin/env bash
set -euo pipefail

# Executed in Agama's installed-system chroot AFTER installation.
# Never repartition, format, choose an ESP, or edit firmware BootOrder.

validate_default_entry() {
  local esp="$1" id="$2" entry
  [[ "$id" =~ ^[A-Za-z0-9._+-]+(\.conf)?$ ]] || return 1
  entry="${esp%/}/loader/entries/${id%.conf}.conf"
  [[ -s "$entry" ]] || return 1
  grep -Eq '^linux[[:space:]]+/' "$entry" || return 1
  grep -Eq '^initrd[[:space:]]+/' "$entry" || return 1
  grep -Eq '^options[[:space:]]+.*root=' "$entry" || return 1
  grep -Eq '^options[[:space:]]+.*rootflags=subvol=.*\.snapshots/[0-9]+/snapshot' "$entry"
}

if [[ "${1:-}" == --self-test ]]; then
  dir="$(mktemp -d)"
  trap 'rm -rf -- "$dir"' EXIT
  mkdir -p "$dir/loader/entries"
  cat > "$dir/loader/entries/snapshot-1.conf" <<'EOF'
title mySlowrollOS
linux /token/kernel/linux-hash
initrd /token/kernel/initrd-hash
options root=UUID=example rw rootflags=subvol=0/.snapshots/1/snapshot
EOF
  validate_default_entry "$dir" snapshot-1 || exit 1
  if validate_default_entry "$dir" ../foreign; then exit 1; fi
  if validate_default_entry "$dir" snapshot-2; then exit 1; fi
  sed -i '/rootflags=/d' "$dir/loader/entries/snapshot-1.conf"
  if validate_default_entry "$dir" snapshot-1; then exit 1; fi
  echo 'PASS: BLS default entry validator refuses missing/foreign/invalid entries'
  exit 0
fi

install -d -m 0755 /etc/systemd/system
ln -sfn /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
rm -f /etc/systemd/system/graphical.target.wants/display-manager-legacy.service
rm -f /etc/systemd/system/display-manager.service
ln -s /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

# SDDM Wayland uses the greeter account's kcminputrc as well as Numlock=on.
# Do not assume the login user's personal config controls the greeter.
test -f /etc/xdg/kcminputrc || { echo 'mySlowrollOS: missing global NumLock configuration' >&2; exit 1; }
getent passwd sddm >/dev/null || { echo 'mySlowrollOS: sddm account missing' >&2; exit 1; }
install -d -m 0700 -o sddm -g sddm /var/lib/sddm/.config
install -m 0600 -o sddm -g sddm /etc/xdg/kcminputrc /var/lib/sddm/.config/kcminputrc

# Agama configures the ESP interactively. Validate that it is mounted and
# let sdbootutil choose the real Snapper default BLS entry *before first reboot*.
# Neither a custom hand-written myslowroll.conf nor a hard-coded partition is used.
[[ "$(findmnt -n -o FSTYPE --target /boot/efi 2>/dev/null)" == vfat ]] || {
  echo 'mySlowrollOS: Agama did not mount a vfat ESP at /boot/efi' >&2
  exit 1
}
command -v sdbootutil >/dev/null || { echo 'mySlowrollOS: sdbootutil missing' >&2; exit 1; }
[[ "$(sdbootutil bootloader)" == *systemd-boot* ]] || {
  echo 'mySlowrollOS: systemd-boot not selected' >&2
  exit 1
}
sdbootutil set-default-snapshot || {
  echo 'mySlowrollOS: cannot make the installed Btrfs snapshot the boot default' >&2
  exit 1
}
default_entry="$(sdbootutil get-default)" || exit 1
validate_default_entry /boot/efi "$default_entry" || {
  echo "mySlowrollOS: invalid or missing default BLS entry: $default_entry" >&2
  exit 1
}
echo "mySlowrollOS: installed BLS default verified: $default_entry"
exit 0
