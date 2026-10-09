Name:           myslowroll-workstation
Version:        1.0.0
Release:        0
Summary:        mySlowrollOS workstation package manifest
License:        MIT
Source0:        LICENSE
BuildArch:      noarch

Requires:       7zip
Requires:       Mesa-dri
Requires:       Mesa-vulkan-device-select
Requires:       NetworkManager
Requires:       aaa_base
Requires:       alsa-ucm-conf
Requires:       alsa-utils
Requires:       apparmor-abstractions
Requires:       apparmor-parser
Requires:       apparmor-profiles
Requires:       apparmor-utils
Requires:       ark
Requires:       atomic-update
Requires:       avahi
Requires:       backintime-qt
Requires:       bash
Requires:       bash-completion
Requires:       bluedevil6
Requires:       bluez
Requires:       bluez-obexd
Requires:       breeze6
Requires:       breeze6-cursors
Requires:       breeze6-decoration
Requires:       breeze6-style
Requires:       btrfsmaintenance
Requires:       btrfsprogs
Requires:       ca-certificates-mozilla
Requires:       cifs-utils
Requires:       coreutils
Requires:       criscore1
Requires:       criscore2
Requires:       cups
Requires:       cups-filters
Requires:       cups-pk-helper
Requires:       curl
Requires:       dbus-broker
Requires:       discover6
Requires:       discover6-backend-flatpak
Requires:       dolphin
Requires:       dosfstools
Requires:       dracut
Requires:       e2fsprogs
Requires:       efibootmgr
Requires:       exfatprogs
Requires:       filesystem
Requires:       firewalld
Requires:       flatpak
Requires:       glibc
Requires:       glibc-locale
Requires:       google-noto-coloremoji-fonts
Requires:       google-noto-sans-fonts
Requires:       iproute2
Requires:       iputils
Requires:       kate
Requires:       kde-cli-tools6
Requires:       kde-gtk-config6
Requires:       kdeconnect-kde
Requires:       kernel-default
# The firmware below is specifically requested for this workstation.
# sof-firmware is not requested (removed from current system; audio works).
# kernel-firmware-platform is the only additional exclusion candidate:
# verify its removal on the real hardware before treating it as safe.
# Product/kernel dependencies can still select either package in Agama;
# comments are NOT a package ban and no post-install removal is authorized.
Requires:       kernel-firmware-amdgpu
Requires:       kernel-firmware-mediatek
Requires:       kernel-firmware-realtek
Requires:       kf6-baloo-file
Requires:       kglobalacceld6
Requires:       kio-admin
Requires:       kio-extras
Requires:       kio-fuse
Requires:       konsole
Requires:       kscreen6
Requires:       kscreenlocker6
Requires:       kwalletmanager
Requires:       kwin6
Requires:       less
Requires:       liberation-fonts
Requires:       libgcrypt20-x86-64-v3
Requires:       libhogweed6-x86-64-v3
Requires:       liblz4-1-x86-64-v3
Requires:       liblzma5-x86-64-v3
Requires:       libnettle8-x86-64-v3
Requires:       libopenssl3-x86-64-v3
Requires:       libsqlite3-0-x86-64-v3
Requires:       libvulkan_radeon
Requires:       libxml2-tools
Requires:       libz1-x86-64-v3
Requires:       libzstd1-x86-64-v3
Requires:       myrlyn
Requires:       nano
Requires:       nss-mdns
Requires:       ntfs-3g
Requires:       ntfsprogs
Requires:       nvme-cli
Requires:       okular
Requires:       openSUSE-build-key
Requires:       openSUSE-release
Requires:       openSUSE-repos-Slowroll
Requires:       openssh-clients
Requires:       pam
Requires:       pam-config
Requires:       pam_kwallet6
Requires:       partitionmanager
Requires:       patterns-glibc-hwcaps-x86_64_v3
Requires:       pciutils
Requires:       pipewire
Requires:       pipewire-alsa
Requires:       pipewire-pulseaudio
Requires:       plasma6-desktop
Requires:       plasma6-firewall
Requires:       plasma6-integration-plugin
Requires:       plasma6-nm
Requires:       plasma6-pa
Requires:       plasma6-print-manager
Requires:       plasma6-session
Requires:       plasma6-systemmonitor
Requires:       plasma6-workspace
Requires:       plymouth
Requires:       polkit
Requires:       polkit-kde-agent-6
Requires:       power-profiles-daemon
Requires:       powerdevil6
Requires:       procps
Requires:       rpm
Requires:       rsync
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper
Requires:       sddm-config-wayland
Requires:       sddm-qt6
Requires:       shadow
Requires:       shim
Requires:       smartmontools
Requires:       snapper
Requires:       snapper-zypp-plugin
Requires:       spectacle
Requires:       sudo
Requires:       sudo-policy-wheel-auth-self
Requires:       systemd
Requires:       systemd-boot
Requires:       systemd-presets-branding-openSUSE
Requires:       systemsettings6
Requires:       timezone
Requires:       tukit
Requires:       ucode-amd
Requires:       udisks2
Requires:       unar
Requires:       unzip
Requires:       upower
Requires:       usbutils
Requires:       util-linux
Requires:       wget
Requires:       wireplumber
Requires:       wpa_supplicant
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-kde6
Requires:       xdg-user-dirs
Requires:       xdg-utils
Requires:       xwayland
Requires:       zip
Requires:       zram-generator
Requires:       zstd
Requires:       zypper

%description
Optional metapackage describing the normal mySlowrollOS workstation
requirements. Agama installs these requirements individually from the
manifest; the metapackage itself is not published or installed by Agama.

%prep

%build

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
