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
BuildArch:      noarch
BuildRequires:  sudo
Requires:       NetworkManager
Requires:       firewalld
Requires:       polkit
Requires:       sddm-qt6
Requires:       sudo
Requires:       systemd
Requires:       zypper

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
install -Dpm0644 %{SOURCE11} %{buildroot}%{_sysconfdir}/kernel/cmdline
install -Dpm0644 %{SOURCE0}  %{buildroot}%{_licensedir}/%{name}/LICENSE

%check
visudo -cf %{SOURCE8} >/dev/null
grep -Fxq 'solver.onlyRequires = true' %{SOURCE6}
grep -Fxq 'solver.dupAllowVendorChange = false' %{SOURCE6}
grep -Fxq 'gpgcheck=1' %{SOURCE7}
grep -Fxq 'repo_gpgcheck=1' %{SOURCE7}

%post
# These operations are idempotent and affect only service policy.
if command -v systemctl >/dev/null 2>&1; then
    systemctl set-default graphical.target >/dev/null 2>&1 || :
    systemctl enable NetworkManager.service firewalld.service >/dev/null 2>&1 || :
    systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || :
    systemctl disable smartd.service smartd_generate_opts.path >/dev/null 2>&1 || :
    systemctl disable snapper-timeline.timer >/dev/null 2>&1 || :
    systemctl disable sshd.service sshd.socket >/dev/null 2>&1 || :
    systemctl disable display-manager-legacy.service >/dev/null 2>&1 || :
    systemctl mask ModemManager.service >/dev/null 2>&1 || :
fi
ln -sfn /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service || :

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
