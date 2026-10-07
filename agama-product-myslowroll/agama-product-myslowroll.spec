Name:           agama-product-myslowroll
Version:        1.0.0
Release:        0
Summary:        Agama product definition for mySlowrollOS
License:        MIT
Source0:        myslowroll.yaml
Source1:        LICENSE
BuildArch:      noarch
Requires:       agama

%description
Agama product definition for the mySlowrollOS Slowroll workstation.
The product fixes software composition and boot/storage capabilities while
leaving the actual storage operations and authentication to the interactive
installer.

%prep

%build

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/agama/products.d/myslowroll.yaml
install -Dpm0644 %{SOURCE1} %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
%{_datadir}/agama/products.d/myslowroll.yaml
