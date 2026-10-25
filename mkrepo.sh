#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Add a build's .deb to the apt repository in ROOT_DIR/apt (pool/ holding the
# already-published packages), put its files in ROOT_DIR/files/VERSION, and
# sign the repository. ROOT_DIR mirrors https://get.ezghcloud.com/kernel-livepatches/.
# Runs as root in ubuntu:26.04 with the armored private key in $APT_SIGNING_KEY.
#
# Usage: mkrepo.sh OUT_DIR ROOT_DIR VERSION
set -euo pipefail
OUT=$1 ROOT=$2 VERSION=$3
P=$ROOT/apt
REPO=$(cd "$(dirname "$0")" && pwd)
die() { echo "error: $*" >&2; exit 1; }
[ -n "${APT_SIGNING_KEY:-}" ] || die "APT_SIGNING_KEY is not set"

export DEBIAN_FRONTEND=noninteractive
"$REPO/snapshot-apt.sh" >/dev/null
apt-get install -y -q --no-install-recommends apt-utils gnupg >/dev/null

(cd "$OUT" && sha256sum -c SHA256SUMS)
deb=$(ls "$OUT"/*.deb)
pkg=$(dpkg-deb -f "$deb" Package)
pool=$P/pool/main/e/$pkg
dest=$pool/$(basename "$deb")
[ ! -e "$dest" ] || cmp -s "$deb" "$dest" || die "$dest is already published with different contents"
rel=$ROOT/files/$VERSION
[ ! -e "$rel" ] || cmp -s "$OUT/SHA256SUMS" "$rel/SHA256SUMS" || die "$rel is already published with different contents"
mkdir -p "$pool" "$rel"
cp "$deb" "$pool/"
cp "$OUT"/{SHA256SUMS,BUILDINFO,static-check.txt,*.ko,*.patch,config-*} "$rel/"
cp "$deb" "$rel/"
cp "$REPO/keys/apt.asc" "$ROOT/apt.asc"

cd "$P"
d=dists/resolute
mkdir -p "$d/main/binary-amd64"
apt-ftparchive packages pool > "$d/main/binary-amd64/Packages"
gzip -9nkf "$d/main/binary-amd64/Packages"
rm -f "$d"/{Release,InRelease,Release.gpg}
apt-ftparchive \
	-o APT::FTPArchive::Release::Origin="EZGH Cloud" \
	-o APT::FTPArchive::Release::Label="EZGH kernel livepatches" \
	-o APT::FTPArchive::Release::Suite=resolute \
	-o APT::FTPArchive::Release::Codename=resolute \
	-o APT::FTPArchive::Release::Architectures=amd64 \
	-o APT::FTPArchive::Release::Components=main \
	release "$d" > /tmp/Release
mv /tmp/Release "$d/Release"

export GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
printenv APT_SIGNING_KEY | gpg --batch --quiet --import
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
# Sign only with the key that keys/apt.asc publishes.
[ "$(gpg --batch --with-colons --show-keys "$REPO/keys/apt.asc" | awk -F: '$1 == "fpr" { print $10; exit }')" = "$fpr" ] \
	|| die "APT_SIGNING_KEY does not match keys/apt.asc"
gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 --clearsign -o "$d/InRelease" "$d/Release"
gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 -abs -o "$d/Release.gpg" "$d/Release"
gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 -abs -o "$rel/SHA256SUMS.asc" "$rel/SHA256SUMS"
gpg --dearmor < "$REPO/keys/apt.asc" > "$GNUPGHOME/apt.gpg"
gpgv --keyring "$GNUPGHOME/apt.gpg" "$d/InRelease"
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID" "$ROOT"; fi
echo "signed $d with $fpr"
