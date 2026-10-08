Name:           myslowroll-policy
Version:        1.0.0
Release:        0
Summary:        Static system policy for mySlowrollOS
License:        MIT
Source0:        LICENSE
Source1:        10-myslowroll.preset
Source2:        20-myslowroll-disable-ipv6.conf
Source3:        10-myslowroll-journald.conf
Source4:        10-myslowroll-wayland.conf
Source5:        90-myslowroll-sddm-fallback.conf
Source6:        90-myslowroll-zypp.conf
Source7:        home_krism.repo
Source8:        99-myslowroll-passwordless-admin
Source9:        10-myslowroll-passwordless-admin.rules
Source10:        kdesurc
Source11:        kernel-cmdline
Source12:        10-myslowroll-zram.conf
BuildArch:      noarch
BuildRequires:  sudo
Requires:       NetworkManager
Requires:       firewalld
Requires:       polkit
Requires:       sddm-qt6
Requires:       sudo
Requires:       systemd
Requires:       zypper
Requires:       zram-generator

%description
Stable configuration policy shared by KIWI validation images and the system
installed by Agama. It deliberately does not create users or set passwords.
Authentication remains an installer-time decision.

%prep

%build

%install
install -Dpm0644 %{SOURCE1}  %{buildroot}%{_sysconfdir}/systemd/system-preset/10-myslowroll.preset
install -Dpm0644 %{SOURCE2}  %{buildroot}%{_sysconfdir}/sysctl.d/20-myslowroll-disable-ipv6.conf
install -Dpm0644 %{SOURCE3}  %{buildroot}%{_sysconfdir}/systemd/journald.conf.d/10-myslowroll.conf
install -Dpm0644 %{SOURCE4}  %{buildroot}%{_sysconfdir}/sddm.conf.d/10-myslowroll-wayland.conf
install -Dpm0644 %{SOURCE5}  %{buildroot}%{_sysconfdir}/sddm.conf.d/90-myslowroll-fallback.conf
install -Dpm0644 %{SOURCE6}  %{buildroot}%{_sysconfdir}/zypp/zypp.conf.d/90-myslowroll.conf
install -Dpm0644 %{SOURCE7}  %{buildroot}%{_sysconfdir}/zypp/repos.d/home_krism.repo
install -Dpm0440 %{SOURCE8}  %{buildroot}%{_sysconfdir}/sudoers.d/99-myslowroll-passwordless-admin
install -Dpm0644 %{SOURCE9}  %{buildroot}%{_sysconfdir}/polkit-1/rules.d/10-myslowroll-passwordless-admin.rules
install -Dpm0644 %{SOURCE10} %{buildroot}%{_sysconfdir}/skel/.config/kdesurc
install -Dpm0644 %{SOURCE12} %{buildroot}%{_sysconfdir}/systemd/zram-generator.conf.d/10-myslowroll.conf
install -Dpm0644 %{SOURCE11} %{buildroot}%{_sysconfdir}/kernel/cmdline
install -Dpm0644 %{SOURCE0}  %{buildroot}%{_licensedir}/%{name}/LICENSE

%check
visudo -cf %{SOURCE8} >/dev/null
grep -Fxq 'solver.onlyRequires = true' %{SOURCE6}
grep -Fxq 'solver.dupAllowVendorChange = false' %{SOURCE6}
grep -Fxq 'gpgcheck=1' %{SOURCE7}
grep -Fxq 'repo_gpgcheck=1' %{SOURCE7}

# No %post service actions: package upgrades must not reset administrators'
# service choices or replace display-manager symlinks. The active Agama path
# applies the initial systemd policy through the shipped preset and its
# one-time post-chroot/first-boot scripts.

%files
%license %{_licensedir}/%{name}/LICENSE
%config(noreplace) %{_sysconfdir}/systemd/system-preset/10-myslowroll.preset
%config(noreplace) %{_sysconfdir}/sysctl.d/20-myslowroll-disable-ipv6.conf
%config(noreplace) %{_sysconfdir}/systemd/journald.conf.d/10-myslowroll.conf
%config(noreplace) %{_sysconfdir}/sddm.conf.d/10-myslowroll-wayland.conf
%config(noreplace) %{_sysconfdir}/sddm.conf.d/90-myslowroll-fallback.conf
%config(noreplace) %{_sysconfdir}/zypp/zypp.conf.d/90-myslowroll.conf
%config(noreplace) %{_sysconfdir}/zypp/repos.d/home_krism.repo
%config(noreplace) %{_sysconfdir}/sudoers.d/99-myslowroll-passwordless-admin
%config(noreplace) %{_sysconfdir}/polkit-1/rules.d/10-myslowroll-passwordless-admin.rules
%config(noreplace) %{_sysconfdir}/skel/.config/kdesurc
%config(noreplace) %{_sysconfdir}/kernel/cmdline
%config(noreplace) %{_sysconfdir}/systemd/zram-generator.conf.d/10-myslowroll.conf
