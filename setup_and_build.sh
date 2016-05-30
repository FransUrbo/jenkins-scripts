#!/bin/sh -xe

# Path to the actual build script. This should be the only manual change
# needed.
BUILD_SCRIPT="/tmp/scratch/build_zol.sh"

# Docker resource limiting options
# https://docs.docker.com/engine/reference/run/#runtime-constraints-on-resources
DOCKER_OPTS="--memory=512MB --memory-swap=300MB"

# What container engine to use ('lxc' or 'docker').
[ -z "${CONTAINER_ENGINE}" ] && CONTAINER_ENGINE="docker"

# ========================================================================
# This is the primary build script (of two) intended to build ZFS On Linux
# Debian GNU/Linux packages.
#
# It will start a GNUPG Agent, prime the passphrase and then start a
# Docker container and in that run the second, actual, build script.
#
# It is intended (built for) to run from a Jenkins multi-configuration
# project. To avoid hard coded values in the scripts, it require some
# environment variables injected into the build process:
#   * As build parameters:
#     These will be passed on to the build script, and can there for be
#     seen in a 'ps' output!
#     APP			What repository to build (spl, zfs)
#     DIST			What distribution to build for (wheezy,
#				jessie, sid)
#     BRANCH			What base branch to build (master, snapshot)
#   * From the 'Environment Injector' plugin:
#     + As a 'normal' environment variable
#       These will be passed on to the build script, and can there for be
#       seen in a 'ps' output!
#       GIT_AUTHOR_NAME		Full name to use for commits
#       GIT_AUTHOR_EMAIL	Email address to use for commits
#     + As a password environment variable (will be masked).
#       These will NOT be passed on to the build script.
#       GPGCACHEID		GPG Key ID. See gpg-preset-passphrase(1)
#       GPGPASS			GPG Passphrase
#       GPGKEYID		GPG Key ID
# If not running from Jenkins, set this in the environment normaly.
#
# The following optional values can be set:
#   FORCE               Ignore existing build (true, false)
#   NOUPLOAD            Don't run dupload on the changes (set, unset)
#
# The 'WORKSPACE' variable is set by Jenkins for every job and is the path
# to the base build directory (where the GIT project is checked out and
# build), but if it's not set, it will be set in the script to something
# resonable.
#
# Inside the container, the user 'jenkins' is used, so the image(s) must
# have that user with a writable homedirectory. In that homedirectory,
# a 'build' directory must be created. The $WORKSPACE will be mounted
# in ~jenkins/build/src and the artifacts (packages, changes etc) will
# then be created in the ~jenkins/build directory. These will only be
# accessible from inside the container - when the container terminates,
# the artifacts will be lost.
# The build script takes that into account by copying them into the
# 'artifacts' directory (=> $WORKSPACE/artifacts) for archiving by
# Jenkins.
#
# Copyright 2016 Turbo Fredriksson <turbo@bayour.com>.
# Released under GPL, version of your choosing.
# ========================================================================

if echo "${*}" | grep -qi "help"; then
    echo "Usage: $(basename ${0}) <app> <dist> <branch>"
    exit 1
elif [ -n "${1}" -a -n "${2}" -a -n "${3}" ]; then
    APP="${1}" ; DIST="${2}" ; BRANCH="${3}"
fi

if [ -z "${APP}" -o -z "${DIST}" -o -z "${BRANCH}" -o -z "${GIT_AUTHOR_NAME}" \
	-o -z "${GIT_AUTHOR_EMAIL}" -o -z "${GPGCACHEID}" -o -z "${GPGPASS}" \
	-o -z "${GPGKEYID}" ]
then
    echo -n "ERROR: One (or more) of APP, DIST, BRANCH, GITNAME, GITEMAIL, "
    echo -n "GPGCACHEID, GPGPASS and/or GPGKEYID environment variable is "
    echo "missing!"
    echo "Usage: $(basename "${0}") <app> <dist> <branch>"
    exit 1
fi

cleanup() {
    # Kill the GPG Agent
    echo "${GPG_AGENT_INFO}" | sed "s,.*:\(.*\):.*,\1," | \
        xargs --no-run-if-empty kill

    # Kill the LXC container (don't care if it exists or not).
    [ "${CONTAINER_ENGINE}" = "lxc" ] && \
	lxc stop "${DIST}-devel" --force > /dev/null 2>&1
}
trap cleanup EXIT

# This can be randomized if it's not supplied. This so that we
# can run this from the shell if we want to.
[ -z "${WORKSPACE}" ] && WORKSPACE="/var/lib/jenkins/tmp/docker_build-${APP}_$$"
[ -d "${WORKSPACE}" ] || mkdir -p "${WORKSPACE}/${DIST}"
if [ -z "${JENKINS_HOME}" ]; then
    WORKSPACE_DIR="${WORKSPACE}"
else
    WORKSPACE_DIR="$(dirname "${WORKSPACE}")"
fi

echo "=> Setting up a Docker build (${APP}/${DIST}/${BRANCH})"

if echo "$*" | grep -q bash; then
    # Run container interactive...
    if [ "${CONTAINER_ENGINE}" = "docker" ]; then
	IT="-it"
    elif [ "${CONTAINER_ENGINE}" = "lxc" ]; then
	IT="--mode=interactive"
    fi

    script="/bin/bash -li" # Shell to spawn in container
else
    [ "${CONTAINER_ENGINE}" = "lxc" ] && IT="--mode=non-interactive"
    script="${BUILD_SCRIPT} ${APP} ${DIST} ${BRANCH}"
fi

# Start a GNUPG Agent and prime the passphrase so that signing of the
# packages etc work without intervention.
echo "=> Start and prime gnupg"
eval $(gpg-agent --daemon --allow-preset-passphrase \
		 --write-env-file "${WORKSPACE}/.gpg-agent.info")
echo "${GPGPASS}" | /usr/lib/gnupg2/gpg-preset-passphrase -v -c ${GPGCACHEID}

# Start a docker container.
# Inside there is where the actual build takes place, using the
# 'build_zol.zh' script.
set +e ; cnt=0
echo "=> Starting docker image fransurbo/devel:${DIST}"
while /bin/true; do
    # Launch the container.
    if [ "${CONTAINER_ENGINE}" = "docker" ]; then
	docker -H tcp://127.0.0.1:2375 run -u jenkins \
	    -v "${HOME}/.gnupg":"/home/jenkins/.gnupg" \
	    -v $(dirname "${SSH_AUTH_SOCK}"):"$(dirname ${SSH_AUTH_SOCK})" \
	    -v $(dirname "${GPG_AGENT_INFO}"):"$(dirname ${GPG_AGENT_INFO})" \
	    -v "${WORKSPACE_DIR}":"/home/jenkins/build" \
	    -v "${HOME}/scratch":"/tmp/scratch" \
	    -w "/home/jenkins/build/${DIST}" \
	    -e FORCE="${FORCE}" \
	    -e NOUPLOAD="${NOUPLOAD}" \
	    -e PATCHES="${PATCHES}" \
	    -e APP="${APP}" \
	    -e DIST="${DIST}" \
	    -e BRANCH="${BRANCH}" \
	    -e JENKINS_HOME="${JENKINS_HOME}" \
	    -e LOGNAME="${LOGNAME}" \
	    -e SSH_AUTH_SOCK="${SSH_AUTH_SOCK}" \
	    -e GPG_AGENT_INFO="${GPG_AGENT_INFO}" \
	    -e GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME}" \
	    -e GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL}" \
	    -e GIT_PREVIOUS_COMMIT="${GIT_PREVIOUS_COMMIT}" \
	    -e GPGKEYID="${GPGKEYID}" \
	    -e WORKSPACE="${WORKSPACE}" \
	    -e payload="${payload}" \
	    --rm ${IT} ${DOCKER_OPTS} fransurbo/devel:${DIST} ${script}
	res="$?"
    elif [ "${CONTAINER_ENGINE}" = "lxc" ]; then
	#    -c limits.cpu.allowance=50% \
	# => error: Error calling 'lxd forkstart wheezy-devel /var/lib/lxd/containers /var/log/lxd/wheezy-devel/lxc.conf': err='exit status 1'
	lxc launch -e "${DIST}-devel" "${DIST}-devel" \
	    -c limits.cpu=1 \
	    -c limits.memory=512MB \
	    -c limits.memory.enforce=hard \
	    -c security.privileged=true \
	    -c environment.FORCE="${FORCE}" \
	    -c environment.NOUPLOAD="${NOUPLOAD}" \
	    -c environment.PATCHES="${PATCHES}" \
	    -c environment.APP="${APP}" \
	    -c environment.DIST="${DIST}" \
	    -c environment.BRANCH="${BRANCH}" \
	    -c environment.JENKINS_HOME="${JENKINS_HOME}" \
	    -c environment.LOGNAME="${LOGNAME}" \
	    -c environment.SSH_AUTH_SOCK="${SSH_AUTH_SOCK}" \
	    -c environment.GPG_AGENT_INFO="${GPG_AGENT_INFO}" \
	    -c environment.GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME}" \
	    -c environment.GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL}" \
	    -c environment.GIT_PREVIOUS_COMMIT="${GIT_PREVIOUS_COMMIT}" \
	    -c environment.GPGKEYID="${GPGKEYID}" \
	    -c environment.WORKSPACE="${WORKSPACE}" \
	    -c environment.payload="${payload}"
	[ "$?" -ge 1 ] && continue
	
	# Attach directories.
	lxc config device add "${DIST}-devel" gnupg disk \
	    source="${HOME}/.gnupg" path="/home/jenkins/.gnupg"
	if [ "$?" -ge 1 ]; then
	    lxc stop "${DIST}-devel"
	    continue
	fi

	dir="$(dirname "${SSH_AUTH_SOCK}")"
	lxc config device add "${DIST}-devel" sshsock disk \
	    source="${dir}" path="${dir}"
	if [ "$?" -ge 1 ]; then
	    lxc stop "${DIST}-devel"
	    continue
	fi

	dir="$(dirname "${GPG_AGENT_INFO}")"
	lxc config device add "${DIST}-devel" gpgagent disk \
	    source="${dir}" path="${dir}"
	if [ "$?" -ge 1 ]; then
	    lxc stop "${DIST}-devel"
	    continue
	fi

	lxc config device add "${DIST}-devel" workspace disk \
	    source="${WORKSPACE_DIR}" path="/home/jenkins/build" \
	    recursive=true
	if [ "$?" -ge 1 ]; then
	    lxc stop "${DIST}-devel"
	    continue
	fi

	lxc config device add "${DIST}-devel" scratch disk \
	    source="${HOME}/scratch" path="/tmp/scratch"
	if [ "$?" -ge 1 ]; then
	    lxc stop "${DIST}-devel"
	    continue
	fi

	# Run script in the container.
	lxc exec ${IT} "${DIST}-devel" -- /tmp/scratch/lxc-wrapper.sh ${script}
	res=$?
    else
	echo "ERROR: Unknown engine '${CONTAINER_ENGINE}'"
	exit 1
    fi

    # No matter what, we need to shutdown the LXC container, So it can be
    # recreated.
    [ "${CONTAINER_ENGINE}" = "lxc" ] && lxc stop "${DIST}-devel" --force

    # Check build result.
    if [ "${res}" -eq "0" ]; then
	# Build script exited with success - exit success.
	exit 0
    elif [ "${res}" -eq "1" ]; then
	# Build script exited with failure - exit with error.
	echo "=> Build failed."
	exit 1
    elif [ "${cnt}" -ge "5" ]; then
	# ERROR. And we've tried long enough - exit error.
	echo "=> Tried five times, wouldn't start!"
	exit 1
    else
	# Lets try again. In 30 seconds.
	echo -n "."
	cnt="$(expr "${cnt}" + 1)"
	sleep 30
    fi
done
