#!/usr/bin/env bash
set -euo pipefail

# Offline/chroot boot policy applied before the first reboot.
# Deliberately contains only filesystem operations: no running systemd is needed.

install -d -m 0755 /etc/systemd/system

# Boot directly to the graphical target.
ln -sfn /usr/lib/systemd/system/graphical.target   /etc/systemd/system/default.target

# Do not let the openSUSE legacy display-manager wrapper win the first boot.
rm -f /etc/systemd/system/graphical.target.wants/display-manager-legacy.service
rm -f /etc/systemd/system/display-manager.service

# Select native SDDM directly before the first boot.
ln -s /usr/lib/systemd/system/sddm.service   /etc/systemd/system/display-manager.service

exit 0
