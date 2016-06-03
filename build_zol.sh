#!/bin/sh -xe

# No checking for correct, missing or faulty values will be done in this
# script. This is the second part of a automated build process and is
# intended to run inside a Docker container. See comments in
# 'setup_and_build.sh' for more information.
#
# The use of 'master' and 'snapshot' (the two options) doesn't refer to the
# master branch, but the base of the pkg-{spl,zfs} branch trees in the
# pkg-{spl,zfs} repositories. The 'master' tree is the released versions
# and 'snapshot' are the dailies.
#
# If running under Jenkins, it is/should be responsible for checking out
# the code into WORKDIR. If $JENKINS_HOME is NOT set (as in not running
# under Jenkins), the code will be cloned and checked out.
#
# Copyright 2016 Turbo Fredriksson <turbo@bayour.com>.
# Released under GPL, version of your choosing.

echo "=> Building (${APP}/${DIST}/${BRANCH})"

if [ -n "${payload}" ]; then
    echo "====================="
    echo "payload:"
    echo "${payload}"
    echo "====================="
fi

# If we haven't mounted the $HOME/.ssh directory into the Docker container,
# the known_hosts don't exit. However, if we have a local copy (in the
# scratch dir), then use that.
# To avoid a 'Do you really want to connect' question, make sure that the
# hosts we're using is all in there.
if [ ! -f "${HOME}/.ssh/known_hosts" -a "/tmp/scratch/known_hosts" ]
then
    # We probably don't have the .ssh directory either, so create it.
    [ -d "${HOME}/.ssh" ] || mkdir -p "${HOME}/.ssh"
    cp /tmp/scratch/known_hosts "${HOME}/.ssh/known_hosts"
fi


# --------------------------------
# --> C O D E  C H E C K O U T <--
# --------------------------------

# --> This is where we (possibly) download the code.
# --> Should only happen if we're NOT running under Jenkins.

# Setup user for commits (including merges).
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"

if [ -z "${JENKINS_HOME}" ]; then
    # Checking out the code.
    if [ -d "pkg-${APP}" ]; then
	cd pkg-${APP}

	find -name .gitignore | xargs --no-run-if-empty rm
	git clean --force -d
	git reset --hard
    else
	git clone --origin pkg-${APP} git@github.com:zfsonlinux/pkg-${APP}.git
	cd pkg-${APP}

	# Add remote ${APP}.
	git remote add ${APP} git@github.com:zfsonlinux/${APP}.git
	git fetch ${APP}
    fi
fi


# ----------------------------------
# --> C O D E  D I S C O V E R Y <--
# ----------------------------------

# --> This is where we figure out _what_ to build. This is dependent
# --> on how we're called - app, branch and dist.
# --> Checks out the correct branch, figure out the upstream version,
# --> merge in (possible) upstream changes and then sets up the version
# --> number accordingly.
# --> We have a couple of exit strategies in place here an there to make
# --> sure we only build stuff that's actually new.

# TODO - eventually we might want to push non-debian branches to.
# If a previous successfull checkout of a non-debian version below created
# a branch, we need to destroy it here. Better than forcing a destroy of the
# whole workspace before build starts.
if ! echo "${DIST}" | grep -Eq "wheezy|jessie|sid" && \
    (git show ${BRANCH}/debian/${DIST} || \
     git show pkg-${APP}/${BRANCH}/debian/${DIST}) > /dev/null 2>&1
then
    git checkout pkg-${APP}/readme

    # Remove any matching branch we find.
    (git branch ; git branch -r) | sort | uniq | \
	grep "${BRANCH}/debian/${DIST}" | \
	while read branch; do
	    git branch -D "${branch}"
	done

    # Remove any tags as well.
    (git tag ; git tag -l ${BRANCH}/debian/${DIST}/*) | sort | uniq | \
	grep "${BRANCH}/debian/${DIST}" | \
	while read snap; do
	    git tag -d "${snap}"
	done
fi

# NOTE: Jenkins checkes out a commitId, even if a branch is specified!!

# 1. Checkout the correct branch.
if ! git show pkg-${APP}/${BRANCH}/debian/${DIST} > /dev/null 2>&1; then
    # Branch don't exist - use the 'jessie' branch, because that's currently the latest.
    # If the system is very different from this, the build will probably fail, but it's
    # a start.
    git checkout -b ${BRANCH}/debian/${DIST} pkg-${APP}/${BRANCH}/debian/jessie
else
    # Not a snapshot - get the correct branch.
    git checkout ${BRANCH}/debian/${DIST}
fi

# 2. Check which branch to use for version check and to get 'latest' from.
if [ "${BRANCH}" = "snapshot" ]; then
    branch="${APP}/master"
else
    branch="$(git tag -l ${APP}-[0-9]* | tail -n1)"
fi

# 3. Make sure that the code in the branch have changed.
file="/tmp/scratch/lastSuccessfulSha-${APP}-${DIST}-${BRANCH}"
sha="$(git log --pretty=oneline --abbrev-commit ${branch} | \
    head -n1 | sed 's@ .*@@')"
if [ "${FORCE}" = "false" -o -z "${FORCE}" ] && [ -f "${file}" ]; then
    old="$(cat "${file}")"
    if [ "${sha}" = "${old}" ]; then
        echo "=> No point in building - same as previous version."
        exit 0
    fi
fi

# 4. Get the latest upstream tag.
#    If there's no changes, exit successfully here.
#    However, if we're called with FORCE set, then ignore this and continue
#    anyway.
git merge -Xtheirs --no-edit ${branch} 2>&1 | \
    grep -q "^Already up-to-date.$" && \
    no_change=1
if [ "${FORCE}" = "false" -o -z "${FORCE}" ] && [ "${no_change}" = "1" ]
then
    echo "=> No point in building - same as previous version."
    exit 0
fi

# 5. Calculate the next version.
if [ -e "/etc/debian_version" ]; then
    # Some ugly magic here.
    nr="$(head -n1 debian/changelog | sed -e "s@.*(\(.*\)).*@\1@" \
	-e "s@^\(.*\)-\([0-9]\+\)-\(.*\)\$@\2@" -e "s@^\(.*\)-\([0-9]\+\)\$@\2@")"
else
    nr="$(grep ^Branch META  | sed 's@.*\.@@')"
fi
pkg_version="$(git describe ${branch} | sed "s@^${APP}-@@")"

if [ "${BRANCH}" = "snapshot" ]; then
    # Allow seemless upgrades between released -> dailies -> different dists.
    # => "0.6.5.6-8-wheezy"                        <= "0.6.5.990-245-gf00828e-244-wheezy-daily"
    # => "0.6.5.990-245-gf00828e-244-wheezy-daily" <= "0.6.5.991-245-gf00828e-244-jessie-daily"
    # => !! Can't go from "dailies" to "released" though !!
    case "${DIST}" in
	wheezy)	subver=".990";;
	jessie)	subver=".991";;
	sid)	subver=".999";;

	trusty)	subver=".990";;
	utopic)	subver=".991";;
	vivid)	subver=".992";;
	wily)	subver=".993";;
	xenial)	subver=".994";;

	*)	subver="";;
    esac

    pkg_version="$(echo "${pkg_version}" | \
	sed "s@\([0-9]\.[0-9]\.[0-9]\)-\(.*\)@\1${subver}-\2@")-${DIST}-daily"
else
    pkg_version="${pkg_version}-$(expr ${nr} + 1)-${DIST}"
fi


# ----------------------------------
# --> P A C K A G E  U P D A T E <--
# ----------------------------------

# --> This is where we update the debian/changelog (if building debs) and sets up
# --> a change log message.

if [ -e "/etc/debian_version" ]; then
    # 6. Setup debian directory.
    echo "=> Start with a clean debian/controls file"
    debian/rules override_dh_prep-base-deb-files

    # 7. Update the GBP config file
    sed -i -e "s,^\(debian-branch\)=.*,\1=${BRANCH}/debian/${DIST}," \
	   -e "s,^\(debian-tag\)=.*\(/\%.*\),\1=${BRANCH}/debian/${DIST}\2," \
	   -e "s,^\(upstream-.*\)=.*,\1=${branch},"  debian/gbp.conf
    
    # 8. Update and commit
    echo "=> Update and commit the changelog"
    if [ "${BRANCH}" = "snapshot" ]; then
	dist="${DIST}-daily"
	msg="daily"

	# Dirty hack, but it's the fastest, easiest way to solve
	#   E: spl-linux changes: bad-distribution-in-changes-file sid-daily
	# Don't know why I don't get that for '{wheezy,jessie}-daily as well,
	# but we do this for all of them, just to make sure.
	CHANGES_DIR="/usr/share/lintian/vendors/debian/main/data/changes-file"
	sudo mkdir -p "${CHANGES_DIR}"
	if [ ! -f "${CHANGES_DIR}/known-dists" ]
	then
	    echo "${dist}" | sudo tee "${CHANGES_DIR}/known-dists" > /dev/null
	else
	    echo "${dist}" | sudo tee -a "${CHANGES_DIR}/known-dists" > /dev/null
	fi
    else
	dist="${DIST}"
	msg="upstream"
    fi
fi

if [ "${BRANCH}" = "snapshot" -a "${PATCHES}" = "true" -a \
     "${DIST}" != "wheezy" ]
then
    # Force pull debian/patches from snapshot/debian/wheezy.
    # This allow us to update the patches in ONE branch manually,
    # and these will be then used in every other build.
    git checkout pkg-${APP}/snapshot/debian/wheezy -- debian/patches
    git add debian/patches/*
    patches_updated_msg="Debian patches updated - "
fi

changed="$(git status | grep -E 'modified:|deleted:|new file:' | wc -l)"
if [ "${changed}" -gt 0 -o "${FORCE}" != "true" ]; then
    commit="<<EOF
New ${msg} release - ${patches_updated_msg}$(date -R)/${sha}.

$(git log --pretty=oneline --abbrev-commit ${GIT_PREVIOUS_COMMIT}..HEAD)
EOF
"
fi

if [ -e "/etc/debian_version" ] && [ "${changed}" -gt 0 -o "${FORCE}" != "true" ];
then
    # Only change the changelog if we have to!
    debchange --distribution "${dist}" --newversion "${pkg_version}" \
	      --force-bad-version --force-distribution \
	      --maintmaint "${commit}"
fi


# -----------------------------------
# --> S T A R T  T H E  B U I L D <--
# -----------------------------------

# --> Ah, this is the interesting bit. The one we've worked so hard
# --> to get to - "The Build(tm)"!
# --> But before that, we need to install any build dependencies and
# --> tag changed files as "ready for commit".
# --> Again, we offer an exit strategy in case the packages have already
# --> been built.
# --> Depending on if we're building debs or rpms, we do things differently.

if [ -e "/etc/debian_version" ]; then
    # Install dependencies
    deps="$(dpkg-checkbuilddeps 2>&1 | \
	sed -e 's,.*dependencies: ,,' -e 's, (.*,,')"
    while [ -n "${deps}" ]; do
	export PATH="${PATH}:/usr/sbin:/sbin"

	echo "=> Installing package dependencies"
	sudo apt-get update > /dev/null 2>&1
	sudo apt-get install -y ${deps} > /dev/null 2>&1
	if [ "$?" = "0" ]; then
	    deps="$(dpkg-checkbuilddeps 2>&1 | \
		sed -e 's,.*dependencies: ,,' -e 's, (.*,,')"
	else
	    echo "   ERROR: install failed"
	    exit 1
	fi
    done
elif type yum > /dev/null 2>&1; then
    deps="$(grep ^BuildRequires: rpm/generic/${APP}.spec.in | sed 's@.*: @@')"
    if [ -n "${deps}" ]; then
	echo "=> Installing package dependencies"

	# Newer Fedora uses "dnf" instead of "yum". Same parameters though,
	# which is lucky..
	type dnf > /dev/null 2>&1 && \
	    pkg="dnf" || pkg="yum"

	# Some of these might be already installed, but it's simpler
	# just to try to install all of them, than to filter out those
	# that already exists. Doesn't make one bit of difference, other
	# than less coding :).
	sudo ${pkg} install -y ${deps}
	if [ "$?" != "0" ]; then
	    echo "   ERROR: install failed"
	    exit 1
	fi
    fi
fi

if [ "${changed}" -gt 0 ]; then
    [ -e "/etc/debian_version" ] && \
	git add META debian/changelog debian/gbp.conf
    git commit -m "${commit}"
fi

# Build packages
if [ -e "/etc/debian_version" ]; then
    echo "=> Build the packages"
    type git-buildpackage > /dev/null 2>&1 && \
	gbp="git-buildpackage" || gbp="gbp buildpackage"

    if [ "${FORCE}" = "true" ]; then
	retag="--git-retag"
    else
	pkg_ver="$(head -n1 debian/changelog | sed "s@.*(\(.*\)).*@\1@")"
	if git show "${BRANCH}/debian/${DIST}/${pkg_ver}" > /dev/null 2>&1;
	then
	    # Branch already exists, and we're not running in force mode
	    echo "=> No point in building - tag already exists so already built."
	    exit 0
	fi
    fi

    ${gbp} --git-ignore-branch --git-keyid="${GPKGKEYID}" --git-tag \
	   --git-ignore-new --git-builder="debuild -i -I -k${GPGKEYID}" \
	   ${retag}
elif type rpmbuild > /dev/null 2>&1; then
    if [ -f "debian/patches/series" ]; then
	echo "=> Applying patches to non-debian tree"
	cat debian/patches/series | grep -v "^#" | \
	    while read patch; do
		patch -p1 < "debian/patches/${patch}"
	    done
    fi
    if [ "${APP}" = "zfs" -a -f "/tmp/scratch/rpm_zfs-EXTRA_DIST.patch" ]
    then
	# This patch is to make sure that the examples in etc/zfs
	# is included in the source RPM.
	echo "=> Applying rpm fixes"
	cat /tmp/scratch/rpm_zfs-EXTRA_DIST.patch | \
	    patch -p0
    fi
    
    # Configure options to avoid building binary modules.
    conf_opts="--with-config=user --bindir=/bin --sbindir=/sbin"
    conf_opts="${conf_opts} --libdir=/lib --with-udevdir=/lib/udev"
		 
    # Build
    [ -e "configure" ] || ./autogen.sh
    [ -e "Makefile" ] || ./configure ${conf_opts}
    [ -e "rpm/generic/${APP}.spec" ] && make rpm-utils
fi


# ------------------------
# --> F I N I S H  U P <--
# ------------------------

# --> All done! Now time to upload our finished packages to our FTP
# --> archive. Also allow for Jenkins to archive the artifacts and to
# --> push any new branches and/or tags to GitHub (only if building debs
# --> for now).
# --> At the very end, we just record this commit as a successful build.

# Upload packages
if [ -e "/etc/debian_version" ]; then
    changelog="${APP}-linux_$(head -n1 debian/changelog | \
	sed "s@.*(\(.*\)).*@\1@")_$(dpkg-architecture -qDEB_BUILD_ARCH).changes"
fi

# Need to set the directory to the artifacts.
dir="/home/jenkins/build/"
[ -z "${JENKINS_HOME}" ] && dir="${dir}/${DIST}/"

# Possibly do the upload
if [ "${NOUPLOAD}" = "false" -o -z "${NOUPLOAD}" ]; then
    echo "=> Upload packages"
    if [ -e "/etc/debian_version" ]; then
	dupload "${dir}${changelog}"
    else
	# TODO: This is kind'a hardcoded - is there any option in Jenkins
	#       we could use?
	scp *.rpm turbo@celia:/usr/src/incoming.jenkins/
    fi
fi

# Copy artifacts so they can be archived in Jenkins.
if [ -z "${JENKINS_HOME}" ]; then
    # If not running under Jenkins, we need to add
    # 'pkg-${APP}' to the path.
    adir="${dir}/${DIST}/pkg-${APP}/artifacts"
else
    adir="${dir}/${DIST}/artifacts"
fi
mkdir -p "${adir}"

# Read the changelog up to the first '^Checksums-*' line.
if [ -e "/etc/debian_version" ]; then
    cat "${dir}${changelog}" | \
    while read line; do
	if echo "${line}" | grep -q "^Checksums-"; then
	    files="$(while read line; do
		# Keep reading up to next '^Checksums-*' line.
		echo "${line}" | grep -Eq "^Checksums-" && \
		break || \
		echo "${line}" | sed "s@.* @${dir}@"
	    done)"

	    OLD_IFS="${IFS}"
	    IFS="
"
	    cp $(echo "${files}") "${dir}${changelog}" "${adir}"
	    IFS="${OLD_IFS}"
	    break
	fi
    done
else
    cp *.rpm "${adir}"
fi

# Push our changes to GitHub
if [ -e "/etc/debian_version" ]; then
    # TODO - eventually we might want to push non-debian branches to.
    if echo "${DIST}" | grep -Eq "wheezy|jessie|sid"; then
	git push pkg-${APP} --force --all
	git push pkg-${APP} --force --tags
    fi
fi

# Record changes
echo "=> Recording successful build (${sha})"
echo "${sha}" > "/tmp/scratch/lastSuccessfulSha-${APP}-${DIST}-${BRANCH}"

exit 0
