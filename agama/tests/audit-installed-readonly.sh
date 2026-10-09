#!/usr/bin/env bash
# Run as the logged-in desktop user after sudo -v. No configuration changes.
set -u
umask 077
report=$(mktemp "${TMPDIR:-/tmp}/myslowroll-review-XXXXXXXX.txt") || exit 1
exec > >(tee "$report") 2>&1
run() {
  printf '\n>>> '; printf '%q ' "$@"; printf '\n'
  timeout 30s "$@"
  rc=$?
  printf '[exit=%s]\n' "$rc"
}
run date -Is
run cat /etc/os-release
run id
run uname -r
run systemctl --failed --no-pager
run systemctl --user --failed --no-pager
run sudo -n journalctl -b -u agama-scripts.service --no-pager -n 250
run sudo -n journalctl -b -1 -u agama-scripts.service --no-pager -n 100
run cat /proc/cmdline /etc/kernel/cmdline
run findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS / /boot/efi /home /var
run lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINTS
run sudo -n btrfs subvolume list /
run sudo -n btrfs subvolume get-default /
run sudo -n bootctl status --no-pager
run sudo -n sdbootutil bootloader
run sudo -n sdbootutil get-default
for unit in NetworkManager bluetooth firewalld chronyd systemd-timesyncd apparmor cups avahi-daemon; do
  run systemctl show "$unit.service" -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result
  run systemctl cat "$unit.service"
done
for unit in cups.socket avahi-daemon.socket snapper-cleanup.timer snapper-timeline.timer btrfs-scrub.timer btrfs-balance.timer btrfs-defrag.timer btrfs-trim.timer fstrim.timer; do
  run systemctl show "$unit" -p LoadState -p ActiveState -p UnitFileState -p Result
  run systemctl cat "$unit"
done
run timedatectl
run chronyc tracking
run sudo -n aa-status
run systemctl list-timers --all --no-pager
run sudo -n snapper -c root get-config
run sudo -n snapper -c root list
run cat /etc/sysconfig/btrfsmaintenance
run rpm -q chrony systemd-timesyncd apparmor-parser snapper backintime-qt backintime plymouth plymouth-dracut sddm-config-wayland which libyui-qt-pkg16 atomic-update criscore1 criscore2 avahi nss-mdns
run rpm -q --requires criscore1 criscore2
run rpm -qa 'plymouth*' 'yast2*' 'libyui*' 'ruby*'
run rpm -ql backintime-qt
run rpm -ql backintime
run rpm -ql sddm-config-wayland
for base in /etc/xdg/autostart /etc/skel/.config/autostart "${XDG_CONFIG_HOME:-$HOME/.config}/autostart"; do
  if [[ -d "$base" ]]; then
    run find "$base" -maxdepth 1 -type f -iname '*back*time*' -print -exec cat '{}' ';'
  fi
done
run cat /etc/xdg/kdesurc /etc/skel/.config/kdesurc "${XDG_CONFIG_HOME:-$HOME/.config}/kdesurc"
run crontab -l
run systemctl --user list-timers --all --no-pager
for base in /usr/lib/sddm/sddm.conf.d /usr/lib/sddm.conf.d /etc/sddm.conf.d; do
  if [[ -d "$base" ]]; then
    run find "$base" -maxdepth 1 -type f -name '*.conf' -print -exec cat '{}' ';'
  fi
done
run sudo -n firewall-cmd --get-default-zone
run sudo -n firewall-cmd --get-active-zones
run sudo -n firewall-cmd --list-all-zones
run sudo -n firewall-cmd --permanent --list-all-zones
run sudo -n firewall-cmd --info-service=kdeconnect
run nmcli -f NAME,TYPE,DEVICE connection show --active
run nmcli -f GENERAL.DEVICE,GENERAL.CONNECTION,IP6 device show
run nmcli radio wifi
run bluetoothctl --timeout 5 show
run sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 vm.swappiness vm.page-cluster
run ip -6 addr show dev lo
run getent ahosts localhost
run cat /etc/nsswitch.conf
run lpstat -r
run zramctl
run swapon --show
run systemd-analyze time
run systemd-analyze blame --no-pager
run systemd-analyze critical-chain --no-pager
run systemd-analyze --user blame --no-pager
run balooctl6 status
run cat /etc/xdg/baloofilerc "${XDG_CONFIG_HOME:-$HOME/.config}/baloofilerc" /etc/xdg/ksplashrc "${XDG_CONFIG_HOME:-$HOME/.config}/ksplashrc"
run ls -l /boot
run sudo -n lsinitrd -m
run sudo -n visudo -c
printf '\nReport: %s\n' "$report"
printf 'Read-only audit completed. Missing commands/units are recorded, not repaired.\n'
printf 'Review logs, connection names and cron entries before sharing.\n'
