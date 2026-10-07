// Final interactive Agama profile for mySlowrollOS.
// Intentionally omits storage and authentication.
// The user selects disk/partitions and creates credentials in the Agama UI.

local base = 'https://raw.githubusercontent.com/krism-eu/mySlowrollOS/main/';

{
  product: { id: 'Slowroll' },

  software: {
    patterns: [],
    packages: [
      '7zip','Mesa-dri','Mesa-vulkan-device-select','NetworkManager',
      'NetworkManager-bluetooth','aaa_base','alsa-ucm-conf','alsa-utils',
      'apparmor-parser','apparmor-utils','ark','atomic-update','avahi','bash',
      'bash-completion','bluedevil6','bluez','bluez-obexd','breeze6',
      'breeze6-cursors','breeze6-decoration','breeze6-style','btrfsmaintenance',
      'btrfsprogs','ca-certificates-mozilla','cifs-utils','coreutils',
      'criscore1','criscore2','cups','cups-filters','cups-pk-helper','curl',
      'dbus-broker','discover6','discover6-backend-flatpak','dolphin',
      'dosfstools','dracut','e2fsprogs','efibootmgr','exfatprogs','filesystem',
      'firewalld','flatpak','glibc','glibc-locale','google-noto-coloremoji-fonts',
      'google-noto-sans-fonts','gutenprint','iproute2','iputils','kate',
      'kde-cli-tools6','kde-gtk-config6','kdeconnect-kde','kernel-default',
      'kernel-firmware-amdgpu','kernel-firmware-mediatek','kernel-firmware-realtek',
      'kf6-baloo-file','kglobalacceld6','kio-admin','kio-extras','kio-fuse',
      'konsole','kscreenlocker6','kwalletmanager','kwin6','liberation-fonts',
      'libgcrypt20-x86-64-v3','libhogweed6-x86-64-v3','liblz4-1-x86-64-v3',
      'liblzma5-x86-64-v3','libnettle8-x86-64-v3','libopenssl3-x86-64-v3',
      'libsqlite3-0-x86-64-v3','libvulkan_radeon','libxml2-tools',
      'libz1-x86-64-v3','libzstd1-x86-64-v3','myrlyn','nss-mdns','ntfs-3g',
      'ntfsprogs','nvme-cli','okular','openSUSE-build-key','openSUSE-release',
      'openSUSE-repos-Slowroll','pam','pam-config','pam_kwallet6',
      'partitionmanager','patterns-glibc-hwcaps-x86_64_v3','pciutils','pipewire',
      'pipewire-alsa','pipewire-pulseaudio','plasma6-desktop','plasma6-firewall',
      'plasma6-integration-plugin','plasma6-nm','plasma6-pa',
      'plasma6-print-manager','plasma6-session','plasma6-systemmonitor',
      'plasma6-workspace','polkit','polkit-kde-agent-6','power-profiles-daemon',
      'powerdevil6','procps','rpm','sdbootutil','sdbootutil-kernel-install',
      'sdbootutil-snapper','sddm-config-wayland','sddm-qt6','shadow','shim',
      'smartmontools','snapper','snapper-zypp-plugin','spectacle','sudo',
      'sudo-policy-wheel-auth-self','systemd','systemd-boot',
      'systemd-presets-branding-openSUSE','systemsettings6','timezone','tukit',
      'ucode-amd','udisks2','unar','unzip','upower','usbutils','util-linux',
      'wireplumber','wpa_supplicant','xdg-desktop-portal',
      'xdg-desktop-portal-kde6','xdg-user-dirs','xdg-utils','xwayland','yast2',
      'yast2-apparmor','yast2-bootloader','yast2-control-center-qt',
      'yast2-packager','yast2-security','yast2-services-manager','yast2-snapper',
      'yast2-storage-ng','yast2-sysconfig','zip','zram-generator','zstd','zypper'
    ],
    extraRepositories: [{
      alias: 'home_krism',
      name: 'home:krism - openSUSE Slowroll',
      url: 'https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/',
      priority: 90,
      gpgFingerprints: ['8528 3DD3 E1AF A9EA 668E 2065 3505 E29C 78A0 0759'],
    }],
    onlyRequired: true,
  },

  // Static policy is deployed as files, not duplicated in a post-chroot script.
  files: [
    { url: base + 'myslowroll-policy/10-myslowroll.preset', destination: '/etc/systemd/system-preset/10-myslowroll.preset', permissions: '0644' },
    { url: base + 'myslowroll-policy/20-myslowroll-disable-ipv6.conf', destination: '/etc/sysctl.d/20-myslowroll-disable-ipv6.conf', permissions: '0644' },
    { url: base + 'myslowroll-policy/10-myslowroll-journald.conf', destination: '/etc/systemd/journald.conf.d/10-myslowroll.conf', permissions: '0644' },
    { url: base + 'myslowroll-policy/10-myslowroll-wayland.conf', destination: '/etc/sddm.conf.d/10-myslowroll-wayland.conf', permissions: '0644' },
    { url: base + 'myslowroll-policy/90-myslowroll-sddm-fallback.conf', destination: '/etc/sddm.conf.d/90-myslowroll-fallback.conf', permissions: '0644' },
    { url: base + 'myslowroll-policy/90-myslowroll-zypp.conf', destination: '/etc/zypp/zypp.conf.d/90-myslowroll.conf', permissions: '0644' },
    { url: base + 'myslowroll-policy/home_krism.repo', destination: '/etc/zypp/repos.d/home_krism.repo', permissions: '0644' },
    { url: base + 'myslowroll-policy/99-myslowroll-passwordless-admin', destination: '/etc/sudoers.d/99-myslowroll-passwordless-admin', permissions: '0440' },
    { url: base + 'myslowroll-policy/10-myslowroll-passwordless-admin.rules', destination: '/etc/polkit-1/rules.d/10-myslowroll-passwordless-admin.rules', permissions: '0644' },
    { url: base + 'myslowroll-policy/kdesurc', destination: '/etc/skel/.config/kdesurc', permissions: '0644' },
    { url: base + 'myslowroll-policy/kernel-cmdline', destination: '/etc/kernel/cmdline', permissions: '0644' },
  ],

  scripts: {
    init: [{
      name: 'myslowroll-firstboot-policy',
      url: base + 'agama/init-firstboot.sh',
    }],
  },
  // Storage and authentication are intentionally omitted.

  bootloader: {
    timeout: 3,
    updateNvram: true,
  },
}
