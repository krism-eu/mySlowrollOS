#!/usr/bin/env bash
set -euo pipefail

# mySlowrollOS conservative runtime policy.
#
# User creation, storage layout, passwords and locale are deliberately left
# to the Agama UI.
#
# This file contains only system-wide runtime decisions intentionally adopted
# by mySlowrollOS.
#
# Storage maintenance, printing/discovery and power-management tuning are left
# at their openSUSE defaults until they can be evaluated on the installed
# system and on the real hardware.

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
ln -sfn /usr/lib/systemd/system/graphical.target     /etc/systemd/system/default.target

ln -sfn /usr/lib/systemd/system/sddm.service     /etc/systemd/system/display-manager.service

# ---------------------------------------------------------------------------
# Local desktop user: Fedora/Anaconda-like passwordless administrator
# ---------------------------------------------------------------------------
MYSLOWROLL_USER="kris"

if ! id "${MYSLOWROLL_USER}" >/dev/null 2>&1; then
    useradd         --create-home         --gid users         --groups wheel         --shell /bin/bash         "${MYSLOWROLL_USER}"
else
    usermod --append --groups wheel "${MYSLOWROLL_USER}"
fi

passwd --delete "${MYSLOWROLL_USER}"
pam-config -a --unix-nullok

install -d -m 0750 /etc/sudoers.d
cat > /etc/sudoers.d/99-myslowroll-passwordless-admin <<EOF
${MYSLOWROLL_USER} ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/99-myslowroll-passwordless-admin
visudo -cf /etc/sudoers.d/99-myslowroll-passwordless-admin >/dev/null

install -d -m 0755 /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/10-myslowroll-passwordless-admin.rules <<EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "${MYSLOWROLL_USER}" &&
        subject.local &&
        subject.active) {
        return polkit.Result.YES;
    }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/10-myslowroll-passwordless-admin.rules

install -d -m 0755 -o "${MYSLOWROLL_USER}" -g users     "/home/${MYSLOWROLL_USER}/.config"
cat > "/home/${MYSLOWROLL_USER}/.config/kdesurc" <<'EOF'
[super-user-command]
super-user-command=sudo
EOF
chown "${MYSLOWROLL_USER}:users" "/home/${MYSLOWROLL_USER}/.config/kdesurc"
chmod 0644 "/home/${MYSLOWROLL_USER}/.config/kdesurc"

# ---------------------------------------------------------------------------
# Persistent local systemd preset policy
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/systemd/system-preset
cat > /etc/systemd/system-preset/10-myslowroll.preset <<'EOF'
# mySlowrollOS local system service policy.

disable NetworkManager-wait-online.service
disable ModemManager.service
disable smartd.service
disable smartd_generate_opts.path
disable snapper-timeline.timer
disable sshd.service
disable sshd.socket
EOF
chmod 0644 /etc/systemd/system-preset/10-myslowroll.preset

# ---------------------------------------------------------------------------
# Network boot behaviour
# ---------------------------------------------------------------------------
systemctl disable NetworkManager-wait-online.service     >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# IPv6
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/sysctl.d
cat > /etc/sysctl.d/20-myslowroll-disable-ipv6.conf <<'EOF'
# mySlowrollOS: keep IPv6 support installed but disabled at runtime.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
chmod 0644 /etc/sysctl.d/20-myslowroll-disable-ipv6.conf

# ---------------------------------------------------------------------------
# WWAN / ModemManager
# ---------------------------------------------------------------------------
systemctl disable ModemManager.service     >/dev/null 2>&1 || true
systemctl mask ModemManager.service     >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Journald
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-myslowroll.conf <<'EOF'
[Journal]
Compress=yes
SystemMaxUse=128M
RuntimeMaxUse=64M
MaxRetentionSec=7day
EOF
chmod 0644 /etc/systemd/journald.conf.d/10-myslowroll.conf

# ---------------------------------------------------------------------------
# SMART monitoring
# ---------------------------------------------------------------------------
systemctl disable     smartd.service     smartd_generate_opts.path     >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Snapper
# ---------------------------------------------------------------------------
if [[ -f /etc/snapper/configs/root ]]; then
    if grep -q '^TIMELINE_CREATE=' /etc/snapper/configs/root; then
        sed -i             's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/'             /etc/snapper/configs/root
    else
        printf '%s
'             'TIMELINE_CREATE="no"'             >> /etc/snapper/configs/root
    fi
fi

systemctl disable snapper-timeline.timer     >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# OpenSSH
# ---------------------------------------------------------------------------
systemctl disable     sshd.service     sshd.socket     >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# SDDM Wayland greeter + Breeze fallback
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-myslowroll-wayland.conf <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell
InputMethod=
Numlock=on

[Wayland]
CompositorCommand=kwin_wayland --no-global-shortcuts --no-lockscreen --locale1
EOF
chmod 0644 /etc/sddm.conf.d/10-myslowroll-wayland.conf

cat > /etc/sddm.conf.d/90-myslowroll-fallback.conf <<'EOF'
[Theme]
Current=breeze
EOF
chmod 0644 /etc/sddm.conf.d/90-myslowroll-fallback.conf

# ---------------------------------------------------------------------------
# Intentionally untouched
# ---------------------------------------------------------------------------
# NetworkManager
# firewalld
# AppArmor
# Bluetooth / BlueZ
# CUPS
# Avahi
# Snapper cleanup
# Btrfs maintenance
# fstrim
# logrotate
# udisks2
# upower
# rtkit
# power-profiles-daemon

exit 0
