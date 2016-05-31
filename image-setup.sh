#!/bin/sh

# ========================================================================
# This is the secondary script (of two) to setup a build environment.
# It is intended to be executed inside the container and will install
# and configure the configure the container to do package builds.
#
# Copyright 2016 Turbo Fredriksson <turbo@bayour.com>.
# Released under GPL, version of your choosing.
# ========================================================================

if type apt-get > /dev/null 2>&1; then
   adduser --uid 110 --disabled-login jenkins
else
   adduser --uid 110 -m jenkins
fi
mkdir ~jenkins/build
chown jenkins:jenkins ~jenkins/build

if [ -d /etc/sudoers.d ]; then
   echo 'jenkins ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers.d/jenkins
else
   echo 'jenkins ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers
fi

cat <<EOF > /etc/dupload.conf
package config;
\$default_host = "celia";
\$preupload{'changes'} = '/usr/share/dupload/gpg-check %1';
\$cfg{'celia'} = {
    fqdn => "celia.bayour.com",
    login => "turbo",
    method => "scp",
    incoming => "/usr/src/incoming.jenkins",
    dinstall_runs => 1,
    nonus => 1
};

1;
EOF

if type apt-get > /dev/null 2>&1; then
    # Get the key for ZoL
    apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 8E234FB17DFFA34D

    # Update sources.list
    cat <<EOF > /etc/apt/sources.list.d/zol
deb [arch=amd64] http://celia.bayour.com/debian-zol ${DIST} main
EOF
fi

# Install basic build packages
if type dnf > /dev/null 2>&1; then
   dnf install rpm-build autoconf automake libtool sudo git kernel-devel kernel-headers make
elif type yum > /dev/null 2>&1; then
   yum install rpm-build autoconf automake libtool sudo git kernel-devel kernel-headers make
elif type apt-get > /dev/null 2>&1; then
   # deb http://old-releases.ubuntu.com/ubuntu/ utopic main restricted universe multiverse
   # deb http://old-releases.ubuntu.com/ubuntu/ utopic-proposed main restricted universe multiverse
   # deb http://old-releases.ubuntu.com/ubuntu/ utopic-updates main restricted universe multiverse
   # deb http://old-releases.ubuntu.com/ubuntu/ utopic-security main restricted universe multiverse

   apt-get update
   apt-get install -y build-essential autoconf automake \
	   libtool sudo git make linux-headers-amd64 autogen debhelper \
	   dupload dkms devscripts git-buildpackage iputils-ping \
	   libselinux1-dev uuid-dev zlib1g-dev libblkid-dev dh-systemd \
	   chrpath libattr1-dev apt-utils
   apt-get clean
fi

sed -i "s@^\(Defaults.*requiretty\)@#\1@" /etc/sudoers
