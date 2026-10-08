Name:           atomic-update
Version:        5.7.1
Release:        0
Summary:        Guarded offline distribution upgrade for openSUSE Slowroll
License:        MIT
Source0:        %{name}-%{version}.sh

BuildRequires:  bash

Requires:       bash
Requires:       btrfsprogs
Requires:       coreutils
Requires:       diffutils
Requires:       findutils
Requires:       gawk
Requires:       grep
Requires:       kernel-default
Requires:       libxml2-tools
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

%check
bash -n %{SOURCE0}

%files
%{_sbindir}/%{name}

%changelog
