// GENERATED FILE - DO NOT EDIT BY HAND.
// Sources: experiments/rootfs/system.seed + experiments/rootfs/plasma.seed + agama/post-install.sh.
// Profilo intenzionalmente parziale: storage, utenti e password restano manuali.
{
  product: {
    id: "Slowroll",
  },

  localization: {
    language: "it_IT.UTF-8",
    keyboard: "it",
    timezone: "Europe/Rome",
  },

  software: {
    patterns: [],
    packages: [
      "7zip",
      "Mesa-dri",
      "Mesa-vulkan-device-select",
      "NetworkManager",
      "NetworkManager-bluetooth",
      "alsa-ucm-conf",
      "alsa-utils",
      "apparmor-parser",
      "apparmor-utils",
      "ark",
      "avahi",
      "bash-completion",
      "bluedevil6",
      "bluez",
      "bluez-obexd",
      "breeze6",
      "breeze6-cursors",
      "breeze6-decoration",
      "breeze6-style",
      "btrfsmaintenance",
      "btrfsprogs",
      "ca-certificates-mozilla",
      "cifs-utils",
      "criscore1",
      "criscore2",
      "cups",
      "cups-filters",
      "cups-pk-helper",
      "curl",
      "dbus-broker",
      "discover6",
      "discover6-backend-flatpak",
      "dolphin",
      "dosfstools",
      "dracut",
      "e2fsprogs",
      "efibootmgr",
      "exfatprogs",
      "firewalld",
      "flatpak",
      "fwupd",
      "fwupd-efi",
      "glibc-locale",
      "google-noto-coloremoji-fonts",
      "google-noto-sans-fonts",
      "gutenprint",
      "gwenview",
      "iproute2",
      "iputils",
      "kate",
      "kde-cli-tools6",
      "kde-gtk-config6",
      "kernel-default",
      "kernel-firmware-amdgpu",
      "kernel-firmware-mediatek",
      "kernel-firmware-realtek",
      "kglobalacceld6",
      "kio-admin",
      "kio-extras",
      "kio-fuse",
      "konsole",
      "kscreenlocker6",
      "kwalletmanager",
      "kwin6",
      "liberation-fonts",
      "libvulkan_radeon",
      "libyui-qt-pkg16",
      "myrlyn",
      "nss-mdns",
      "ntfs-3g",
      "ntfsprogs",
      "nvme-cli",
      "okular",
      "openSUSE-release",
      "openSUSE-repos-Slowroll",
      "pam_kwallet6",
      "partitionmanager",
      "pciutils",
      "pipewire",
      "pipewire-alsa",
      "pipewire-pulseaudio",
      "plasma6-branding-openSUSE",
      "plasma6-disks",
      "plasma6-firewall",
      "plasma6-integration-plugin",
      "plasma6-nm",
      "plasma6-pa",
      "plasma6-print-manager",
      "plasma6-session",
      "plasma6-systemmonitor",
      "plasma6-theme-openSUSE",
      "plasma6-workspace",
      "plymouth",
      "plymouth-branding-openSUSE",
      "plymouth-dracut",
      "polkit",
      "polkit-kde-agent-6",
      "power-profiles-daemon",
      "powerdevil6",
      "rpm",
      "sdbootutil",
      "sdbootutil-kernel-install",
      "sdbootutil-snapper",
      "sddm-kcm6",
      "sddm-qt6",
      "sddm-qt6-branding-openSUSE",
      "shim",
      "skanlite",
      "smartmontools",
      "snapper",
      "snapper-zypp-plugin",
      "spectacle",
      "sudo",
      "systemd",
      "systemd-boot",
      "systemd-presets-branding-openSUSE",
      "systemsettings6",
      "timezone",
      "transactional-update",
      "ucode-amd",
      "udisks2",
      "unar",
      "unzip",
      "upower",
      "usbutils",
      "wireplumber",
      "wpa_supplicant",
      "xdg-desktop-portal",
      "xdg-desktop-portal-kde6",
      "xdg-user-dirs",
      "xdg-utils",
      "xf86-input-libinput",
      "xorg-x11-server",
      "xwayland",
      "yast2",
      "yast2-apparmor",
      "yast2-bootloader",
      "yast2-control-center-qt",
      "yast2-packager",
      "yast2-scanner",
      "yast2-services-manager",
      "yast2-snapper",
      "yast2-storage-ng",
      "yast2-sysconfig",
      "zip",
      "zram-generator",
      "zstd",
      "zypper",
    ],
    extraRepositories: [
      {
        alias: "criscore",
        name: "mySlowrollOS criscore",
        url: "https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/",
        priority: 90,
      },
    ],
    onlyRequired: true,
  },

  // La policy post-install e incorporata per rendere workstation.jsonnet
  // autosufficiente anche quando viene caricato con usb:///.
  scripts: {
    post: [
      {
        name: "myslowroll-system-policy",
        chroot: true,
        content: |||
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
        |||,
      },
    ],
  },
}
