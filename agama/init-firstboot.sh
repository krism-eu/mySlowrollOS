#!/usr/bin/env bash
set -euo pipefail

# First-boot runtime policy for mySlowrollOS.
# The native SDDM/default-target symlinks are already prepared offline by
# post-chroot-boot-policy.sh so the very first boot can reach SDDM directly.

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
