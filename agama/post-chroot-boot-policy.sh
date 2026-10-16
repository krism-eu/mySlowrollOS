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

# Agama may mount the EFI System Partition at /boot or /boot/efi.
# Check the exact mountpoint: --target alone can report the parent mount.
find_esp_mountpoint() {
  local candidate info target fstype
  for candidate in /boot/efi /boot; do
    info="$(findmnt -n -o TARGET,FSTYPE --target "$candidate" 2>/dev/null || true)"
    read -r target fstype <<< "$info"
    if [[ "$target" == "$candidate" && "$fstype" == vfat ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
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

# Back In Time ships an autostart .desktop that starts pw-cache and must never
# autolaunch on this workstation. The reviewed Hidden=true override is
# delivered by Agama to a neutral path; the package owns
# /etc/xdg/autostart/backintime.desktop, so the override is installed here with
# an atomic replace and verified byte-for-byte before the first reboot.
install_backintime_override() {
  local asset="${BACKINTIME_OVERRIDE_ASSET:-/var/lib/myslowroll/backintime-autostart-disabled.desktop}"
  local dest="${BACKINTIME_OVERRIDE_DEST:-/etc/xdg/autostart/backintime.desktop}"
  local owner="${BACKINTIME_OVERRIDE_OWNER:-0}"
  local group="${BACKINTIME_OVERRIDE_GROUP:-0}"
  local tmp sections
  [[ -f "$asset" && ! -L "$asset" ]] || { echo "mySlowrollOS: backintime override asset missing or not a regular file: $asset" >&2; return 1; }
  sections="$(grep -Ec '^[[:space:]]*\[Desktop Entry\][[:space:]]*$' "$asset")"
  [[ "$sections" -eq 1 ]] || { echo "mySlowrollOS: backintime override must have exactly one [Desktop Entry] section: $asset" >&2; return 1; }
  grep -Fxq 'Hidden=true' "$asset" || { echo "mySlowrollOS: backintime override missing Hidden=true: $asset" >&2; return 1; }
  if grep -Fq 'backintime pw-cache start' "$asset"; then
    echo "mySlowrollOS: backintime override must not contain an autostart pw-cache command: $asset" >&2
    return 1
  fi
  install -d -m 0755 "$(dirname "$dest")"
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  install -m 0644 -o "$owner" -g "$group" "$asset" "$tmp" || return 1
  mv -fT "$tmp" "$dest"
  cmp -s "$asset" "$dest" || { echo "mySlowrollOS: backintime override verification failed: $dest" >&2; return 1; }
  echo "mySlowrollOS: Back In Time autostart suppressed (Hidden=true) -> $dest"
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

  # Exercise exact ESP detection for both layouts, without touching host mounts.
  findmnt() {
    local target="${@: -1}"
    case "${MOCK_ESP_LAYOUT:-none}:$target" in
      boot:/boot/efi|boot:/boot) printf '/boot vfat\n' ;;
      efi:/boot/efi) printf '/boot/efi vfat\n' ;;
      efi:/boot) printf '/boot btrfs\n' ;;
      none:*) printf '/ btrfs\n' ;;
      *) return 1 ;;
    esac
  }
  [[ "$(MOCK_ESP_LAYOUT=boot find_esp_mountpoint)" == /boot ]] || exit 1
  [[ "$(MOCK_ESP_LAYOUT=efi find_esp_mountpoint)" == /boot/efi ]] || exit 1
  if MOCK_ESP_LAYOUT=none find_esp_mountpoint; then exit 1; fi
  unset -f findmnt

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
  # Back In Time: atomically replace an RPM-provided autostart file with the
  # reviewed Hidden=true override, then verify content, single section, mode 0644
  # and absence of the original pw-cache command. Idempotent by design.
  mkdir -p "$dir/xdg/autostart" "$dir/assets"
  printf '[Desktop Entry]\nType=Application\nName=Back In Time\nExec=/bin/sh -c "backintime pw-cache start 2>&1 >/dev/null"\n' > "$dir/xdg/autostart/backintime.desktop"
  printf '[Desktop Entry]\nType=Application\nName=Back In Time (manual only)\nHidden=true\n' > "$dir/assets/backintime-autostart-disabled.desktop"
  BACKINTIME_OVERRIDE_ASSET="$dir/assets/backintime-autostart-disabled.desktop" \
  BACKINTIME_OVERRIDE_DEST="$dir/xdg/autostart/backintime.desktop" \
  BACKINTIME_OVERRIDE_OWNER="$(id -u)" BACKINTIME_OVERRIDE_GROUP="$(id -g)" \
  install_backintime_override || exit 1
  cmp -s "$dir/assets/backintime-autostart-disabled.desktop" "$dir/xdg/autostart/backintime.desktop" || { echo 'FAIL: backintime override not byte-identical to asset' >&2; exit 1; }
  grep -Fxq 'Hidden=true' "$dir/xdg/autostart/backintime.desktop" || { echo 'FAIL: backintime override missing Hidden=true' >&2; exit 1; }
  [[ "$(grep -Ec '^[[:space:]]*\[Desktop Entry\][[:space:]]*$' "$dir/xdg/autostart/backintime.desktop")" -eq 1 ]] || { echo 'FAIL: backintime override has multiple Desktop Entry sections' >&2; exit 1; }
  [[ "$(stat -c '%a' "$dir/xdg/autostart/backintime.desktop")" == "644" ]] || { echo 'FAIL: backintime override wrong mode' >&2; exit 1; }
  if grep -Fq 'backintime pw-cache start' "$dir/xdg/autostart/backintime.desktop"; then echo 'FAIL: backintime original Exec retained' >&2; exit 1; fi
  BACKINTIME_OVERRIDE_ASSET="$dir/assets/backintime-autostart-disabled.desktop" \
  BACKINTIME_OVERRIDE_DEST="$dir/xdg/autostart/backintime.desktop" \
  BACKINTIME_OVERRIDE_OWNER="$(id -u)" BACKINTIME_OVERRIDE_GROUP="$(id -g)" \
  install_backintime_override || exit 1
  echo 'PASS: Back In Time autostart suppressed atomically and idempotently'
  echo 'PASS: BLS default entry validator refuses missing/foreign/invalid entries'
  echo 'PASS: ESP detection accepts exact /boot and /boot/efi vfat mounts'
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

# Apply Snapper retention independently of boot-entry validation, without
# deleting snapshots. A later EFI/bootloader error must not skip this policy.
configure_snapper_root_file /etc/snapper/configs/root || exit 1
echo 'mySlowrollOS: Snapper root retention configured before first reboot'

# Back In Time: replace any package-provided autostart file with the reviewed
# Hidden=true override. Runs after packages are installed and before first boot.
install_backintime_override || exit 1

# Hostname: ensure a consistent and clean mDNS hostname
if [[ ! -s /etc/hostname || "$(< /etc/hostname)" =~ ^(localhost|localhost\.localdomain)?$ ]]; then
  echo "myslowrollos" > /etc/hostname
  echo 'mySlowrollOS: hostname set to myslowrollos'
fi

# fstab hardening & optimization: umask=0077 for /boot/efi, noatime for Btrfs
if [[ -f /etc/fstab ]]; then
  python3 -c '
path = "/etc/fstab"
lines = []
with open(path, "r") as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 6:
            # Add umask=0077 to vfat ESP
            if parts[1] == "/boot/efi" and parts[2] == "vfat":
                if "umask=0077" not in parts[3]:
                    parts[3] = parts[3] + ",umask=0077"
            # Add noatime to btrfs
            if parts[2] == "btrfs":
                if "noatime" not in parts[3]:
                    parts[3] = parts[3] + ",noatime"
            lines.append(f"{parts[0]:<43} {parts[1]:<12} {parts[2]:<6} {parts[3]:<28} {parts[4]}  {parts[5]}\n")
        else:
            lines.append(line)
with open(path, "w") as f:
    f.writelines(lines)
' 2>/dev/null || true
  echo 'mySlowrollOS: /etc/fstab updated with umask=0077 for ESP and noatime for Btrfs'
fi

# Wallpaper: install default branded dark wallpaper for SDDM and Plasma
if [[ -f /var/lib/myslowroll/wallpaper.png ]]; then
  install -d -m 0755 /usr/share/wallpapers/Next/contents/images
  install -m 0644 /var/lib/myslowroll/wallpaper.png /usr/share/wallpapers/Next/contents/images/5120x2880.png
  install -m 0644 /var/lib/myslowroll/wallpaper.png /usr/share/wallpapers/Next/contents/images/1920x1080.png
  echo 'mySlowrollOS: default dark wallpaper installed into /usr/share/wallpapers/Next'
fi

# Baloo: configure lightweight file-name-only indexing (no heavy content scraping)
install -d -m 0755 /etc/xdg
cat > /etc/xdg/baloofilerc <<'BALOO_EOF'
[Basic Settings]
indexing=true
index hidden folders=false
only basic metadata=true
BALOO_EOF

# AppImage: native desktop executor so double-clicking runs seamlessly without terminal
cat > /usr/bin/myslowroll-appimage-run <<'APPIMAGE_RUN_EOF'
#!/usr/bin/env bash
set -e
target="$1"
if [[ -f "$target" ]]; then
    if [[ ! -x "$target" ]]; then
        chmod +x "$target" 2>/dev/null || true
    fi
    exec "$target" "$@"
fi
APPIMAGE_RUN_EOF
chmod 0755 /usr/bin/myslowroll-appimage-run

install -d -m 0755 /usr/share/applications
cat > /usr/share/applications/appimage-executor.desktop <<'APPIMAGE_DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Esegui AppImage
Name[it]=Esegui AppImage
GenericName=AppImage Runner
Comment=Esegue pacchetti AppImage direttamente
Exec=/usr/bin/myslowroll-appimage-run %f
Icon=system-run
Terminal=false
StartupNotify=true
Categories=Utility;
MimeType=application/x-iso9660-appimage;application/vnd.appimage;
NoDisplay=false
APPIMAGE_DESKTOP_EOF

cat >> /etc/xdg/mimeapps.list <<'MIME_EOF'
[Default Applications]
application/vnd.appimage=appimage-executor.desktop
application/x-iso9660-appimage=appimage-executor.desktop

[Added Associations]
application/vnd.appimage=appimage-executor.desktop;
application/x-iso9660-appimage=appimage-executor.desktop;
MIME_EOF

# Agama configures the ESP interactively. Detect the actual EFI mountpoint
# and let sdbootutil choose the real Snapper default BLS entry before reboot.
# Neither a custom hand-written myslowroll.conf nor a hard-coded partition is used.
esp_mount="$(find_esp_mountpoint)" || {
  echo 'mySlowrollOS: no exact vfat ESP mountpoint at /boot or /boot/efi' >&2
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
validate_default_entry "$esp_mount" "$default_entry" || {
  echo "mySlowrollOS: invalid or missing default BLS entry in $esp_mount: $default_entry" >&2
  exit 1
}
echo "mySlowrollOS: installed BLS default verified on $esp_mount: $default_entry"
exit 0
