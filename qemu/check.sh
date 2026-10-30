#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check the throttle filter's discard accounting with the qemu-io on PATH, against a
# null-co disk (no guest, no KVM, no data):
#   - a 4 KiB write after a 100 MiB discard through a 10 MB/s group is not delayed
#     (stock QEMU makes it wait about 10 s, the discard's length at the bps limit);
#   - discards still count as requests: 30 of them through a 10 IOPS group take
#     at least 1.5 s.
# Usage: qemu/check.sh   (exit status 0 when both hold)
set -euo pipefail
die() { echo "FAIL: $*" >&2; exit 1; }

io() { # io <throttle-group limits> <qemu-io -c commands...>
	local limits=$1; shift
	qemu-io --object "throttle-group,id=tg0,$limits" \
		--image-opts driver=throttle,throttle-group=tg0,discard=unmap,file.driver=null-co,file.size=10737418240 \
		"$@" >/dev/null
}
seconds() { # seconds <command...>: wall time of the command, in seconds
	local t0 t1
	t0=$(date +%s.%N); "$@"; t1=$(date +%s.%N)
	echo "$t1 - $t0" | bc
}

bps=$(seconds io x-bps-total=10000000 -c "discard 0 100M" -c "write 0 4k")
echo "write after a 100 MiB discard at 10 MB/s: ${bps}s"
[ "$(echo "$bps < 1" | bc)" = 1 ] || die "the discard was charged by its length (${bps}s)"

cmds=()
for i in $(seq 0 29); do cmds+=(-c "discard $((i * 1048576)) 1M"); done
ops=$(seconds io x-iops-total=10 "${cmds[@]}")
echo "30 discards at 10 IOPS: ${ops}s"
[ "$(echo "$ops >= 1.5" | bc)" = 1 ] || die "discards no longer count against the iops limit (${ops}s)"
echo "OK"
