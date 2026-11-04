#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build upstream NFS-Ganesha (with its bundled ntirpc) as nfs-ganesha, nfs-ganesha-ceph and
# nfs-ganesha-rados-grace $DEB_VER from ganesha/debian with EZGH's patches (ganesha/patches,
# in order), against upstream Ceph 20.2.4 client libraries, then install the packages and run
# ganesha/check.sh against them. Writes the binary packages, noble's libicu74 (which
# libcephfs2 needs), the source package and SHA256SUMS to $OUT.
#
# Runs as root inside ubuntu:26.04, see README.md ("NFS-Ganesha"). Minutes. amd64 is what
# hosts run; arm64 builds too, as a local smoke of the packaging only. Env: WORK (default
# /build), OUT, JOBS (default 16), HOST_UID chowns OUT at the end. Mount the host CA bundle
# at /hostca.pem.
set -euo pipefail

UPSTREAM=15.10
DEB_VER=15.10-1+ezgh4 # the tag is ganesha-v$DEB_VER
GANESHA_COMMIT=38f542cd5ef861add07bcf75c3d0496a332d5018 # tag V15.10 (signed by Frank S. Filz)
# Ceph client libraries: download.ceph.com's noble build, the one the hosts' OS release carries.
CEPH_VER=20.2.4-1noble
# libcephfs2 needs ICU 74, which only noble has; published with the packages, so gateway
# hosts need nothing else from noble.
ICU_VER=74.2-1ubuntu3.1
PKGS=(nfs-ganesha nfs-ganesha-ceph nfs-ganesha-rados-grace)

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/build}
OUT=${OUT:?OUT is not set}
die() { echo "error: $*" >&2; exit 1; }

ARCH=$(dpkg --print-architecture)
[ "$ARCH" = amd64 ] || [ "$ARCH" = arm64 ] || die "must run on amd64 (or arm64, for a smoke)"
[ "$(id -u)" = 0 ] || die "must run as root (in a container)"

export DEBIAN_FRONTEND=noninteractive
"$REPO/snapshot-apt.sh"
# Ceph's packages, checked against the Ceph release key (ganesha/ceph-release.asc,
# 08B7 3419 AC32 B4E9 66C1  A330 E84A C2C0 460F 3994). libcephfs2 needs noble's libicu74,
# from noble-updates in the same Ubuntu snapshot; noble is pinned low, so it serves only
# what resolute lacks.
uri=$(awk '/^URIs:/ { print $2; exit }' /etc/apt/sources.list.d/snapshot.sources)
install -D -m 0644 "$REPO/ganesha/ceph-release.asc" /etc/apt/keyrings/ceph-release.asc
cat > /etc/apt/sources.list.d/ceph.sources <<X
Types: deb
URIs: https://download.ceph.com/debian-${CEPH_VER%-*}
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/ceph-release.asc

Types: deb
URIs: $uri
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
X
cat > /etc/apt/preferences.d/noble <<X
Package: *
Pin: release n=noble
Pin-Priority: 100

Package: *
Pin: release n=noble-updates
Pin-Priority: 100
X
apt-get update -q
# apt's solver only takes the exact versions when the libraries are named too.
ceph=(libcephfs-dev librados-dev libcephfs2 libcephfs-proxy2 librados2)
apt-get install -y -q --no-install-recommends dpkg-dev quilt git ca-certificates openssl \
	"libicu74=$ICU_VER" "${ceph[@]/%/=$CEPH_VER}"

mkdir -p "$WORK" "$OUT"
cd "$WORK"
rm -rf nfs-ganesha-git "nfs-ganesha-$UPSTREAM" nfs-ganesha_* ./*.deb ./*.ddeb
apt-get download -q "libicu74=$ICU_VER"
# The tag and its submodules (ntirpc; libkmip, which FSAL_CEPH's fscrypt support builds),
# pinned by the commit the tag points at.
git clone -q --depth 1 --branch "V$UPSTREAM" --recurse-submodules --shallow-submodules \
	https://github.com/nfs-ganesha/nfs-ganesha nfs-ganesha-git
[ "$(git -C nfs-ganesha-git rev-parse HEAD)" = "$GANESHA_COMMIT" ] || die "V$UPSTREAM is not $GANESHA_COMMIT"
# A leading -, + or U marks a submodule not checked out at the recorded commit. (No pipe:
# grep -q exiting early must not let a SIGPIPE'd status decide.)
subs=$(git -C nfs-ganesha-git submodule status --recursive)
echo "$subs" >&2
[ -n "$subs" ] || die "V$UPSTREAM has no submodules"
! grep -q '^[^ ]' <<<"$subs" || die "a submodule is not at the commit V$UPSTREAM records"
# The orig tarball is the tree at that commit, without .git, in a fixed order and time.
tar -C nfs-ganesha-git --exclude=.git --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$(git -C nfs-ganesha-git log -1 --format=%ct)" \
	--transform "s,^\.,nfs-ganesha-$UPSTREAM," -cf - . | xz -T1 -6 > "nfs-ganesha_$UPSTREAM.orig.tar.xz"
rm -rf nfs-ganesha-git
tar -xf "nfs-ganesha_$UPSTREAM.orig.tar.xz"
cp -r "$REPO/ganesha/debian" "nfs-ganesha-$UPSTREAM/"
cd "nfs-ganesha-$UPSTREAM"
# Our patches, applied with quilt, which records them in .pc as 3.0 (quilt) expects.
export QUILT_PATCHES=debian/patches
mkdir -p debian/patches
for p in "$REPO"/ganesha/patches/*.patch; do
	cp "$p" debian/patches/
	basename "$p" >> debian/patches/series
	quilt push -q || die "$(basename "$p") does not apply"
done
[ "$(dpkg-parsechangelog -S Version)" = "$DEB_VER" ] || die "debian/changelog is not $DEB_VER"
apt-get build-dep -y -q .
for pkg in "${ceph[@]}"; do
	[ "$(dpkg-query -W -f='${Version}' "$pkg")" = "$CEPH_VER" ] || die "$pkg is not $CEPH_VER"
done
[ "$(dpkg-query -W -f='${Version}' libicu74)" = "$ICU_VER" ] || die "libicu74 is not $ICU_VER"

# Capped like the QEMU build: CI runners report 80 CPUs with far less memory.
JOBS=${JOBS:-$(( $(nproc) < 16 ? $(nproc) : 16 ))}
DEB_BUILD_OPTIONS="nocheck noddebs parallel=$JOBS" dpkg-buildpackage --build=source,any -uc -us
cd "$WORK"

# Check the built packages before anything is published.
debs=()
for pkg in "${PKGS[@]}"; do debs+=("./${pkg}_${DEB_VER}_$ARCH.deb"); done
apt-get install -y -q --no-install-recommends "${debs[@]}"
for pkg in "${PKGS[@]}"; do
	[ "$(dpkg-query -W -f='${Version}' "$pkg")" = "$DEB_VER" ] || die "$pkg $DEB_VER is not installed"
done
"$REPO/ganesha/check.sh" | tee check.txt
"$REPO/ganesha/addrs-check.sh" | tee -a check.txt

rm -f "$OUT"/*.deb
cp "${debs[@]}" "libicu74_${ICU_VER}_$ARCH.deb" "$OUT/"
cp "nfs-ganesha_$DEB_VER.dsc" "nfs-ganesha_$DEB_VER.debian.tar.xz" "nfs-ganesha_$UPSTREAM.orig.tar.xz" "$OUT/"
cp check.txt "$OUT/ganesha-check.txt"
cd "$OUT"
sha256sum ./*.deb ./*.dsc ./*.tar.xz ganesha-check.txt | sed 's| \./| |' > SHA256SUMS
cat SHA256SUMS
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID" "$OUT"; fi
