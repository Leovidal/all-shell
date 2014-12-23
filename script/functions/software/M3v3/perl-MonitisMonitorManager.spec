Summary: MonitisMonitorManager Perl module
Name: perl-MonitisMonitorManager
Version: 3.12
Release: 1
License: GPL or Artistic
Group: Development/Libraries
URL: http://search.cpan.org/dist/MonitisMonitorManager/
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
BuildArch: noarch
BuildRequires: perl
Requires: perl
Requires: perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
Requires: perl-Monitis >= 0.93
Source: perl-MonitisMonitorManager.tar.gz

%description
%{summary}.

%prep
%setup -q -n perl-MonitisMonitorManager-%{version}

%build
# force installation to go to /usr and not /usr/local as the init.d service
# needs stuff in /usr/bin/monitis-m3
CFLAGS="$RPM_OPT_FLAGS" %{__perl} Makefile.PL PREFIX=$RPM_BUILD_ROOT/usr
make %{?_smp_mflags} OPTIMIZE="$RPM_OPT_FLAGS"

%install
rm -rf $RPM_BUILD_ROOT

# this is the original line, but we've set the PREFIX previously
#make pure_install PERL_INSTALL_ROOT=$RPM_BUILD_ROOT
make pure_install

find $RPM_BUILD_ROOT -type f -a \( -name perllocal.pod -o -name .packlist \
  -o \( -name '*.bs' -a -empty \) \) -exec rm -f {} ';'
find $RPM_BUILD_ROOT -type d -depth -exec rmdir {} 2>/dev/null ';'
chmod -R u+w $RPM_BUILD_ROOT/*

for brp in %{_prefix}/lib/rpm/%{_build_vendor}/brp-compress \
  %{_prefix}/lib/rpm/brp-compress
do
  [ -x $brp ] && $brp && break
done


find $RPM_BUILD_ROOT -type f \
| sed "s@^$RPM_BUILD_ROOT@@g" \
> %{name}-%{version}-%{release}-filelist

eval `%{__perl} -V:archname -V:installsitelib -V:installvendorlib -V:installprivlib`
for d in $installsitelib $installvendorlib $installprivlib; do
  [ -z "$d" -o "$d" = "UNKNOWN" -o ! -d "$RPM_BUILD_ROOT$d" ] && continue
  find $RPM_BUILD_ROOT$d/* -type d \
  | grep -v "/$archname\(/auto\)\?$" \
  | sed "s@^$RPM_BUILD_ROOT@%dir @g" \
  >> %{name}-%{version}-%{release}-filelist
done

if [ "$(cat %{name}-%{version}-%{release}-filelist)X" = "X" ] ; then
    echo "ERROR: EMPTY FILE LIST"
    exit 1
fi

cp -av etc $RPM_BUILD_ROOT/
mv $RPM_BUILD_ROOT/etc/init.d/rpm.m3 $RPM_BUILD_ROOT/etc/init.d/m3
rm -f $RPM_BUILD_ROOT/etc/init.d/deb.m3

%clean
rm -rf $RPM_BUILD_ROOT

%files -f %{name}-%{version}-%{release}-filelist
%defattr(-,root,root,-)
%doc Changes README eg
/etc/init.d/m3
%config(noreplace) /etc/m3.d
%config(noreplace) /etc/logrotate.d/m3
%config(noreplace) /etc/rsyslog.d/m3.conf
%config(noreplace) /etc/sysconfig/m3

%changelog
* Fri Apr  5 2013 Dan Fruehauf <malkodan@gmail.com> - 3.12-1
- Added version switch for invocation
- Support for multi-column queries in DBI module
- Depending on perl-Monitis now (Perl-SDK)

* Sat Nov 3 2012 Dan Fruehauf <malkodan@gmail.com> - 3.11-1
- Added disk usage agent
- init.d service for RHEL/CentOS is a bit better at stopping the service
- Reduced some log messages to debug, so the main log doesn't get spammed
- Handling case if monitor exists on sandbox
- Rixed cleanup of M3Logger
- Added port_monitor.xml, used to monitor open ports easily
- Removed redundant code - now working with syslog
- Fixed parameter extraction of boolean values
- Another tiny fix for boolean value parsing in Regex.pm
- Added rsyslog.d m3.conf file

* Wed Aug 15 2012 Dan Fruehauf <malkodan@gmail.com> - 3.10-1
- Fixed issues with binary value parsing in Regex.pm
- Added syslog logging
- Improved bandwidth monitor
- Fixed bug where empty result set was sent to server
- Added nginx_monitor.xml - monitor for nginx StubStatus module
- Code cleanup of callbacks - cleaner now
- Improved parsing of boolean values
- Rearranged eg directory
- Added linux_bandwidth_monitor.xml

* Fri May 18 2012 Dan Fruehauf <malkodan@gmail.com> - 3.6-1
- Added raw command for listing and deleting monitors

* Tue May 1 2012 Dan Fruehauf <malkodan@gmail.com> - 3.4-1
- Initial release which actually works

* Mon Apr 30 2012 Dan Fruehauf <malkodan@gmail.com> - 3.3-8
- Specfile autogenerated with command '/usr/bin/cpanflute2 --just-spec /tmp/MonitisMonitorManager-3.3.tar.gz'

