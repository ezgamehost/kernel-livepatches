#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Install what PM's os-packages release puts on an EZGH Files gateway host from the published
# repositories, then run ganesha/check.sh on it: the Ubuntu snapshot's resolute, this
# repository's apt repo (nfs-ganesha* and noble's libicu74), download.ceph.com's 20.2.4 noble
# repo and the snapshot's noble universe (librados2's libthrift, which the cell release
# already carries), with the exact versions ganesha/build.sh names. No noble main.
# Runs as root in ubuntu:26.04 (amd64) with the host CA bundle at /hostca.pem.
# Env: URL (default the published repo), KEY (its signing key, default keys/apt.asc).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
URL=${URL:-https://get.ezghcloud.com/kernel-livepatches/apt}
KEY=${KEY:-$REPO/keys/apt.asc}
eval "$(sed -n 's/^\(DEB_VER\|CEPH_VER\|ICU_VER\)=\([^ ]*\).*/\1=\2/p' "$REPO/ganesha/build.sh")"
: "${DEB_VER:?}" "${CEPH_VER:?}" "${ICU_VER:?}"

export DEBIAN_FRONTEND=noninteractive
"$REPO/snapshot-apt.sh" >/dev/null
uri=$(awk '/^URIs:/ { print $2; exit }' /etc/apt/sources.list.d/snapshot.sources)
install -D -m 0644 "$KEY" /etc/apt/keyrings/ezgh-kernel-livepatches.asc
install -D -m 0644 "$REPO/ganesha/ceph-release.asc" /etc/apt/keyrings/ceph-release.asc
cat > /etc/apt/sources.list.d/gateway.sources <<X
Types: deb
URIs: $URL
Suites: resolute
Components: main
Signed-By: /etc/apt/keyrings/ezgh-kernel-livepatches.asc

Types: deb
URIs: https://download.ceph.com/debian-${CEPH_VER%-*}
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/ceph-release.asc

Types: deb
URIs: $uri
Suites: noble
Components: universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
X
apt-get update -q
# Recommends on, as PM installs.
apt-get install -y -q openssl "libicu74=$ICU_VER" "libcephfs2=$CEPH_VER" "librados2=$CEPH_VER" \
	"nfs-ganesha=$DEB_VER" "nfs-ganesha-ceph=$DEB_VER" "nfs-ganesha-rados-grace=$DEB_VER"
"$REPO/ganesha/check.sh"
echo "gateway install of $DEB_VER (Ceph $CEPH_VER, libicu74 $ICU_VER): OK"
