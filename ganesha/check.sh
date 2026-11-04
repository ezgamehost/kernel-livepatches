#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check the installed nfs-ganesha, nfs-ganesha-ceph and nfs-ganesha-rados-grace (no Ceph
# cluster, no clients; one throwaway server on 127.0.0.1:$PORT):
#   - every binary and library they ship resolves all its libraries; libcephfs and librados
#     come from Ceph's packages, both at the same version (libcephfs uses libceph-common's
#     private symbols from librados2), 20.2.4 or later, and resolve every symbol (ldd -r);
#     ntirpc comes from nfs-ganesha (in /usr/lib/<multiarch>), its TLS from OpenSSL
#     (libssl), not GnuTLS;
#   - TLS and QoS are compiled in. Ganesha reads TLS_CONFIG and QOS_DEFAULT_CONFIG only when
#     they are, and ignores both blocks otherwise, so an out-of-range value in either must
#     stop it. A valid pair (TLS on with kTLS and a throwaway certificate, QoS on) must get
#     past both to the NFSv4 block, which it reads after them, with the RADOS URLs library
#     loaded; with a missing certificate, ganesha.nfsd must exit non-zero;
#   - the rados_cluster recovery backend loads (and then can't reach a cluster);
#   - a running server serves its certificate to a TLS handshake, and after the certificate
#     and key files are replaced and it gets SIGHUP, serves the new one to new handshakes;
#     a broken certificate on SIGHUP keeps the current one.
# Usage: ganesha/check.sh   (as root; exit status 0 when all hold). Env: PORT (default 32049).
set -euo pipefail
die() { echo "FAIL: $*" >&2; exit 1; }
CEPH_MIN=20.2.4
PORT=${PORT:-32049}
T=$(mktemp -d)
srv=
trap '[ -z "$srv" ] || kill -9 "$srv" 2>/dev/null; rm -rf "$T"' EXIT

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

ceph_ver=$(dpkg-query -W -f='${Version}' librados2)
[ "$(dpkg-query -W -f='${Version}' libcephfs2)" = "$ceph_ver" ] \
	|| die "libcephfs2 $(dpkg-query -W -f='${Version}' libcephfs2) is not librados2's $ceph_ver"
dpkg --compare-versions "$ceph_ver" ge "$CEPH_MIN" || die "Ceph's libraries are $ceph_ver, older than $CEPH_MIN"
symbols() { # symbols <file>: every symbol <file> needs resolves
	local u
	u=$(ldd -r "$1" 2>&1 | grep 'undefined symbol' || true)
	[ -z "$u" ] || { echo "$u" >&2; die "$1 has undefined symbols"; }
}
ceph() { # ceph <file> <soname> <package>: <file> loads <soname> from <package>, symbols resolved
	local p
	p=$(lib "$1" "^$2\$"); [ -n "$p" ] || die "$1 does not link $2"
	[ "$(owner "$p")" = "$3" ] || die "$1 loads $2 from $p, not from $3"
	symbols "$1"
	symbols "$p"
	echo "$(basename "$1"): $(basename "$p") from $3 $ceph_ver, every symbol resolved"
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

cert() { # cert <name>: a throwaway self-signed certificate (its own CA) and key, $T/<name>.{crt,key}
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=check-$1" \
		-keyout "$T/$1.key" -out "$T/$1.crt" 2>/dev/null
}
cert a
cert b
cp "$T/a.crt" "$T/cert.pem"
cp "$T/a.key" "$T/key.pem"

core="NFS_CORE_PARAM { Protocols = 4; Enable_UDP = false; Bind_Addr = 127.0.0.1; NFS_Port = $PORT; Dbus_Name_Prefix = \"check\"; Allow_Set_Io_Flusher_Fail = true; }"
run() { # run <name> <config blocks>: log Ganesha reading the config, until it stops; status in $T/<name>.rc
	cat > "$T/$1.conf" <<-X
	$core
	$2
	X
	local rc=0
	timeout 60 "$nfsd" -F -L STDOUT -N NIV_EVENT -f "$T/$1.conf" -p "$T/$1.pid" > "$T/$1.log" 2>&1 || rc=$?
	echo "$rc" > "$T/$1.rc"
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
# Ganesha loads its RADOS URLs and recovery libraries by bare name (dlopen, through RUNPATH).
reject valid 'Missing RADOS URLs backend library'
echo "valid TLS_CONFIG (kTLS, a certificate) and QOS_DEFAULT_CONFIG: accepted; RADOS URLs loaded"
run recov "NFSv4 { RecoveryBackend = rados_cluster; }
RADOS_KV { ceph_conf = \"$T/missing.conf\"; userid = check; nodeid = check; }"
expect recov 'Failed to read conf'
reject recov 'Failed to load Backend'
echo "rados_cluster recovery backend: loaded (no cluster to reach)"
run nocert "TLS_CONFIG { Enable_TLS = true; TLS_Cert_File = \"$T/missing.pem\"; TLS_Key_File = \"$T/key.pem\"; TLS_CA_File = \"$T/cert.pem\"; }"
expect nocert 'TLS_CONFIG enables TLS but TLS failed to initialize'
rc=$(cat "$T/nocert.rc")
[ "$rc" != 0 ] && [ "$rc" != 124 ] || { cat "$T/nocert.log" >&2; die "nocert: exit status $rc, not a startup failure"; }
echo "TLS with a missing certificate: ganesha.nfsd exits ($rc) at startup"

# No CA: only client certificates need one, and none is required, so Ganesha must start with
# just the certificate and key (it reads the CA from /etc/ganesha/tls/ca.crt when the block
# names none, which nothing installs).
noca_file=; [ ! -e /etc/ganesha/tls/ca.crt ] || noca_file="TLS_CA_File = \"$T/missing-ca.pem\";"
run noca "TLS_CONFIG { Enable_TLS = true; TLS_Cert_File = \"$T/cert.pem\"; TLS_Key_File = \"$T/key.pem\"; $noca_file }
$stop"
expect noca 'Error while parsing NFSv4 specific configuration'
expect noca 'client certificates are not requested'
reject noca 'TLS failed to initialize'
echo "TLS with no CA file: starts with the certificate and key, requests no client certificate"

# A server on 127.0.0.1:$PORT with certificate a (and a as the CA). Clients present no
# certificate, as Linux's tlshd doesn't by default.
cat > "$T/serve.conf" <<X
$core
NFSv4 { RecoveryBackend = fs_ng; RecoveryRoot = "$T/recovery"; }
$tls
X
cp "$T/serve.conf" "$T/serve.conf.tls"
"$nfsd" -F -L "$T/serve.log" -N NIV_EVENT -f "$T/serve.conf" -p "$T/serve.pid" > "$T/serve.out" 2>&1 &
srv=$!
count() { grep -c "$1" "$T/serve.log" 2>/dev/null || :; }
wait_log() { # wait_log <count> <message>: the server's log holds <message> <count> times (60 s)
	local i n
	for i in $(seq 60); do
		n=$(count "$2")
		[ "${n:-0}" -ge "$1" ] && return 0
		kill -0 "$srv" 2>/dev/null || { cat "$T/serve.log" >&2; die "the server exited"; }
		sleep 1
	done
	cat "$T/serve.log" >&2; die "serve: no '$2' $1 times after 60 s"
}
served() { # served: the SHA-256 fingerprint of the certificate a new TLS handshake gets
	timeout 20 openssl s_client -connect "127.0.0.1:$PORT" </dev/null 2>/dev/null \
		| openssl x509 -noout -fingerprint -sha256
}
fp() { openssl x509 -noout -fingerprint -sha256 -in "$1"; }
# An NFS NULL call (xid 12345678, AUTH_NONE) as one RPC record, and its reply (accepted, success).
rpc_null() { printf '\x80\x00\x00\x28\x12\x34\x56\x78\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01\x86\xa3\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'; }
replied() { od -An -tx1 -v "$1" | tr -d ' \n' | grep -q 80000018123456780000000100000000000000000000000000000000; }
null_rpc() { # null_rpc <name>: a new TLS session, no client certificate, gets a NULL reply
	{ rpc_null; sleep 2; } | timeout 20 openssl s_client -connect "127.0.0.1:$PORT" > "$T/$1.out" 2>&1 || true
	replied "$T/$1.out" || { cat "$T/$1.out" >&2; die "$1: no NFS NULL reply over TLS"; }
}
hup() { # hup <cert>: install certificate <cert> (a or b) and its key, SIGHUP, wait for the reload
	local n
	n=$(count 'TLS_CONFIG reloaded')
	cp "$T/$1.key" "$T/key.pem"
	cp "$T/$1.crt" "$T/cert.pem"
	kill -HUP "$srv"
	wait_log $((n + 1)) 'TLS_CONFIG reloaded'
}
wait_log 1 'NFS SERVER INITIALIZED'
[ "$(served)" = "$(fp "$T/a.crt")" ] || die "the server does not serve certificate a"
null_rpc fresh-a
echo "TLS on 127.0.0.1:$PORT with a CA configured: a client without a certificate gets certificate a and an NFS NULL reply"

# A session opened before the reload keeps working on its old context and closes cleanly.
mkfifo "$T/held.in"
timeout 120 openssl s_client -connect "127.0.0.1:$PORT" < "$T/held.in" > "$T/held.out" 2>&1 &
held=$!
exec 3> "$T/held.in"
for i in $(seq 20); do grep -q 'BEGIN CERTIFICATE' "$T/held.out" && break; sleep 1; done
grep -q 'BEGIN CERTIFICATE' "$T/held.out" || { cat "$T/held.out" >&2; die "held: no handshake"; }
hup b
[ "$(served)" = "$(fp "$T/b.crt")" ] || die "after SIGHUP, a new handshake does not get certificate b"
echo "certificate b in place, SIGHUP: a new handshake gets certificate b"
rpc_null >&3
for i in $(seq 20); do replied "$T/held.out" && break; sleep 1; done
replied "$T/held.out" || { cat "$T/held.out" >&2; die "held: no NFS NULL reply on the session opened before the reload"; }
exec 3>&-
wait "$held" || die "held: s_client exited $? closing the session"
[ "$(fp "$T/held.out")" = "$(fp "$T/a.crt")" ] || die "held: the session was not on certificate a"
echo "a session opened on certificate a before the reload: NFS NULL reply after it, closed cleanly"

# Unchanged files don't reload; a broken certificate is refused once and the current one stays.
kill -HUP "$srv"
echo broken > "$T/cert.pem"
kill -HUP "$srv"
wait_log 1 'TLS_CONFIG not reloaded'
kill -HUP "$srv"
hup a
[ "$(count 'TLS_CONFIG reloaded')" = 2 ] || die "a SIGHUP with unchanged files reloaded"
[ "$(count 'TLS_CONFIG not reloaded')" = 1 ] || die "unchanged broken files were retried"
[ "$(served)" = "$(fp "$T/a.crt")" ] || die "after the broken certificate and a again, a new handshake does not get a"
echo "SIGHUP with unchanged files: no reload; broken certificate: refused once, the current one kept"

# Turning TLS off takes a restart: refused, logged once.
sed 's/Enable_TLS = true/Enable_TLS = false/' "$T/serve.conf.tls" > "$T/serve.conf"
kill -HUP "$srv"
wait_log 1 'which takes a restart'
kill -HUP "$srv"
cp "$T/serve.conf.tls" "$T/serve.conf"
hup b
[ "$(count 'which takes a restart')" = 1 ] || die "the TLS on/off refusal was logged more than once"
echo "TLS turned off by SIGHUP: refused (logged once), TLS stays on"

for i in $(seq 20); do hup "$( [ $((i % 2)) = 1 ] && echo a || echo b)"; done
[ "$(served)" = "$(fp "$T/b.crt")" ] || die "after 20 reloads, a new handshake does not get certificate b"
null_rpc fresh-b
echo "20 more reloads: still serving, new handshakes get the last certificate"
kill "$srv"
wait "$srv" || true
srv=
grep -q 'NFS EXIT: regular exit' "$T/serve.log" || { tail -50 "$T/serve.log" >&2; die "the server did not exit cleanly"; }
echo OK
