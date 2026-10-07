#!/usr/bin/env bash
set -euo pipefail

# First-boot policy for mySlowrollOS.
# Runs through Agama init scripts, when the installed system and systemd
# are fully operational. User creation/passwords remain an Agama decision.

systemctl set-default graphical.target

# Select SDDM explicitly.
ln -sfn /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

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
