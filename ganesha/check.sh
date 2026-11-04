#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check the installed nfs-ganesha, nfs-ganesha-ceph and nfs-ganesha-rados-grace (no Ceph
# cluster, no clients, nothing listens):
#   - every binary and library they ship resolves all its libraries; libcephfs and librados
#     come from Ceph's packages at 20.2.4 or later, ntirpc from /usr/lib/ganesha, and ntirpc's
#     TLS from OpenSSL (libssl), not GnuTLS;
#   - TLS and QoS are compiled in. Ganesha reads TLS_CONFIG and QOS_DEFAULT_CONFIG only when
#     they are, and ignores both blocks otherwise, so an out-of-range value in either must
#     stop it. A valid pair (TLS on with kTLS and a throwaway certificate, QoS on) must get
#     past both to the NFSv4 block, which it reads after them; with a missing certificate,
#     OpenSSL must fail to initialize TLS.
# Usage: ganesha/check.sh   (as root; exit status 0 when all hold)
set -euo pipefail
die() { echo "FAIL: $*" >&2; exit 1; }
CEPH_MIN=20.2.4
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

owner() { # owner <path>: the package that ships it
	dpkg -S "$(readlink -f "$1")" | cut -d: -f1
}
lib() { # lib <file> <soname pattern>: the path <file> loads it from
	ldd "$1" | awk -v s="$2" '$1 ~ s { print $3; exit }'
}
mapfile -t files < <(dpkg -L nfs-ganesha nfs-ganesha-ceph nfs-ganesha-rados-grace)
elfs=()
for f in "${files[@]}"; do
	[ -f "$f" ] && [ ! -L "$f" ] && [[ "$f" == /usr/bin/* || "$f" == *.so* ]] && elfs+=("$f")
done
for f in "${elfs[@]}"; do
	! ldd "$f" | grep 'not found' || die "$f has unresolved libraries"
done
echo "${#elfs[@]} binaries and libraries resolve every library"

shipped() { # shipped <pattern>: the one file the packages ship matching it
	printf '%s\n' "${files[@]}" | grep -x "$1" || die "no $1"
}
nfsd=$(shipped /usr/bin/ganesha.nfsd)
fsal=$(shipped '/usr/lib/.*/ganesha/libfsalceph\.so')
recov=$(shipped /usr/lib/ganesha/libganesha_rados_recov.so)
urls=$(shipped /usr/lib/ganesha/libganesha_rados_urls.so)
grace=$(shipped /usr/bin/ganesha-rados-grace)

ceph() { # ceph <file> <soname> <package>: <file> loads <soname> from <package> >= CEPH_MIN
	local p v
	p=$(lib "$1" "^$2\$"); [ -n "$p" ] || die "$1 does not link $2"
	[ "$(owner "$p")" = "$3" ] || die "$1 loads $2 from $p, not from $3"
	v=$(dpkg-query -W -f='${Version}' "$3")
	dpkg --compare-versions "$v" ge "$CEPH_MIN" || die "$3 is $v, older than $CEPH_MIN"
	echo "$(basename "$1"): $(basename "$p") from $3 $v"
}
ceph "$fsal" 'libcephfs\.so\.2' libcephfs2
ceph "$recov" 'librados\.so\.2' librados2
ceph "$urls" 'librados\.so\.2' librados2
ceph "$grace" 'librados\.so\.2' librados2

ntirpc=$(lib "$nfsd" '^libntirpc\.so')
[ "$(owner "$ntirpc")" = nfs-ganesha ] || die "ganesha.nfsd loads ntirpc from $ntirpc, not nfs-ganesha's"
ldd "$ntirpc" | grep -q '^\s*libssl\.so\.3 ' || die "ntirpc does not link OpenSSL"
! ldd "$ntirpc" | grep -q libgnutls || die "ntirpc links GnuTLS"
echo "ganesha.nfsd: ntirpc $ntirpc, TLS from $(lib "$ntirpc" '^libssl\.so') ($(owner "$(lib "$ntirpc" '^libssl\.so')"))"

# A throwaway self-signed certificate (its own CA) for the TLS block; OpenSSL must load it.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=check \
	-keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null

run() { # run <name> <config blocks>: log Ganesha reading the config, until it stops
	cat > "$T/$1.conf" <<-X
	NFS_CORE_PARAM { Protocols = 4; Enable_UDP = false; }
	$2
	X
	timeout 60 "$nfsd" -F -L STDOUT -N NIV_EVENT -f "$T/$1.conf" -p "$T/$1.pid" > "$T/$1.log" 2>&1 || true
}
expect() { # expect <name> <message>: the run logged <message>
	grep -q "$2" "$T/$1.log" || { cat "$T/$1.log" >&2; die "$1: no '$2'"; }
}
reject() { # reject <name> <message>: the run did not log <message>
	! grep -q "$2" "$T/$1.log" || { cat "$T/$1.log" >&2; die "$1: '$2'"; }
}
tls="TLS_CONFIG { Enable_TLS = true; Enable_KTLS = true; TLS_Cert_File = \"$T/cert.pem\"; TLS_Key_File = \"$T/key.pem\"; TLS_CA_File = \"$T/cert.pem\"; }"
qos='QOS_DEFAULT_CONFIG { enable_qos = true; enable_bw_control = true; combined_rw_bw_control = true; enable_iops_control = true; combined_rw_iops_control = true; qos_type = Per_Export; }'
stop='NFSv4 { Lease_Lifetime = 0; }' # out of range: the read stops at NFSv4, after TLS and QoS

run tls-bad 'TLS_CONFIG { TLS_Session_Timeout = 0; }'
expect tls-bad 'Error while parsing TLS configuration'
echo "TLS_CONFIG with an out-of-range value: refused"
run qos-bad 'QOS_DEFAULT_CONFIG { client_read_tokens_renew_time = 1; }'
expect qos-bad 'Error while parsing qos configuration'
echo "QOS_DEFAULT_CONFIG with an out-of-range value: refused"
run valid "$tls
$qos
$stop"
expect valid 'Error while parsing NFSv4 specific configuration'
reject valid 'Error while parsing \(TLS\|qos\) configuration'
reject valid 'Failed to initialize TLS'
echo "valid TLS_CONFIG (kTLS, a certificate) and QOS_DEFAULT_CONFIG: accepted"
run nocert "TLS_CONFIG { Enable_TLS = true; TLS_Cert_File = \"$T/missing.pem\"; TLS_Key_File = \"$T/key.pem\"; TLS_CA_File = \"$T/cert.pem\"; }
$stop"
expect nocert 'Failed to initialize TLS'
echo "TLS with a missing certificate: OpenSSL fails to initialize"
echo OK
