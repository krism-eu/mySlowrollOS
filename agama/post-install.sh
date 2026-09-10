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

# Full Slowroll upgrades are manual and guarded by core/myslowroll-atomic-dup.
# Never let transactional-update start an unattended distribution upgrade.
systemctl disable transactional-update.timer >/dev/null 2>&1 || true
systemctl mask transactional-update.timer >/dev/null 2>&1 || true

# Keep the project's solver policy explicit instead of relying on distro
# defaults. This also controls the zypper instance run inside
# transactional-update, which does not accept our dup policy as extra args.
set_zypp_option() {
    local key="$1" value="$2" file=/etc/zypp/zypp.conf escaped
    escaped="${key//./\\.}"

    if grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "${file}"; then
        sed -i -E "s|^[[:space:]]*${escaped}[[:space:]]*=.*$|${key} = ${value}|" "${file}"
    else
        printf '\n%s = %s\n' "${key}" "${value}" >> "${file}"
    fi
}

set_zypp_option solver.onlyRequires true
set_zypp_option solver.dupAllowVendorChange false

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
