#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Point apt at the pinned Ubuntu snapshot only, then apt-get update.
# The ubuntu image has no CA bundle, so TLS uses the host's, mounted at
# /hostca.pem; apt still verifies the Ubuntu archive signature.
# With SNAPSHOT_CACHE_TOKEN set (EZGH CI), the snapshot comes through EZGH's cache of it,
# the same files under the same paths, falling back to snapshot.ubuntu.com when the
# cache doesn't answer.
set -euo pipefail
SNAPSHOT=20261018T000000Z
CACHE=snapshot-cache.ezghcloud.com
if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
	[ -s /hostca.pem ] || { echo "error: mount the host CA bundle at /hostca.pem" >&2; exit 1; }
	echo 'Acquire::https::CAInfo "/hostca.pem";' > /etc/apt/apt.conf.d/99hostca
fi
# snapshot.ubuntu.com answers 5xx at times: retry each download with backoff, and don't
# wait on a stalled connection for apt's default 120 s.
cat > /etc/apt/apt.conf.d/80retries <<'X'
Acquire::Retries "10";
Acquire::Retries::Delay "true";
Acquire::Retries::Delay::Maximum "60";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
X
uri=https://snapshot.ubuntu.com/ubuntu/$SNAPSHOT
if [ -n "${SNAPSHOT_CACHE_TOKEN:-}" ]; then
	install -m 0600 /dev/null /etc/apt/auth.conf.d/snapshot-cache.conf
	printf 'machine %s\nlogin ci\npassword %s\n' "$CACHE" "$SNAPSHOT_CACHE_TOKEN" > /etc/apt/auth.conf.d/snapshot-cache.conf
	if /usr/lib/apt/apt-helper -o Acquire::Retries=1 download-file \
		"https://$CACHE/ubuntu/$SNAPSHOT/dists/resolute/InRelease" /tmp/snapshot-cache-probe >/dev/null 2>&1; then
		uri=https://$CACHE/ubuntu/$SNAPSHOT
	else
		echo "warning: $CACHE doesn't answer, using snapshot.ubuntu.com" >&2
	fi
	rm -f /tmp/snapshot-cache-probe
fi
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<X
Types: deb deb-src
URIs: $uri
Suites: resolute resolute-updates resolute-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
X
apt-get update -q
