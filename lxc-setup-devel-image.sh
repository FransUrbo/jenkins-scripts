#!/bin/sh

# ========================================================================
# This is the primary script (of two) to setup a build environment for LXC.
#
# This script depend on already downloaded images from "images:".
#
# Copyright 2016 Turbo Fredriksson <turbo@bayour.com>.
# Released under GPL, version of your choosing.
# ========================================================================

set -ex

if [ -z "${1}" ]; then
    echo "Usage: $(basename "${0}") <dist>"
    exit 1
else
    DIST="${1}"
fi

lxc launch ${DIST} ${DIST}
lxc file push ~jenkins/scratch/image-setup.sh ${DIST}/tmp/
lxc exec ${DIST} /tmp/docker-image-setup.sh
lxc stop ${DIST} --force
lxc snapshot ${DIST} ${DIST}-devel
lxc copy ${DIST}/${DIST}-devel local:${DIST}-devel
lxc delete ${DIST}
lxc publish local:${DIST}-devel --alias ${DIST}-devel
lxc delete ${DIST}-devel
lxc image show ${DIST} | sed "s@\(description:.*\)@\1 - devel install@" | lxc image edit ${DIST}-devel
