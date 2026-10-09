#!/usr/bin/env bash
set -euo pipefail

# First-boot runtime policy for mySlowrollOS.
# The native SDDM/default-target symlinks are already prepared offline by
# post-chroot-boot-policy.sh so the very first boot can reach SDDM directly.

# yast2-bootloader writes /etc/kernel/cmdline AFTER Agama's post/chroot scripts,
# and can inherit failsafe options from the live installer ISO on x86_64.
# Keep only the installed system's ordinary options and enforce AppArmor.
sanitize_kernel_cmdline() {
  local token cleaned=""
  for token in $1; do
    case "$token" in
      ide=nodma|apm=off|noresume|edd=off|nomodeset|3|security=*|systemd.show_status=*|quiet)
        continue ;;
    esac
    cleaned="${cleaned:+$cleaned }$token"
  done
  printf '%s\n' "${cleaned:+$cleaned }security=apparmor systemd.show_status=1 quiet"
}

# Edit only verified stock btrfsmaintenance keys, keeping distro defaults intact.
# The distro's refresh service will own the timer schedule; no custom daemon.
configure_btrfsmaintenance() {
  local config="$1" key
  [[ -f "$config" ]] || return 1
  for key in BTRFS_BALANCE_PERIOD BTRFS_DEFRAG_PERIOD BTRFS_TRIM_PERIOD \
             BTRFS_SCRUB_PERIOD BTRFS_SCRUB_PRIORITY BTRFS_SCRUB_MOUNTPOINTS; do
    [[ "$(grep -Ec "^$key=" "$config")" == 1 ]] || return 1
  done
  sed -i \
    -e 's/^BTRFS_BALANCE_PERIOD=.*/BTRFS_BALANCE_PERIOD="none"/' \
    -e 's/^BTRFS_DEFRAG_PERIOD=.*/BTRFS_DEFRAG_PERIOD="none"/' \
    -e 's/^BTRFS_TRIM_PERIOD=.*/BTRFS_TRIM_PERIOD="none"/' \
    -e 's/^BTRFS_SCRUB_PERIOD=.*/BTRFS_SCRUB_PERIOD="monthly"/' \
    -e 's/^BTRFS_SCRUB_PRIORITY=.*/BTRFS_SCRUB_PRIORITY="idle"/' \
    -e 's@^BTRFS_SCRUB_MOUNTPOINTS=.*@BTRFS_SCRUB_MOUNTPOINTS="/"@' \
    "$config"
}

# Disable startup only, without masking: another dependency may still request
# a unit, and package removal is postponed until the separate RPM audit.
disable_optional_unit() {
  local unit="$1" state
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|linked|linked-runtime)
      if ! systemctl disable "$unit"; then
        echo "myslowroll-firstboot: cannot disable optional unit $unit" >&2
        firstboot_rc=1
      fi
      ;;
    disabled|masked|static|indirect|generated|alias|not-found|'') ;;
    *) echo "myslowroll-firstboot: unknown state for $unit ($state)" >&2; firstboot_rc=1 ;;
  esac
}

# Functional regression tests without privileged actions or running services.
if [[ "${1:-}" == "--self-test" ]]; then
  sample='root=/dev/vda1 rw ide=nodma apm=off noresume edd=off nomodeset 3 mitigations=auto security= rootflags=subvol=0/.snapshots/1/snapshot'
  expected='root=/dev/vda1 rw mitigations=auto rootflags=subvol=0/.snapshots/1/snapshot security=apparmor systemd.show_status=1 quiet'
  [[ "$(sanitize_kernel_cmdline "$sample")" == "$expected" ]] || exit 1
  [[ "$(sanitize_kernel_cmdline "$expected")" == "$expected" ]] || exit 1
  # Test the shipped file, not only a hand-picked canonical string.
  shipped_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/myslowroll-policy/kernel-cmdline"
  shipped="$(<"$shipped_file")"
  [[ "$(sanitize_kernel_cmdline "$shipped")" == "$shipped" ]] || {
    echo 'FAIL: shipped cmdline would trigger a needless firstboot rewrite' >&2
    exit 1
  }
  maintenance_test="$(mktemp)" || exit 1
  trap 'rm -f -- "$maintenance_test"' EXIT
  cat >"$maintenance_test" <<'TEST_BTRFS'
BTRFS_BALANCE_PERIOD="weekly"
BTRFS_DEFRAG_PERIOD="monthly"
BTRFS_TRIM_PERIOD="monthly"
BTRFS_SCRUB_PERIOD="weekly"
BTRFS_SCRUB_PRIORITY="normal"
BTRFS_SCRUB_MOUNTPOINTS="auto"
BTRFS_ALLOW_CONCURRENCY="false"
TEST_BTRFS
  configure_btrfsmaintenance "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_BALANCE_PERIOD="none"' "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_DEFRAG_PERIOD="none"' "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_TRIM_PERIOD="none"' "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_SCRUB_PERIOD="monthly"' "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_SCRUB_PRIORITY="idle"' "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_SCRUB_MOUNTPOINTS="/"' "$maintenance_test" || exit 1
  grep -Fxq 'BTRFS_ALLOW_CONCURRENCY="false"' "$maintenance_test" || exit 1
  configure_btrfsmaintenance "$maintenance_test" || exit 1
  [[ "$(grep -c '^BTRFS_BALANCE_PERIOD=' "$maintenance_test")" == 1 ]] || exit 1
  printf '%s\n' 'BTRFS_BALANCE_PERIOD="daily"' >>"$maintenance_test"
  if configure_btrfsmaintenance "$maintenance_test"; then
    echo 'FAIL: duplicate config key accepted' >&2
    exit 1
  fi
  echo 'PASS: Btrfs timer policy, one root scrub, preservation, idempotence'
  echo 'PASS: failsafe removed, root/subvolume preserved, shipped cmdline idempotent'
  exit 0
fi

# Repair the installer cmdline before the remaining first-boot policy.
# An sdbootutil failure must be reported but must not skip service setup.
# Storage and EFI choices remain entirely interactive in Agama.
firstboot_rc=0
cmdline_file=/etc/kernel/cmdline
if [[ ! -f "$cmdline_file" ]]; then
  echo "myslowroll-firstboot: missing $cmdline_file" >&2
  firstboot_rc=1
else
  before="$(<"$cmdline_file")"
  after="$(sanitize_kernel_cmdline "$before")"
  if [[ "$before" != "$after" ]]; then
    echo "myslowroll-firstboot: normalizing installed kernel options" >&2
    backup_ok=1
    if [[ ! -e "$cmdline_file.agama-before-repair" ]] &&
       ! cp -a -- "$cmdline_file" "$cmdline_file.agama-before-repair"; then
      echo "myslowroll-firstboot: cannot back up kernel cmdline" >&2
      backup_ok=0
      firstboot_rc=1
    fi
    if (( backup_ok == 1 )); then
      if ! printf '%s\n' "$after" > "$cmdline_file"; then
        echo "myslowroll-firstboot: cannot write kernel cmdline" >&2
        firstboot_rc=1
      elif ! command -v sdbootutil >/dev/null 2>&1; then
        echo "myslowroll-firstboot: sdbootutil missing; boot entries were not updated" >&2
        firstboot_rc=1
      elif ! sdbootutil update-all-entries; then
        echo "myslowroll-firstboot: sdbootutil failed; boot entries may be stale" >&2
        firstboot_rc=1
      fi
    fi
  else
    echo "myslowroll-firstboot: kernel command line already clean"
  fi
  if grep -Eq '(^|[[:space:]])(ide=nodma|apm=off|noresume|edd=off|nomodeset|3|security=)([[:space:]]|$)' "$cmdline_file"; then
    echo "myslowroll-firstboot: failsafe options still present in $cmdline_file" >&2
    firstboot_rc=1
  fi
  if grep -Eq '(^|[[:space:]])(3|nomodeset)([[:space:]]|$)' /proc/cmdline; then
    echo "myslowroll-firstboot: current boot still has failsafe options; restart once for graphical boot" >&2
  fi
fi

systemctl set-default graphical.target

# Defensive check: keep the native SDDM selector authoritative.
if [[ "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)" != "/usr/lib/systemd/system/sddm.service" ]]; then
  systemctl disable --now display-manager-legacy.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/display-manager.service
  ln -s /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service
  systemctl daemon-reload
fi

# Persist trust for the OBS repository used by criscore/atomic-update.
# Agama's gpgFingerprints authenticates the installation repository but does
# not globally import that key for future package verification.
if [[ -f /etc/zypp/repos.d/home_krism.key ]]; then
  rpm --import /etc/zypp/repos.d/home_krism.key
fi

# Apply intended runtime service policy.
if ! systemctl enable NetworkManager.service firewalld.service bluetooth.service; then
  echo "myslowroll-firstboot: cannot enable NetworkManager, firewalld or Bluetooth" >&2
  firstboot_rc=1
fi
systemctl disable NetworkManager-wait-online.service || true
systemctl disable smartd.service smartd_generate_opts.path || true
systemctl disable snapper-timeline.timer || true
systemctl disable sshd.service sshd.socket || true
systemctl disable display-manager-legacy.service || true
systemctl disable ModemManager.service || true
if ! systemctl mask ModemManager.service; then
  echo "myslowroll-firstboot: cannot mask ModemManager" >&2
  firstboot_rc=1
fi

# Initial radio policy: services stay available and radio switches remain usable.
# Unlike boot timers, this firstboot script runs only once. Changes made in
# Plasma after installation are NOT forcibly reverted at every later boot.
if command -v nmcli >/dev/null 2>&1; then
  if ! systemctl is-active --quiet NetworkManager.service; then
    systemctl start NetworkManager.service || firstboot_rc=1
  fi
  if systemctl is-active --quiet NetworkManager.service; then
    if ! LC_ALL=C nmcli radio wifi off ||
       [[ "$(LC_ALL=C nmcli radio wifi)" != disabled ]]; then
      echo 'myslowroll-firstboot: initial Wi-Fi OFF state not confirmed' >&2
      firstboot_rc=1
    fi
  else
    echo 'myslowroll-firstboot: NetworkManager inactive; Wi-Fi state unverified' >&2
    firstboot_rc=1
  fi
else
  echo 'myslowroll-firstboot: nmcli missing' >&2
  firstboot_rc=1
fi

# BlueZ stays enabled for manual operation. AutoEnable=false covers newly
# detected adapters; start the service now to verify the initial OFF state.
if ! systemctl is-active --quiet bluetooth.service; then
  if ! systemctl start bluetooth.service; then
    echo 'myslowroll-firstboot: cannot start Bluetooth for initial radio check' >&2
    firstboot_rc=1
  fi
fi
if systemctl is-active --quiet bluetooth.service; then
  if ! grep -Eq '^AutoEnable=false$' /etc/bluetooth/main.conf; then
    echo 'myslowroll-firstboot: BlueZ AutoEnable=false missing' >&2
    firstboot_rc=1
  fi
  if command -v bluetoothctl >/dev/null 2>&1; then
    bt_controllers="$(LC_ALL=C bluetoothctl --timeout 5 list 2>/dev/null || true)"
    if grep -q '^Controller ' <<<"$bt_controllers"; then
      if ! LC_ALL=C bluetoothctl --timeout 5 power off >/dev/null 2>&1; then
        echo 'myslowroll-firstboot: Bluetooth controller could not be powered off' >&2
        firstboot_rc=1
      else
        bt_state="$(LC_ALL=C bluetoothctl --timeout 5 show 2>/dev/null || true)"
        if ! grep -Eq '^[[:space:]]*Powered: no([[:space:]]|$)' <<<"$bt_state"; then
          echo 'myslowroll-firstboot: Bluetooth OFF state could not be confirmed' >&2
          firstboot_rc=1
        fi
      fi
    fi
  fi
else
  echo 'myslowroll-firstboot: Bluetooth inactive; initial radio state unverified' >&2
  firstboot_rc=1
fi

# Native Btrfs timer policy approved for this single-disk Btrfs+ext4 PC.
# No periodic balance/defrag/Btrfs TRIM; monthly low-priority root scrub;
# weekly fstrim.timer covers ext4 /home as well.
if configure_btrfsmaintenance /etc/sysconfig/btrfsmaintenance; then
  if ! systemctl start btrfsmaintenance-refresh.service; then
    echo 'myslowroll-firstboot: stock Btrfs timer refresh failed' >&2
    firstboot_rc=1
  fi
  for unit in btrfs-balance.timer btrfs-defrag.timer btrfs-trim.timer; do
    disable_optional_unit "$unit"
  done
  if ! systemctl enable --now btrfs-scrub.timer fstrim.timer; then
    echo 'myslowroll-firstboot: cannot enable scrub/fstrim timers' >&2
    firstboot_rc=1
  fi
else
  echo 'myslowroll-firstboot: unexpected/missing stock Btrfs config' >&2
  firstboot_rc=1
fi

# Only disable optional storage units after confirming the installed layout.
# Agama storage/partitioning remains entirely interactive. On RAID/LVM or
# remote NVMe systems, keep their own boot services. Never mask/remove them.
if ! command -v lsblk >/dev/null 2>&1; then
  echo 'myslowroll-firstboot: lsblk missing, retaining optional storage boot units' >&2
elif ! storage_types="$(lsblk -nr -o TYPE 2>/dev/null)"; then
  echo 'myslowroll-firstboot: cannot inspect disk layout, retaining storage units' >&2
else
  if grep -Eq '^(raid[0-9]*|md)$' <<<"$storage_types"; then
    echo 'myslowroll-firstboot: md RAID detected, retaining md boot units'
  else
    for unit in mdcheck_start.timer mdcheck_continue.timer mdmonitor-oneshot.timer; do
      disable_optional_unit "$unit"
    done
  fi
  if grep -Eq '^(lvm|mpath)$' <<<"$storage_types"; then
    echo 'myslowroll-firstboot: device-mapper volumes detected, retaining LVM units'
  else
    disable_optional_unit lvm2-monitor.service
    disable_optional_unit blk-availability.service
  fi
fi
# NVMe-over-Fabrics detection must fail closed: if the probe is unavailable,
# do not deactivate auto-connections used by a different installation.
if command -v nvme >/dev/null 2>&1; then
  if fabrics="$(LC_ALL=C nvme list-subsys 2>/dev/null)"; then
    if grep -Eq 'trtype=(tcp|rdma|fc)' <<<"$fabrics"; then
      echo 'myslowroll-firstboot: NVMe fabrics detected, retaining autoconnect'
    else
      disable_optional_unit nvmefc-boot-connections.service
      disable_optional_unit nvmf-autoconnect.service
    fi
  fi
fi
# Back In Time is manual-only. XDG Hidden=true override is delivered by Agama;
# keep the Qt application in the menu; never install a backup autostart daemon.
if ! grep -Fxq 'Hidden=true' /etc/xdg/autostart/backintime.desktop; then
  echo 'myslowroll-firstboot: Back In Time autostart suppression missing' >&2
  firstboot_rc=1
fi

# Keep root Snapper but disable timeline snapshots. Cleanup remains available.
if [[ -f /etc/snapper/configs/root ]]; then
  if grep -q '^TIMELINE_CREATE=' /etc/snapper/configs/root; then
    sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
  else
    printf '%s\n' 'TIMELINE_CREATE="no"' >> /etc/snapper/configs/root
  fi
fi

exit "$firstboot_rc"
