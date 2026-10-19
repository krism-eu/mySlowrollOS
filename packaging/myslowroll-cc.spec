Name:           myslowroll-cc
Version:        1.0.0
Release:        1%{?dist}
Summary:        MSCC - Control Center for openSUSE Slowroll
Summary(it):    MSCC - Centro di Controllo per openSUSE Slowroll
License:        MIT
Group:          System/GUI/KDE
URL:            https://github.com/krism-eu/mySlowrollOS
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}-rpmlintrc

BuildRequires:  cmake >= 3.20
BuildRequires:  gcc-c++
BuildRequires:  ninja
BuildRequires:  qt6-base-devel
BuildRequires:  qt6-declarative-devel
BuildRequires:  qt6-widgets-devel
BuildRequires:  qt6-quickcontrols2-devel
BuildRequires:  qt6-test-devel
BuildRequires:  kf6-kirigami-devel
BuildRequires:  kf6-extra-cmake-modules
BuildRequires:  hicolor-icon-theme

Requires:       qt6-declarative-imports
Requires:       kf6-kirigami-imports
Requires:       kf6-qqc2-desktop-style
Requires:       polkit
Recommends:     snapper
Recommends:     btrfsprogs
Recommends:     efibootmgr
Recommends:     NetworkManager
Recommends:     kf6-kconfig
Recommends:     flatpak
Recommends:     plasma6-systemmonitor
Recommends:     discover6
Recommends:     backintime-qt
Recommends:     python3-mast

%description
Desktop operational control center for openSUSE Slowroll and mySlowrollOS.
Provides real-time resource monitoring, Btrfs/Snapper snapshot integration,
atomic-update transactional engine status, quick audio stack repairs,
assisted disk cleanup, and rootless custom actions. Administrative tasks
require Polkit/pkexec authorization or sudoers configuration for the wheel group.

%description -l it
Centro di controllo operativo desktop personale per openSUSE Slowroll e mySlowrollOS.
Offre monitoraggio risorse in tempo reale, integrazione con gli snapshot Btrfs/Snapper,
stato del motore di transazione atomic-update, riparazioni rapide dello stack audio,
pulizia disco assistita e comandi personali rootless. Le operazioni amministrative
richiedono autorizzazione Polkit/pkexec o configurazione sudoers per il gruppo wheel.

%prep
%autosetup -n %{name}-%{version}

%build
%cmake_kf6 -DBUILD_TESTING=ON
%kf6_build

%install
%kf6_install

%check
%ctest

%files
%license LICENSE
%{_bindir}/myslowroll-cc
%{_datadir}/applications/myslowroll-cc.desktop
%{_datadir}/icons/hicolor/scalable/apps/myslowroll-cc.svg
%dir %{_datadir}/polkit-1
%dir %{_datadir}/polkit-1/actions
%{_datadir}/polkit-1/actions/org.myslowrollos.controlcenter.policy
%dir %{_datadir}/metainfo
%{_datadir}/metainfo/org.myslowrollos.controlcenter.metainfo.xml

%changelog
* Sat Oct 17 2026 Kris <kris@myslowrollos.org> - 1.0.0-1
- Prima bozza e release iniziale per openSUSE Slowroll
