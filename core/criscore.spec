# GENERATED FILE - DO NOT EDIT BY HAND.
# Source of common Requires: experiments/rootfs/protected.seed
# Regenerate with: core/generate-criscore-spec

Name:           criscore1
Version:        0.1
Release:        0
Summary:        Protected core anchor 1 for mySlowrollOS
License:        MIT
BuildArch:      noarch
Source0:        criscore-clean-orphans

# Keep the two anchors on exactly the same build without creating an ordering loop.
Requires(meta): criscore2 = %{version}-%{release}
Requires:       Mesa-dri
Requires:       Mesa-vulkan-device-select
Requires:       NetworkManager
Requires:       NetworkManager-bluetooth
Requires:       alsa-ucm-conf
Requires:       alsa-utils
Requires:       apparmor-parser
Requires:       apparmor-utils
Requires:       avahi
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
Requires:       curl
Requires:       dbus-broker
Requires:       dolphin
Requires:       dosfstools
Requires:       dracut
Requires:       e2fsprogs
Requires:       efibootmgr
Requires:       exfatprogs
Requires:       firewalld
Requires:       fwupd
Requires:       fwupd-efi
Requires:       glibc-locale
Requires:       iproute2
Requires:       iputils
Requires:       kde-cli-tools6
Requires:       kernel-default
Requires:       kernel-firmware-amdgpu
Requires:       kernel-firmware-mediatek
Requires:       kernel-firmware-realtek
Requires:       kglobalacceld6
Requires:       kio-admin
Requires:       kio-extras
Requires:       kio-fuse
Requires:       konsole
Requires:       kscreenlocker6
Requires:       kwin6
Requires:       libvulkan_radeon
Requires:       myrlyn
Requires:       nss-mdns
Requires:       ntfs-3g
Requires:       ntfsprogs
Requires:       nvme-cli
Requires:       openSUSE-release
Requires:       openSUSE-repos-Slowroll
Requires:       pam_kwallet6
Requires:       pciutils
Requires:       pipewire
Requires:       pipewire-alsa
Requires:       pipewire-pulseaudio
Requires:       plasma6-branding-openSUSE
Requires:       plasma6-disks
Requires:       plasma6-firewall
Requires:       plasma6-integration-plugin
Requires:       plasma6-nm
Requires:       plasma6-pa
Requires:       plasma6-session
Requires:       plasma6-systemmonitor
Requires:       plasma6-theme-openSUSE
Requires:       plasma6-workspace
Requires:       plymouth
Requires:       plymouth-branding-openSUSE
Requires:       plymouth-dracut
Requires:       polkit
Requires:       polkit-kde-agent-6
Requires:       power-profiles-daemon
Requires:       powerdevil6
Requires:       rpm
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper
Requires:       sddm-kcm6
Requires:       sddm-qt6
Requires:       sddm-qt6-branding-openSUSE
Requires:       shim
Requires:       smartmontools
Requires:       snapper
Requires:       snapper-zypp-plugin
Requires:       sudo
Requires:       systemd
Requires:       systemd-boot
Requires:       systemd-presets-branding-openSUSE
Requires:       systemsettings6
Requires:       timezone
Requires:       ucode-amd
Requires:       udisks2
Requires:       upower
Requires:       usbutils
Requires:       wireplumber
Requires:       wpa_supplicant
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-kde6
Requires:       xdg-user-dirs
Requires:       xdg-utils
Requires:       xf86-input-libinput
Requires:       xorg-x11-server
Requires:       xwayland
Requires:       yast2
Requires:       yast2-apparmor
Requires:       yast2-bootloader
Requires:       yast2-control-center-qt
Requires:       yast2-packager
Requires:       yast2-services-manager
Requires:       yast2-snapper
Requires:       yast2-storage-ng
Requires:       yast2-sysconfig
Requires:       zram-generator
Requires:       zypper

%description
criscore1 is one of two deliberately redundant dependency anchors used by
mySlowrollOS. It protects the approved core package set from accidental removal.
The package contains no application payload beyond the guarded orphan-cleanup
helper and a marker file.

%package -n criscore2
Summary:        Protected core anchor 2 for mySlowrollOS
BuildArch:      noarch
Requires(meta): criscore1 = %{version}-%{release}
Requires:       Mesa-dri
Requires:       Mesa-vulkan-device-select
Requires:       NetworkManager
Requires:       NetworkManager-bluetooth
Requires:       alsa-ucm-conf
Requires:       alsa-utils
Requires:       apparmor-parser
Requires:       apparmor-utils
Requires:       avahi
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
Requires:       curl
Requires:       dbus-broker
Requires:       dolphin
Requires:       dosfstools
Requires:       dracut
Requires:       e2fsprogs
Requires:       efibootmgr
Requires:       exfatprogs
Requires:       firewalld
Requires:       fwupd
Requires:       fwupd-efi
Requires:       glibc-locale
Requires:       iproute2
Requires:       iputils
Requires:       kde-cli-tools6
Requires:       kernel-default
Requires:       kernel-firmware-amdgpu
Requires:       kernel-firmware-mediatek
Requires:       kernel-firmware-realtek
Requires:       kglobalacceld6
Requires:       kio-admin
Requires:       kio-extras
Requires:       kio-fuse
Requires:       konsole
Requires:       kscreenlocker6
Requires:       kwin6
Requires:       libvulkan_radeon
Requires:       myrlyn
Requires:       nss-mdns
Requires:       ntfs-3g
Requires:       ntfsprogs
Requires:       nvme-cli
Requires:       openSUSE-release
Requires:       openSUSE-repos-Slowroll
Requires:       pam_kwallet6
Requires:       pciutils
Requires:       pipewire
Requires:       pipewire-alsa
Requires:       pipewire-pulseaudio
Requires:       plasma6-branding-openSUSE
Requires:       plasma6-disks
Requires:       plasma6-firewall
Requires:       plasma6-integration-plugin
Requires:       plasma6-nm
Requires:       plasma6-pa
Requires:       plasma6-session
Requires:       plasma6-systemmonitor
Requires:       plasma6-theme-openSUSE
Requires:       plasma6-workspace
Requires:       plymouth
Requires:       plymouth-branding-openSUSE
Requires:       plymouth-dracut
Requires:       polkit
Requires:       polkit-kde-agent-6
Requires:       power-profiles-daemon
Requires:       powerdevil6
Requires:       rpm
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper
Requires:       sddm-kcm6
Requires:       sddm-qt6
Requires:       sddm-qt6-branding-openSUSE
Requires:       shim
Requires:       smartmontools
Requires:       snapper
Requires:       snapper-zypp-plugin
Requires:       sudo
Requires:       systemd
Requires:       systemd-boot
Requires:       systemd-presets-branding-openSUSE
Requires:       systemsettings6
Requires:       timezone
Requires:       ucode-amd
Requires:       udisks2
Requires:       upower
Requires:       usbutils
Requires:       wireplumber
Requires:       wpa_supplicant
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-kde6
Requires:       xdg-user-dirs
Requires:       xdg-utils
Requires:       xf86-input-libinput
Requires:       xorg-x11-server
Requires:       xwayland
Requires:       yast2
Requires:       yast2-apparmor
Requires:       yast2-bootloader
Requires:       yast2-control-center-qt
Requires:       yast2-packager
Requires:       yast2-services-manager
Requires:       yast2-snapper
Requires:       yast2-storage-ng
Requires:       yast2-sysconfig
Requires:       zram-generator
Requires:       zypper

%description -n criscore2
criscore2 is the second dependency anchor used by mySlowrollOS. It carries the
same approved Requires as criscore1 and is version-locked to its peer.

%prep

%build

%install
install -Dm0755 %{SOURCE0} %{buildroot}%{_sbindir}/criscore-clean-orphans
install -d %{buildroot}%{_datadir}/criscore
printf '%s\n' 'mySlowrollOS protected core anchor 1' > %{buildroot}%{_datadir}/criscore/criscore1
printf '%s\n' 'mySlowrollOS protected core anchor 2' > %{buildroot}%{_datadir}/criscore/criscore2

%preun
if [ "$1" -eq 0 ] && [ ! -e /run/criscore.allow-removal ]; then
    echo "Refusing to remove protected package criscore1." >&2
    echo "For intentional removal, create /run/criscore.allow-removal first." >&2
    exit 1
fi

%preun -n criscore2
if [ "$1" -eq 0 ] && [ ! -e /run/criscore.allow-removal ]; then
    echo "Refusing to remove protected package criscore2." >&2
    echo "For intentional removal, create /run/criscore.allow-removal first." >&2
    exit 1
fi

%files
%{_sbindir}/criscore-clean-orphans
%{_datadir}/criscore/criscore1

%files -n criscore2
%{_datadir}/criscore/criscore2

%changelog
