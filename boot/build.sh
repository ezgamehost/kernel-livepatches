#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build ezgh-livepatch-boot: dracut configuration that keeps EZGH livepatch modules out of
# dracut initramfs images (no module of its own). Writes the .deb and SHA256SUMS to $OUT.
# Runs in ubuntu:26.04; seconds, no kernel tree. Usage: OUT=dir boot/build.sh
set -euo pipefail
DEB_NAME=ezgh-livepatch-boot
DEB_VER=1.0.0
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:?OUT is not set}
PKG=$(mktemp -d)
trap 'rm -rf "$PKG"' EXIT
chmod 0755 "$PKG"
mkdir -p "$OUT"
install -D -m 0644 "$REPO/boot/90-ezgh-livepatch.conf" "$PKG/usr/lib/dracut/dracut.conf.d/90-ezgh-livepatch.conf"
install -D -m 0755 "$REPO/boot/module-setup.sh" "$PKG/usr/lib/dracut/modules.d/99ezgh-livepatch/module-setup.sh"
install -d "$PKG/DEBIAN"
# No postrm: regenerating after removal would put the stripped livepatch back in.
install -m 0755 "$REPO"/boot/postinst "$PKG/DEBIAN/"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: $DEB_NAME
Version: $DEB_VER
Architecture: all
Maintainer: EZGH Cloud <matthewzhaocc@gmail.com>
Section: kernel
Priority: optional
Homepage: https://github.com/ezgamehost/kernel-livepatches
Description: keep EZGH livepatches out of dracut initramfs images
 dracut strips the kernel modules it copies into an initramfs, which turns a
 livepatch module's .klp.rela sections into sections the kernel ignores: the
 patch then loads without its relocations and faults on first use. This
 package omits every EZGH livepatch module (and its modules-load.d entry) from
 dracut images, so they load from the root filesystem, unstripped, and
 regenerates the dracut images of kernels that have them. No effect on hosts
 that use initramfs-tools.
CONTROL
DEB=$OUT/${DEB_NAME}_${DEB_VER}_all.deb
SOURCE_DATE_EPOCH=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || echo 0) \
	dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
cd "$OUT"
sha256sum "$(basename "$DEB")" > SHA256SUMS
cat SHA256SUMS
