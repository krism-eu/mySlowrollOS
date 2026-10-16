Name:           atomic-update
Version:        5.7.1
Release:        1
Summary:        Guarded offline distribution upgrade for openSUSE Slowroll
License:        MIT
URL:            https://build.opensuse.org/package/show/home:krism/atomic-update
Source0:        %{name}-%{version}.sh
Source1:        myslowroll-update
Source2:        myslowroll-update.desktop

BuildRequires:  bash
BuildRequires:  desktop-file-utils

Requires:       bash
Requires:       btrfsprogs
Requires:       coreutils
Requires:       diffutils
Requires:       findutils
Requires:       gawk
Requires:       grep
Requires:       kernel-default
Requires:       /usr/bin/xmllint
Requires:       konsole
Requires:       procps
Requires:       rpm
Requires:       sdbootutil
Requires:       sdbootutil-kernel-install
Requires:       sdbootutil-snapper
Requires:       sed
Requires:       snapper
Requires:       systemd
Requires:       systemd-boot
Requires:       tukit
Requires:       util-linux
Requires:       zypper
Requires:       criscore1
Requires:       criscore2

BuildArch:      noarch

%description
Guarded offline distribution upgrade tool for a personal openSUSE Slowroll
workstation using Btrfs, Snapper, tukit and systemd-boot.

The package installs no timer or daemon. Execution is manual. It remains
separate from criscore so the guarded updater can be replaced independently.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_sbindir}/%{name}
install -Dpm0755 %{SOURCE1} %{buildroot}%{_bindir}/myslowroll-update
install -Dpm0644 %{SOURCE2} %{buildroot}%{_datadir}/applications/myslowroll-update.desktop

%check
bash -n %{SOURCE0}
bash -n %{SOURCE1}
desktop-file-validate %{SOURCE2}

%files
%{_sbindir}/%{name}
%{_bindir}/myslowroll-update
%{_datadir}/applications/myslowroll-update.desktop

%changelog

