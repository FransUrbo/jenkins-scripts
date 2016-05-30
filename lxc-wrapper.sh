#!/bin/sh -ex

export PATH="${PATH}:/usr/sbin:/sbin"
su jenkins -c "cd ~jenkins/build/\${DIST} ; $*"
