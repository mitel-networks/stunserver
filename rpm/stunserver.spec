Name:           stunserver
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        STUN server and client compliant with RFC 5389/8489
License:        Apache-2.0
URL:            https://github.com/jselbie/stunserver

%global debug_package %{nil}

Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  openssl-devel
BuildRequires:  boost-devel
BuildRequires:  systemd-rpm-macros

Requires(pre):  shadow-utils
# The status endpoint (stunserver-health) is a Python script.
Requires:       python3
%{?systemd_requires}

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
install -D -m 0644 rpm/stunserver.service \
    %{buildroot}%{_unitdir}/stunserver.service
install -D -m 0755 rpm/stunserver-health \
    %{buildroot}%{_libexecdir}/stunserver/stunserver-health
install -D -m 0644 rpm/stunserver-health.service \
    %{buildroot}%{_unitdir}/stunserver-health.service
install -d -m 0755 %{buildroot}%{_sysconfdir}/stunserver

%pre
getent group stunserver >/dev/null || groupadd -r stunserver
getent passwd stunserver >/dev/null || \
    useradd -r -g stunserver -s /sbin/nologin -d /dev/null \
            -c "STUN Server daemon" stunserver
exit 0

%post
%systemd_post stunserver.service stunserver-health.service
if [ $1 -eq 1 ] ; then
    systemctl start stunserver.service >/dev/null 2>&1 || :
fi
# stunserver-health is deliberately not started here: it needs the
# environment file written at first boot, which enables and starts it.

%preun
%systemd_preun stunserver.service stunserver-health.service

%postun
%systemd_postun_with_restart stunserver.service stunserver-health.service

%files
%license LICENSE
%{_bindir}/stunserver
%{_bindir}/stunclient
%{_unitdir}/stunserver.service
%{_unitdir}/stunserver-health.service
%dir %{_libexecdir}/stunserver
%{_libexecdir}/stunserver/stunserver-health
%dir %{_sysconfdir}/stunserver

%changelog
* Tue May 27 2025 CI Build <ci@mitel.com> - %{version}-1
- Automated build
