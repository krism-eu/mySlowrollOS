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

# Agama has installed Snapper, but snapperd/systemd does not run in chroot.
# Preserve installer-created SUBVOLUME/QGROUP, changing only verified keys.
configure_snapper_root_file() {
  local config="$1" key
  [[ -f "$config" ]] || { echo "mySlowrollOS: missing Snapper root config: $config" >&2; return 1; }
  for key in NUMBER_CLEANUP NUMBER_LIMIT NUMBER_LIMIT_IMPORTANT NUMBER_MIN_AGE \
             TIMELINE_CREATE EMPTY_PRE_POST_CLEANUP; do
    if [[ "$(grep -Ec "^${key}=" "$config")" != 1 ]]; then
      echo "mySlowrollOS: unexpected Snapper key count: $key" >&2
      return 1
    fi
  done
  sed -i \
    -e 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' \
    -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="4-4"/' \
    -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="0-0"/' \
    -e 's/^NUMBER_MIN_AGE=.*/NUMBER_MIN_AGE="3600"/' \
    -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' \
    -e 's/^EMPTY_PRE_POST_CLEANUP=.*/EMPTY_PRE_POST_CLEANUP="yes"/' \
    "$config"
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

  cat > "$dir/snapper-root.conf" <<'SNAPPER_TEST'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP="1/0"
NUMBER_CLEANUP="yes"
NUMBER_LIMIT="2-10"
NUMBER_LIMIT_IMPORTANT="4-10"
NUMBER_MIN_AGE="3600"
TIMELINE_CREATE="no"
EMPTY_PRE_POST_CLEANUP="yes"
SNAPPER_TEST
  configure_snapper_root_file "$dir/snapper-root.conf" || exit 1
  for setting in 'NUMBER_CLEANUP="yes"' 'NUMBER_LIMIT="4-4"' \
                 'NUMBER_LIMIT_IMPORTANT="0-0"' 'NUMBER_MIN_AGE="3600"' \
                 'TIMELINE_CREATE="no"' 'EMPTY_PRE_POST_CLEANUP="yes"' \
                 'QGROUP="1/0"' 'SUBVOLUME="/"'; do
    grep -Fxq "$setting" "$dir/snapper-root.conf" || exit 1
  done
  cp "$dir/snapper-root.conf" "$dir/once.conf"
  configure_snapper_root_file "$dir/snapper-root.conf" || exit 1
  cmp -s "$dir/snapper-root.conf" "$dir/once.conf" || exit 1
  printf '%s\n' 'NUMBER_LIMIT="99"' >> "$dir/snapper-root.conf"
  if configure_snapper_root_file "$dir/snapper-root.conf"; then
    echo 'FAIL: duplicate Snapper setting accepted' >&2
    exit 1
  fi
  if configure_snapper_root_file "$dir/missing.conf"; then
    echo 'FAIL: missing Snapper root accepted' >&2
    exit 1
  fi
  echo 'PASS: BLS default entry validator refuses missing/foreign/invalid entries'
  echo 'PASS: Snapper retention 4/0, preserves Agama root config, idempotent, fail-closed'
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

# Apply tested retention before first boot, without deleting any snapshots.
configure_snapper_root_file /etc/snapper/configs/root
echo 'mySlowrollOS: Snapper root retention configured before first reboot'
exit 0
