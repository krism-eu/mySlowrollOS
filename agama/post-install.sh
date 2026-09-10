#!/usr/bin/env bash
set -euo pipefail

# mySlowrollOS conservative runtime policy.
# User, storage and passwords are deliberately left to Agama UI.
# Locale, keymap and timezone are preset by the Agama profile.

# Desktop target; package presets remain responsible for the concrete services.
systemctl set-default graphical.target

# A desktop does not need to block boot waiting for network-online.
systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || true

# This workstation has no WWAN modem. Keep ModemManager installed if pulled as
# a dependency, but do not start it by default. It can be enabled later.
systemctl disable ModemManager.service >/dev/null 2>&1 || true

# Keep the journal useful for diagnostics and rollback, but bounded.
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-myslowroll.conf <<'EOF'
[Journal]
Compress=yes
SystemMaxUse=128M
RuntimeMaxUse=64M
MaxRetentionSec=7day
EOF

# Do not disable NetworkManager, firewalld, AppArmor, Bluetooth, CUPS/Avahi,
# Snapper or Btrfs maintenance here: they are intentional workstation features.
