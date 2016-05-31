#!/bin/sh -ex

export PATH="${PATH}:/usr/sbin:/sbin"

# Wait for the network to come up
while ! ping -c1 github.com; do sleep 10; done

# Get the key for ZoL
apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 8E234FB17DFFA34D

# Update sources.list
cat <<EOF > /etc/apt/sources.list.d/zol.list
deb [arch=amd64] http://celia.bayour.com/debian-zol ${DIST} main
EOF

su jenkins -c "cd ~jenkins/build/\${DIST} ; $*"
