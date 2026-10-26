#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build livepatch-xfrm-pcpu.ko and its .deb for Ubuntu 7.0.0-38-generic, then
# run the static compatibility check against the stock kernel.
#
# Runs as root inside ubuntu:26.04 (amd64), see README.md:
#   build.sh              full build (several hours on 4 CPUs)
#   build.sh --preflight  toolchain, source, config and patch checks only
#
# Env: WORK (default /build) holds the tree, OUT (default ./out) the results,
# HOST_UID chowns OUT at the end. Mount the host CA bundle at /hostca.pem
# (see snapshot-apt.sh).
set -euo pipefail

SNAPSHOT=20261018T000000Z # also in snapshot-apt.sh
KVER=7.0.0-38-generic
KPKG=7.0.0-38.38
SIG="Ubuntu 7.0.0-38.38-generic 7.0.14"
GCC_PKG=15.2.0-16ubuntu1
BINUTILS_PKG=2.46-3ubuntu2
GCC_TEXT="x86_64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0"
LD_TEXT="GNU ld (GNU Binutils for Ubuntu) 2.46"
# Cumulative atomic-replace module. Each release takes a new module and package
# name, so the upgrade loads it over the old one instead of unloading that first.
NAME=livepatch-xfrm-pcpu-2
DEB_NAME=ezgh-livepatch-xfrm-pcpu-2-$KVER
DEB_VER=1.1.0

REPO=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/build}
OUT=${OUT:-$REPO/out}

die() { echo "error: $*" >&2; exit 1; }
want() { [ "$2" = "$3" ] || die "$1: got '$2', want '$3'"; echo "ok $1: $2"; }

[ "$(dpkg --print-architecture)" = amd64 ] || die "must run on amd64"
[ "$(id -u)" = 0 ] || die "must run as root (in a container)"

# --- Ubuntu snapshot only -------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
"$REPO/snapshot-apt.sh"
apt-get build-dep -y -q --arch-only "linux=$KPKG"
# libxxhash-dev: objtool --checksum (klp-build only; not used by the stock build)
apt-get install -y -q --no-install-recommends dpkg-dev git gawk kmod zstd libxxhash-dev

# --- Toolchain must be the one that built the stock kernel ----------------
want "gcc-15 package" "$(dpkg-query -W -f='${Version}' gcc-15)" "$GCC_PKG"
want "binutils package" "$(dpkg-query -W -f='${Version}' binutils-x86-64-linux-gnu)" "$BINUTILS_PKG"
want "gcc --version" "$(x86_64-linux-gnu-gcc --version | head -1)" "$GCC_TEXT"
want "ld --version" "$(x86_64-linux-gnu-ld --version | head -1)" "$LD_TEXT"

# --- Source and stock binaries (apt verifies every hash) ------------------
mkdir -p "$WORK/stock" "$WORK/patches" "$OUT"
cd "$WORK"
apt-get source -q --download-only "linux=$KPKG"
rm -rf linux && dpkg-source -x "linux_$KPKG.dsc" linux >/dev/null
SRC=$WORK/linux
apt-get download -q "linux-modules-$KVER=$KPKG" "linux-headers-$KVER=$KPKG"
for d in linux-modules-"$KVER"_*.deb linux-headers-"$KVER"_*.deb; do dpkg-deb -x "$d" stock; done
STOCK_CONFIG=$WORK/stock/boot/config-$KVER
cmp "$STOCK_CONFIG" "$WORK/stock/usr/src/linux-headers-$KVER/.config"

# --- Ubuntu's kmake variables (debian/rules.d/0-common-vars.mk) -----------
# Variable definitions in MAKEFLAGS act as command-line overrides for every
# make that klp-build runs.
export MAKEFLAGS="ARCH=x86 CROSS_COMPILE=x86_64-linux-gnu- HOSTCC=x86_64-linux-gnu-gcc CC=x86_64-linux-gnu-gcc RUSTC=rustc HOSTRUSTC=rustc RUSTFMT=rustfmt BINDGEN=bindgen KERNELRELEASE=$KVER CONFIG_DEBUG_SECTION_MISMATCH=y KBUILD_BUILD_VERSION=38 CFLAGS_MODULE=-DPKG_ABI=38 PYTHON=/usr/bin/python3"
cd "$SRC"
cp "$STOCK_CONFIG" .config
make -s olddefconfig
diff -u "$STOCK_CONFIG" .config || die "make olddefconfig changed the stock config"
echo "ok olddefconfig: no change to config-$KVER"
want "kernelrelease" "$(make -s kernelrelease)" "$KVER"
want "version signature" "$(sed -n 's/^CONFIG_VERSION_SIGNATURE="\(.*\)"$/\1/p' .config)" "$SIG"

cp "$REPO"/patches/*.patch "$WORK/patches/"
# Later patches build on earlier ones, but klp-build refreshes each patch
# against the unpatched tree. Apply them in order, diff the result into one
# patch for klp-build, then restore the tree.
files=$(sed -n 's|^+++ b/||p' "$WORK"/patches/*.patch | sort -u)
mkdir -p "$WORK/orig"
cp --parents $files "$WORK/orig/"
applied=()
for p in "$WORK"/patches/*.patch; do
	sed -n '/^-- /q;p' "$p" | git apply -v
	applied=("$p" "${applied[@]}")
done
SERIES=$WORK/series.patch
for f in $files; do
	diff -u --label "a/$f" --label "b/$f" "$WORK/orig/$f" "$f" || [ $? = 1 ]
done > "$SERIES"
for p in "${applied[@]}"; do sed -n '/^-- /q;p' "$p" | git apply -R; done
echo "ok patches: apply to the Ubuntu tree"
if [ "${1:-}" = --preflight ]; then echo "preflight OK"; exit 0; fi

# --- Build ------------------------------------------------------------------
# Atomic replace (klp-build default): loading supersedes every livepatch on the
# host in one transition, including 1.0.0 (livepatch_xfrm_pcpu).
./scripts/livepatch/klp-build --keep-tmp -j"$(nproc)" \
	-o "$OUT/$NAME.ko" "$SERIES" 2>&1 | tee "$OUT/klp-build.log"
cp klp-tmp/diff/diff.log "$OUT/klp-diff.log"

"$REPO/check.sh" "$OUT/$NAME.ko" "$WORK/stock" "$SRC" | tee "$OUT/static-check.txt"

# --- Package ----------------------------------------------------------------
PKG=$WORK/pkg
rm -rf "$PKG"
install -D -m 0644 "$OUT/$NAME.ko" "$PKG/usr/lib/modules/$KVER/updates/ezgh/$NAME.ko"
install -d "$PKG/usr/lib/modules-load.d" "$PKG/DEBIAN"
# Sorts after 1.0.0's livepatch-xfrm-pcpu.conf, which stays installed (PM never
# removes packages): at boot this module loads last and replaces that one.
echo "${NAME//-/_}" > "$PKG/usr/lib/modules-load.d/zz-$NAME.conf"
install -m 0755 "$REPO"/packaging/{postinst,prerm,postrm} "$PKG/DEBIAN/"
cat > "$PKG/DEBIAN/control" <<EOF
Package: $DEB_NAME
Version: $DEB_VER
Architecture: amd64
Maintainer: EZGH Cloud <matthewzhaocc@gmail.com>
Depends: linux-image-$KVER (= $KPKG), kmod
Section: kernel
Priority: optional
Homepage: https://github.com/ezgamehost/kernel-livepatches
Description: livepatch for xfrm per-CPU SA fallback bugs ($SIG)
 Cumulative atomic-replace livepatch module $NAME (sysfs ${NAME//-/_})
 carrying four xfrm_state fixes for per-CPU IPsec SAs (Fixes: 1ddf9916ac09).
 Loading it replaces 1.0.0 (livepatch_xfrm_pcpu) and any other livepatch in
 one transition. Loads at install when the running kernel is exactly $SIG,
 and at every boot of $KVER.
EOF
DEB=$OUT/${DEB_NAME}_${DEB_VER}_amd64.deb
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"

cd "$OUT"
cp "$STOCK_CONFIG" "config-$KVER"
cp "$REPO"/patches/*.patch .
sha256sum "$NAME.ko" "$(basename "$DEB")" "config-$KVER" 0*.patch > SHA256SUMS
cat > BUILDINFO <<EOF
kernel: $SIG ($KVER, linux $KPKG)
snapshot: https://snapshot.ubuntu.com/ubuntu/$SNAPSHOT
gcc: $(x86_64-linux-gnu-gcc --version | head -1)
ld: $(x86_64-linux-gnu-ld --version | head -1)
rustc: $(rustc --version)
bindgen: $(bindgen --version 2>/dev/null | head -1)
pahole: $(pahole --version)
make: $MAKEFLAGS
module: $NAME.ko (sysfs /sys/kernel/livepatch/${NAME//-/_})
package: $(basename "$DEB")
build seconds: $SECONDS
EOF
cat SHA256SUMS BUILDINFO
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID" "$OUT"; fi
echo "build OK"
