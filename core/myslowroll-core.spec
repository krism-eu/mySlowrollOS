# DRAFT NON APPROVATA: non usare per build o installazione.
# I Requires saranno sostituiti dopo il confronto della baseline KIWI.

Name:           myslowroll-core
Version:        0.1
Release:        0
Summary:        Protected core for the mySlowrollOS workstation
License:        MIT
BuildArch:      noarch

# Base system and package management
Requires:       openSUSE-release
Requires:       aaa_base
Requires:       filesystem
Requires:       systemd
Requires:       udev
Requires:       rpm
Requires:       zypper
Requires:       dbus-broker
Requires:       polkit
Requires:       sudo

# Boot, storage and rollback
Requires:       kernel-default
Requires:       dracut
Requires:       btrfsprogs
Requires:       snapper
Requires:       snapper-zypp-plugin
Requires:       efibootmgr
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper

# Security and networking
Requires:       apparmor-parser
Requires:       apparmor-utils
Requires:       firewalld
Requires:       NetworkManager

# Minimal usable Plasma Wayland session
Requires:       sddm
Requires:       plasma6-session
Requires:       plasma6-workspace
Requires:       kwin6
Requires:       xwayland
Requires:       kscreenlocker6
Requires:       kglobalacceld6
Requires:       powerdevil6
Requires:       polkit-kde-agent-6
Requires:       plasma6-nm

# Audio session
Requires:       pipewire
Requires:       pipewire-pulseaudio
Requires:       wireplumber
Requires:       plasma6-pa

# Graphical and command-line administration
Requires:       yast2
Requires:       yast2-control-center-qt
Requires:       yast2-packager
Requires:       yast2-storage-ng

%description
myslowroll-core is the deliberately small protected dependency root of
mySlowrollOS. It keeps the machine bootable, recoverable, networked and able
to start a minimal Plasma Wayland administration session. Xwayland is kept
for legacy application compatibility without installing a Plasma X11 session.

Applications, printing, Bluetooth, codecs and other workstation features
intentionally do not belong to this package.

%prep

%build

%install

%preun
# RPM passes 0 for a real erase and a value greater than 0 during an upgrade.
if [ "$1" -eq 0 ] && [ ! -e /run/myslowroll-core.allow-removal ]; then
    echo "Refusing to remove the protected mySlowrollOS core." >&2
    echo "For an intentional removal, create /run/myslowroll-core.allow-removal first." >&2
    exit 1
fi

%postun
if [ "$1" -eq 0 ]; then
    rm -f /run/myslowroll-core.allow-removal
fi

%files

%changelog
