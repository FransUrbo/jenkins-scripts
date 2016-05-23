#!/bin/sh

rm -Rf jobs/Build_ZoL_SPL/builds
rm -Rf jobs/Build_ZoL_SPL/configurations
rm -Rf jobs/Build_ZoL_SPL/workspace* \
rm -Rf jobs/Build_ZoL_SPL/lastS*
rm -Rf jobs/Build_ZoL_SPL/github-polling.log
echo 1 > jobs/Build_ZoL_SPL/nextBuildNumber
