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

# Functional regression test of exactly the same normalization code, with no
# privileged actions or calls to systemctl/sdbootutil.
if [[ "${1:-}" == "--self-test" ]]; then
  sample='root=/dev/vda1 rw ide=nodma apm=off noresume edd=off nomodeset 3 mitigations=auto security= rootflags=subvol=0/.snapshots/1/snapshot'
  expected='root=/dev/vda1 rw mitigations=auto rootflags=subvol=0/.snapshots/1/snapshot security=apparmor systemd.show_status=1 quiet'
  [[ "$(sanitize_kernel_cmdline "$sample")" == "$expected" ]] || exit 1
  [[ "$(sanitize_kernel_cmdline "$expected")" == "$expected" ]] || exit 1
  echo 'PASS: inherited failsafe removed, root/subvolume preserved, operation idempotent'
  exit 0
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

# Only repair this installed system's cmdline; partitioning, UUIDs and the
# choice of EFI system partition belong entirely to Agama's interactive UI.
# sdbootutil updates entries belonging to this installed root, not other OSes.
cmdline_file=/etc/kernel/cmdline
if [[ ! -f "$cmdline_file" ]]; then
  echo "myslowroll-firstboot: missing $cmdline_file" >&2
  exit 1
fi
before="$(<"$cmdline_file")"
after="$(sanitize_kernel_cmdline "$before")"
if [[ "$before" != "$after" ]]; then
  echo "myslowroll-firstboot: cleaning inherited installer kernel options" >&2
  if [[ ! -e "$cmdline_file.agama-before-repair" ]]; then
    cp -a -- "$cmdline_file" "$cmdline_file.agama-before-repair"
  fi
  printf '%s\n' "$after" > "$cmdline_file"
  if ! command -v sdbootutil >/dev/null 2>&1; then
    echo "myslowroll-firstboot: sdbootutil missing, cannot refresh this system's boot entries" >&2
    exit 1
  fi
  sdbootutil update-all-entries
  # A failsafe installer boot can force text mode for *this* boot. Never force
  # a Wayland session under a running kernel that still has nomodeset.
  if grep -Eq '(^|[[:space:]])(3|nomodeset)([[:space:]]|$)' /proc/cmdline; then
    echo "myslowroll-firstboot: current boot still has failsafe options; restart once for graphical boot" >&2
  fi
else
  echo "myslowroll-firstboot: kernel command line already clean" >&2
fi
if grep -Eq '(^|[[:space:]])(ide=nodma|apm=off|noresume|edd=off|nomodeset|3|security=)([[:space:]]|$)' "$cmdline_file"; then
  echo "myslowroll-firstboot: failsafe options still present in $cmdline_file" >&2
  exit 1
fi

# Apply intended runtime service policy.
systemctl enable NetworkManager.service firewalld.service || true
systemctl disable NetworkManager-wait-online.service || true
systemctl disable smartd.service smartd_generate_opts.path || true
systemctl disable snapper-timeline.timer || true
systemctl disable sshd.service sshd.socket || true
systemctl disable display-manager-legacy.service || true
systemctl disable ModemManager.service || true
systemctl mask ModemManager.service || true

# Keep root Snapper but disable timeline snapshots. Cleanup remains available.
if [[ -f /etc/snapper/configs/root ]]; then
  if grep -q '^TIMELINE_CREATE=' /etc/snapper/configs/root; then
    sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
  else
    printf '%s\n' 'TIMELINE_CREATE="no"' >> /etc/snapper/configs/root
  fi
fi

exit 0
