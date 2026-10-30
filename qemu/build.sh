#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build Ubuntu's qemu source package with EZGH's patches (qemu/patches, in order) under
# a +ezghN version, then install the built qemu-utils and run qemu/check.sh against it.
# Writes the host's binary packages, the source package and SHA256SUMS to $OUT.
#
# Runs as root inside ubuntu:26.04 (amd64), see README.md ("QEMU"). Hours: Ubuntu's
# rules build every system and user target. Env: WORK (default /build), OUT, JOBS (default 16),
# HOST_UID chowns OUT at the end. Mount the host CA bundle at /hostca.pem.
set -euo pipefail

UBUNTU_VER=1:10.2.1+ds-1ubuntu3.2 # as pinned in the hosts' OS releases
DEB_VER=10.2.1+ds-1ubuntu3.2+ezgh1 # the tag is qemu-v$DEB_VER
VERSION=1:$DEB_VER
# What a hypervisor installs from this source; the rest stay Ubuntu's. qemu-system-data
# (Architecture: all) is only required >> 1:10.2.1+ds~, so Ubuntu's copy keeps working.
PKGS=(qemu-system-x86 qemu-system-common qemu-system-gui qemu-system-modules-opengl
	qemu-system-modules-spice qemu-block-extra qemu-utils)

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/build}
OUT=${OUT:?OUT is not set}
die() { echo "error: $*" >&2; exit 1; }

[ "$(dpkg --print-architecture)" = amd64 ] || die "must run on amd64"
[ "$(id -u)" = 0 ] || die "must run as root (in a container)"

export DEBIAN_FRONTEND=noninteractive
"$REPO/snapshot-apt.sh"
apt-get build-dep -y -q --arch-only "qemu=$UBUNTU_VER"
apt-get install -y -q --no-install-recommends dpkg-dev quilt bc git
# An arch-only build takes the user-mode vDSO archive from the installed qemu-system-data,
# as Debian's arch builds do (Ubuntu builds arch and indep together, so it doesn't list it).
apt-get install -y -q --no-install-recommends "qemu-system-data=$UBUNTU_VER"
git config --global --add safe.directory "$REPO"

mkdir -p "$WORK" "$OUT"
cd "$WORK"
rm -rf qemu ./*.deb ./*.ddeb ./*.dsc ./*.debian.tar.xz
apt-get source -q --download-only "qemu=$UBUNTU_VER"
dpkg-source -x "qemu_${UBUNTU_VER#1:}.dsc" qemu >/dev/null
cd qemu

# dpkg-source applied Ubuntu's series; add ours on top with quilt, which records them
# in .pc as 3.0 (quilt) expects.
export QUILT_PATCHES=debian/patches
mkdir -p debian/patches/ezgh
for p in "$REPO"/qemu/patches/*.patch; do
	cp "$p" debian/patches/ezgh/
	echo "ezgh/$(basename "$p")" >> debian/patches/series
	quilt push -q || die "$(basename "$p") does not apply"
done

SOURCE_DATE_EPOCH=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)
export SOURCE_DATE_EPOCH
{
	echo "qemu ($VERSION) resolute; urgency=medium"
	echo
	for p in "$REPO"/qemu/patches/*.patch; do
		echo "  * d/p/ezgh/$(basename "$p"):"
		# The Subject header, with its folded continuation lines joined.
		awk '/^Subject: /{s=$0; sub(/^Subject: \[PATCH[^]]*\] /,"",s); on=1; next}
			on && /^ /{s=s $0; next} on{exit} END{print s}' "$p" | fold -s -w 70 | sed 's/^/    /'
	done
	echo
	echo " -- EZGH Cloud <matthewzhaocc@gmail.com>  $(date -R -u -d "@$SOURCE_DATE_EPOCH")"
	echo
	cat debian/changelog
} > debian/changelog.new
mv debian/changelog.new debian/changelog
[ "$(dpkg-parsechangelog -S Version)" = "$VERSION" ] || die "changelog version is not $VERSION"

# Capped: CI runners report 80 CPUs with far less memory, and 80 parallel compiles and links
# got the build container killed.
JOBS=${JOBS:-$(( $(nproc) < 16 ? $(nproc) : 16 ))}
DEB_BUILD_OPTIONS="nocheck parallel=$JOBS" dpkg-buildpackage --build=source,any -uc -us
cd "$WORK"

# Check the built QEMU before anything is published.
apt-get install -y -q --no-install-recommends "./qemu-utils_${DEB_VER}_amd64.deb"
[ "$(dpkg-query -W -f='${Version}' qemu-utils)" = "$VERSION" ] || die "qemu-utils $VERSION is not installed"
"$REPO/qemu/check.sh"

rm -f "$OUT"/*.deb
for pkg in "${PKGS[@]}"; do
	cp "${pkg}_${DEB_VER}_amd64.deb" "$OUT/" || die "no $pkg package"
done
cp "qemu_$DEB_VER.dsc" "qemu_$DEB_VER.debian.tar.xz" "$REPO"/qemu/patches/*.patch "$OUT/"
cd "$OUT"
sha256sum ./*.deb ./*.dsc ./*.debian.tar.xz ./*.patch | sed 's| \./| |' > SHA256SUMS
cat SHA256SUMS
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID" "$OUT"; fi
