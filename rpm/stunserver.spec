Name:           stunserver
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        STUN server and client compliant with RFC 5389/8489
License:        Apache-2.0
URL:            https://github.com/jselbie/stunserver

Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  openssl-devel
BuildRequires:  boost-devel

%description
stunserver is a free STUN server implementation compliant with RFC 5389 and
RFC 8489. It supports both UDP and TCP transports and ships with a client
utility, stunclient, for testing STUN connectivity.

%prep
%setup -q

%build
%make_build

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 stunserver %{buildroot}%{_bindir}/stunserver
install -m 0755 stunclient %{buildroot}%{_bindir}/stunclient

%files
%license LICENSE
%{_bindir}/stunserver
%{_bindir}/stunclient

%changelog
* Tue May 27 2025 CI Build <ci@mitel.com> - %{version}-1
- Automated build
