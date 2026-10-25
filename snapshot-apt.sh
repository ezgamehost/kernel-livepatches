#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Point apt at the pinned Ubuntu snapshot only, then apt-get update.
# The ubuntu image has no CA bundle, so TLS uses the host's, mounted at
# /hostca.pem; apt still verifies the Ubuntu archive signature.
set -euo pipefail
SNAPSHOT=20261018T000000Z
if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
	[ -s /hostca.pem ] || { echo "error: mount the host CA bundle at /hostca.pem" >&2; exit 1; }
	echo 'Acquire::https::CAInfo "/hostca.pem";' > /etc/apt/apt.conf.d/99hostca
fi
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<X
Types: deb deb-src
URIs: https://snapshot.ubuntu.com/ubuntu/$SNAPSHOT
Suites: resolute resolute-updates resolute-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
X
apt-get update -q
