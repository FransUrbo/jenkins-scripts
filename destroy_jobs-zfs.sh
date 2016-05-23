#!/bin/sh

rm -Rf jobs/Build_ZoL_ZFS/builds
rm -Rf jobs/Build_ZoL_ZFS/configurations
rm -Rf jobs/Build_ZoL_ZFS/workspace* \
rm -Rf jobs/Build_ZoL_ZFS/lastS*
rm -Rf jobs/Build_ZoL_ZFS/github-polling.log
echo 1 > jobs/Build_ZoL_ZFS/nextBuildNumber
