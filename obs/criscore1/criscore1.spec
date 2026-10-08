# Protected RPM dependency anchors (both Requires blocks must stay identical).
# The historical generator/seed named in previous versions are not in this
# repository; do not claim this spec is currently reproducibly generated.
# Keep the YaST GUI modules in the Agama install-only list, never in the anchors.

Name:           criscore1
Version:        0.2
Release:        0
Summary:        Protected core anchor 1 for mySlowrollOS
License:        MIT
BuildArch:      noarch

# A meta dependency keeps both anchors on exactly the same build without
# introducing an artificial install/erase ordering dependency.
Requires(meta): criscore2 = %{version}-%{release}
Requires:       Mesa-dri
Requires:       Mesa-vulkan-device-select
Requires:       NetworkManager
Requires:       aaa_base
Requires:       alsa-ucm-conf
Requires:       alsa-utils
Requires:       apparmor-parser
Requires:       apparmor-utils
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
Requires:       curl
Requires:       dbus-broker
Requires:       dolphin
Requires:       dosfstools
Requires:       dracut
Requires:       e2fsprogs
Requires:       efibootmgr
Requires:       exfatprogs
Requires:       filesystem
Requires:       firewalld
Requires:       glibc
Requires:       glibc-locale
Requires:       iproute2
Requires:       iputils
Requires:       kde-cli-tools6
Requires:       kernel-default
Requires:       kernel-firmware-amdgpu
Requires:       kernel-firmware-mediatek
Requires:       kernel-firmware-realtek
Requires:       kf6-baloo-file
Requires:       kglobalacceld6
Requires:       kio-admin
Requires:       kio-extras
Requires:       konsole
Requires:       kscreenlocker6
Requires:       kwin6
Requires:       libvulkan_radeon
Requires:       libxml2-tools
Requires:       myrlyn
Requires:       ntfs-3g
Requires:       nvme-cli
Requires:       openSUSE-build-key
Requires:       openSUSE-release
Requires:       openSUSE-repos-Slowroll
Requires:       pam
Requires:       pam-config
Requires:       pam_kwallet6
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
Requires:       plasma6-session
Requires:       plasma6-workspace
Requires:       polkit
Requires:       polkit-kde-agent-6
Requires:       power-profiles-daemon
Requires:       powerdevil6
Requires:       procps
Requires:       rpm
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper
Requires:       sddm-config-wayland
Requires:       sddm-qt6
Requires:       shadow
Requires:       shim
Requires:       snapper
Requires:       snapper-zypp-plugin
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
Requires:       upower
Requires:       usbutils
Requires:       util-linux
Requires:       wireplumber
Requires:       wpa_supplicant
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-kde6
Requires:       xdg-user-dirs
Requires:       xdg-utils
Requires:       xwayland
Requires:       zram-generator
Requires:       zypper

%description
criscore1 is one of two deliberately redundant dependency anchors used by
mySlowrollOS. It protects the approved core package set from accidental removal.
It contains only a marker file; the protection is expressed by RPM dependencies
and the erase guard.

%package -n criscore2
Summary:        Protected core anchor 2 for mySlowrollOS
BuildArch:      noarch
Requires(meta): criscore1 = %{version}-%{release}
Requires:       Mesa-dri
Requires:       Mesa-vulkan-device-select
Requires:       NetworkManager
Requires:       aaa_base
Requires:       alsa-ucm-conf
Requires:       alsa-utils
Requires:       apparmor-parser
Requires:       apparmor-utils
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
Requires:       curl
Requires:       dbus-broker
Requires:       dolphin
Requires:       dosfstools
Requires:       dracut
Requires:       e2fsprogs
Requires:       efibootmgr
Requires:       exfatprogs
Requires:       filesystem
Requires:       firewalld
Requires:       glibc
Requires:       glibc-locale
Requires:       iproute2
Requires:       iputils
Requires:       kde-cli-tools6
Requires:       kernel-default
Requires:       kernel-firmware-amdgpu
Requires:       kernel-firmware-mediatek
Requires:       kernel-firmware-realtek
Requires:       kf6-baloo-file
Requires:       kglobalacceld6
Requires:       kio-admin
Requires:       kio-extras
Requires:       konsole
Requires:       kscreenlocker6
Requires:       kwin6
Requires:       libvulkan_radeon
Requires:       libxml2-tools
Requires:       myrlyn
Requires:       ntfs-3g
Requires:       nvme-cli
Requires:       openSUSE-build-key
Requires:       openSUSE-release
Requires:       openSUSE-repos-Slowroll
Requires:       pam
Requires:       pam-config
Requires:       pam_kwallet6
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
Requires:       plasma6-session
Requires:       plasma6-workspace
Requires:       polkit
Requires:       polkit-kde-agent-6
Requires:       power-profiles-daemon
Requires:       powerdevil6
Requires:       procps
Requires:       rpm
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper
Requires:       sddm-config-wayland
Requires:       sddm-qt6
Requires:       shadow
Requires:       shim
Requires:       snapper
Requires:       snapper-zypp-plugin
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
Requires:       upower
Requires:       usbutils
Requires:       util-linux
Requires:       wireplumber
Requires:       wpa_supplicant
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-kde6
Requires:       xdg-user-dirs
Requires:       xdg-utils
Requires:       xwayland
Requires:       zram-generator
Requires:       zypper

%description -n criscore2
criscore2 is the second dependency anchor used by mySlowrollOS. It carries the
same approved Requires as criscore1 and is version-locked to its peer.

%prep

%build

%install
install -d %{buildroot}%{_datadir}/criscore
printf '%s\n' 'mySlowrollOS protected core anchor 1' > %{buildroot}%{_datadir}/criscore/criscore1
printf '%s\n' 'mySlowrollOS protected core anchor 2' > %{buildroot}%{_datadir}/criscore/criscore2

# openSUSE post-build-checks performs a synthetic erase test with
# YAST_IS_RUNNING=instsys. Permit that build-root cleanup without weakening
# the guard for normal installed-system RPM/Zypper operations.
%preun
if [ "$1" -eq 0 ] && [ ! -e /run/criscore.allow-removal ] && [ "${YAST_IS_RUNNING:-}" != "instsys" ]; then
    echo "Refusing to remove protected package criscore1." >&2
    echo "For intentional removal, create /run/criscore.allow-removal first." >&2
    exit 1
fi

%preun -n criscore2
if [ "$1" -eq 0 ] && [ ! -e /run/criscore.allow-removal ] && [ "${YAST_IS_RUNNING:-}" != "instsys" ]; then
    echo "Refusing to remove protected package criscore2." >&2
    echo "For intentional removal, create /run/criscore.allow-removal first." >&2
    exit 1
fi

%files
%dir %{_datadir}/criscore
%{_datadir}/criscore/criscore1

%files -n criscore2
%dir %{_datadir}/criscore
%{_datadir}/criscore/criscore2

%changelog
