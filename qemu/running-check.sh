#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check that a hypervisor runs the expected QEMU: qemu-system-x86 is installed at the
# version given, and no running QEMU process started before that package was installed
# (it would still be running the old build: an upgrade never replaces a running QEMU).
# Prints one line per running QEMU, "stale" for each that needs a stop/start or migration.
# Read-only. Usage: qemu/running-check.sh <version>   (root; exit status 0 when all current)
set -euo pipefail
want=${1:?usage: running-check.sh <qemu-system-x86 version>}
have=$(dpkg-query -W -f='${Version}' qemu-system-x86)
# dpkg rewrites the package's file list on every install of it.
installed=$(stat -c %Y /var/lib/dpkg/info/qemu-system-x86.list)
echo "$(hostname): qemu-system-x86 $have, installed $(date -u -d "@$installed" +%FT%TZ)"
rc=0
[ "$have" = "$want" ] || { echo "installed $have, want $want"; rc=1; }
for pid in $(pgrep -x qemu-system-x86 || true); do
	guest=$(tr '\0' '\n' < "/proc/$pid/cmdline" | grep -oE '^guest=[^,]+' | head -1 | cut -d= -f2)
	start=$(( $(date +%s) - $(ps -o etimes= -p "$pid") ))
	state=current
	if [ "$start" -lt "$installed" ] || readlink "/proc/$pid/exe" | grep -q '(deleted)'; then
		state=stale rc=1
	fi
	echo "  ${guest:-pid $pid} started $(date -u -d "@$start" +%FT%TZ) $state"
done
exit $rc
