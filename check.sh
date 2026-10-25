#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Static compatibility check of a klp-build module against the stock Ubuntu
# kernel. Exits non-zero on any mismatch.
#
# Usage: check.sh MODULE.ko STOCK_ROOT KERNEL_TREE
#   STOCK_ROOT: linux-modules-$KVER and linux-headers-$KVER extracted (dpkg-deb -x)
#   KERNEL_TREE: the tree klp-build ran in (Module.symvers, klp-tmp/)
set -euo pipefail

KO=$1 STOCK=$2 TREE=$3
KVER=7.0.0-38-generic
MAP=$STOCK/boot/System.map-$KVER
SYMVERS=$STOCK/usr/src/linux-headers-$KVER/Module.symvers
MODDIR=$STOCK/usr/lib/modules/$KVER
ORIG_VMLINUX=$TREE/klp-tmp/orig/vmlinux.o
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# Same-name symbol count: stock System.map vs the unpatched build's vmlinux.o.
count_map() { awk -v n="$1" '$3 == n { c++ } END { print c + 0 }' "$MAP"; }
nm "$ORIG_VMLINUX" > /tmp/orig.nm
count_orig() { awk -v n="$1" '$3 == n { c++ } END { print c + 0 }' /tmp/orig.nm; }

echo "== vermagic"
want=$(modinfo -F vermagic "$MODDIR/kernel/net/xfrm/xfrm_user.ko.zst")
got=$(modinfo -F vermagic "$KO")
[ "$got" = "$want" ] && echo "ok: $got" || bad "vermagic '$got', stock '$want'"

echo "== Module.symvers of this build vs stock linux-headers-$KVER"
if cmp -s <(sort "$SYMVERS") <(sort "$TREE/Module.symvers"); then
	echo "ok: identical ($(wc -l < "$SYMVERS") exports, CRCs included)"
else
	bad "Module.symvers differs from stock:"
	diff <(sort "$SYMVERS") <(sort "$TREE/Module.symvers") | head -20
fi

echo "== modversion CRCs the module depends on"
modprobe --dump-modversions "$KO" > /tmp/modversions
gawk 'NR == FNR { crc[$2] = strtonum($1); next }
	!($2 in crc) { print "FAIL: " $2 " not exported by stock kernel"; bad = 1; next }
	crc[$2] != strtonum($1) { print "FAIL: " $2 " CRC " $1 " != stock"; bad = 1; next }
	{ print "ok: " $1 " " $2 }
	END { exit bad }' "$SYMVERS" /tmp/modversions || fail=1
readelf -sW "$KO" | awk '$7 == "UND" && $8 != "" { print $8 }' | sort -u > /tmp/und
for s in $(comm -23 /tmp/und <(awk '{ print $2 }' /tmp/modversions | sort -u)); do
	bad "undefined symbol $s has no modversion"
done

echo "== klp relocation symbols (.klp.sym.<obj>.<name>,<sympos>)"
readelf -sW "$KO" | awk '$8 ~ /^\.klp\.sym\./ { print $8 }' | sort -u > /tmp/klpsyms
[ -s /tmp/klpsyms ] || echo "(none)"
while read -r s; do
	s=${s#.klp.sym.}
	obj=${s%%.*} rest=${s#*.}
	name=${rest%,*} pos=${rest##*,}
	if [ "$obj" = vmlinux ]; then
		n=$(count_map "$name") o=$(count_orig "$name")
	else
		mod=$(find "$MODDIR" -name "$obj.ko.zst" | head -1)
		[ -n "$mod" ] || { bad "$obj.$name: module $obj not in stock"; continue; }
		zstd -qdcf "$mod" > /tmp/stockmod.ko
		n=$(nm /tmp/stockmod.ko | awk -v n="$name" '$3 == n { c++ } END { print c + 0 }')
		o=$n
	fi
	if [ "$n" -eq 0 ]; then
		bad "$obj.$name,$pos: missing from stock"
	elif [ "$n" -ne "$o" ]; then
		bad "$obj.$name,$pos: $n in stock, $o in this build (sympos would not match)"
	elif { [ "$pos" -eq 0 ] && [ "$n" -ne 1 ]; } || [ "$pos" -gt "$n" ]; then
		bad "$obj.$name,$pos: sympos invalid for $n stock symbols"
	else
		echo "ok: $obj.$name,$pos ($n in stock)"
	fi
done < /tmp/klpsyms

echo "== patched functions (from objtool klp diff)"
gawk '/: changed function: / { print $NF }' "$TREE/klp-tmp/diff/diff.log" | sort -u > /tmp/funcs
[ -s /tmp/funcs ] || bad "no changed functions in diff.log"
while read -r f; do
	n=$(count_map "$f") o=$(count_orig "$f")
	if [ "$n" -eq 1 ] && [ "$o" -eq 1 ]; then echo "ok: $f (unique in stock)"
	else bad "$f: $n in stock, $o in this build"; fi
done < /tmp/funcs

[ "$fail" -eq 0 ] && echo "STATIC CHECK PASSED" || { echo "STATIC CHECK FAILED"; exit 1; }
