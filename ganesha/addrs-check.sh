#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check, without a Ceph cluster, that a rados_cluster ganesha.nfsd publishes its RADOS client
# addresses (ganesha/patches/0002) before it touches the grace database, and exits when it
# can't. ganesha.nfsd runs against a stub librados.so.2 (LD_LIBRARY_PATH, ahead of the
# modules' RUNPATH): every librados function the RADOS modules use returns 0, except that
# rados_create/rados_getaddrs give each client the address [v2:127.0.0.1:0/<userid>],
# rados_write_full records what it's given (or fails with -EIO when STUB_WRITE_FAIL is set),
# and rados_read_op_operate fails with -EIO, so the grace-database membership check fails
# and Ganesha stops there.
# Runs as root after ganesha/build.sh installed the packages; needs cc and nm (binutils).
set -euo pipefail
die() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mods=(/usr/lib/ganesha/libganesha_rados_recov.so /usr/lib/ganesha/libganesha_rados_urls.so)
special=" rados_create rados_getaddrs rados_buffer_free rados_ioctx_create rados_ioctx_set_namespace rados_write_full rados_read_op_operate "
{
	cat <<'C'
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
struct client { char id[64]; };
struct ioctx { char pool[64], ns[64]; };
int rados_create(void **c, const char *id)
{
	struct client *cl = calloc(1, sizeof(*cl));
	snprintf(cl->id, sizeof(cl->id), "%s", id ? id : "admin");
	*c = cl;
	return 0;
}
int rados_getaddrs(void *c, char **addrs)
{
	return asprintf(addrs, "[v2:127.0.0.1:0/%s]", ((struct client *)c)->id) < 0 ? -ENOMEM : 0;
}
void rados_buffer_free(char *b) { free(b); }
int rados_ioctx_create(void *c, const char *pool, void **io)
{
	struct ioctx *x = calloc(1, sizeof(*x));
	snprintf(x->pool, sizeof(x->pool), "%s", pool);
	*io = x;
	return 0;
}
void rados_ioctx_set_namespace(void *io, const char *ns)
{
	snprintf(((struct ioctx *)io)->ns, sizeof(((struct ioctx *)io)->ns), "%s", ns ? ns : "");
}
int rados_write_full(void *io, const char *oid, const char *buf, size_t len)
{
	struct ioctx *x = io;
	FILE *f;

	if (getenv("STUB_WRITE_FAIL"))
		return -EIO;
	f = fopen(getenv("STUB_OUT"), "w");
	if (!f)
		return -EIO;
	fprintf(f, "pool=%s ns=%s oid=%s\n", x->pool, x->ns, oid);
	fwrite(buf, 1, len, f);
	fclose(f);
	return 0;
}
int rados_read_op_operate(void *op, void *io, const char *oid, int flags) { return -EIO; }
C
	nm -D --undefined-only "${mods[@]}" | awk '{ sub(/@.*/, "", $2); print $2 }' | grep '^rados_' | sort -u \
		| while read -r s; do
			[[ "$special" == *" $s "* ]] || echo "long $s(void) { return 0; }"
		done
} > "$T/stub.c"
cc -shared -fPIC -w -o "$T/librados.so.2" -Wl,-soname,librados.so.2 "$T/stub.c"

cat > "$T/ganesha.conf" <<X
NFS_CORE_PARAM { Protocols = 4; Enable_UDP = false; Bind_Addr = 127.0.0.1; NFS_Port = ${PORT:-32049}; Dbus_Name_Prefix = "check"; Allow_Set_Io_Flusher_Fail = true; }
NFSv4 { RecoveryBackend = rados_cluster; }
RADOS_KV { ceph_conf = "$T/ceph.conf"; userid = "check-recov"; pool = "files-check"; namespace = "ns-check"; nodeid = "rank-1"; }
RADOS_URLS { ceph_conf = "$T/ceph.conf"; userid = "check-urls"; watch_url = "rados://files-check/ns-check/conf-rank-1"; }
X
touch "$T/ceph.conf"
run() { # run <name> [env...]: ganesha.nfsd on the stub until it stops; status in $T/<name>.rc
	local name=$1 rc=0
	shift
	env "$@" LD_LIBRARY_PATH="$T" STUB_OUT="$T/$name.obj" timeout 60 /usr/bin/ganesha.nfsd -F -L STDOUT -N NIV_EVENT \
		-f "$T/ganesha.conf" -p "$T/$name.pid" > "$T/$name.log" 2>&1 || rc=$?
	echo "$rc" > "$T/$name.rc"
	[ "$rc" != 0 ] && [ "$rc" != 124 ] || { cat "$T/$name.log" >&2; die "$name: exit status $rc, not a startup failure"; }
}
line() { grep -n "$2" "$T/$1.log" | head -1 | cut -d: -f1; }

run write
want='pool=files-check ns=ns-check oid=addrs.rank-1
recov [v2:127.0.0.1:0/check-recov]
urls [v2:127.0.0.1:0/check-urls]'
[ "$(cat "$T/write.obj" 2>/dev/null)" = "$want" ] \
	|| { cat "$T/write.log" >&2; printf 'got:\n%s\n' "$(cat "$T/write.obj" 2>/dev/null)" >&2; die "addrs.rank-1 is not as expected"; }
w=$(line write 'Wrote addrs.rank-1: recov')
m=$(line write 'Cluster membership check failed')
[ -n "$w" ] && [ -n "$m" ] && [ "$w" -lt "$m" ] || { cat "$T/write.log" >&2; die "write: addrs.rank-1 not written before the grace database"; }
echo "rados_cluster: addrs.rank-1 written (grace pool and namespace, recov and urls lines) before the grace database"

run fail STUB_WRITE_FAIL=1
grep -q 'Failed to write addrs.rank-1: -5' "$T/fail.log" || { cat "$T/fail.log" >&2; die "fail: no 'Failed to write addrs.rank-1'"; }
! grep -q 'Cluster membership' "$T/fail.log" || { cat "$T/fail.log" >&2; die "fail: went on to the grace database"; }
echo "rados_cluster: addrs.rank-1 write fails -> ganesha.nfsd exits ($(cat "$T/fail.rc")) before the grace database"
echo OK
