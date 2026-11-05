#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check that a guest still gets normal service from the devices hostd gives every instance
# (compute-stack internal/hostd/virt/xml.go): the qemu-xhci USB tablet, the guest agent's
# virtio-serial channel and virtio-rng from /dev/urandom. Boots a disposable guest from an
# Ubuntu cloud image under the installed QEMU and libvirt (KVM), then:
#   - the tablet enumerates, delivers pointer events, and a second tablet hot-plugs and
#     unplugs (xHCI attach, detach, wakeup and transfer-completion paths);
#   - the guest agent answers before and after the agent restarts (control open/close);
#   - /dev/hwrng is virtio_rng and serves 1 MiB of non-constant data;
#   - QEMU logged no "Blocked re-entrant IO" (normal use never trips the guard) and the
#     guest is still running.
# Exercises normal behaviour only: no oversized or malformed guest requests.
# Usage: qemu/guest-check.sh <ubuntu-cloudimg.img>   (root; exit status 0 when all hold)
set -euo pipefail
IMG=${1:?usage: guest-check.sh <ubuntu cloud image>}
NAME=ezgh-guest-check
DIR=/var/lib/libvirt/images/$NAME
die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

cleanup() { virsh destroy $NAME >/dev/null 2>&1 || true; virsh undefine $NAME --nvram >/dev/null 2>&1 || true; rm -rf "$DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$DIR"
qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$IMG")" "$DIR/disk.qcow2" 10G
cat > "$DIR/user-data" <<X
#cloud-config
packages: [qemu-guest-agent]
runcmd: [[systemctl, enable, --now, qemu-guest-agent]]
X
echo "instance-id: $NAME" > "$DIR/meta-data"
cloud-localds "$DIR/seed.img" "$DIR/user-data" "$DIR/meta-data"
chown -R libvirt-qemu: "$DIR" 2>/dev/null || true

# The device set of hostd's definition, without its disks, NICs and throttle groups.
virsh define /dev/stdin >/dev/null <<X
<domain type="kvm"><name>$NAME</name><memory unit="MiB">1024</memory><vcpu>2</vcpu>
<os><type arch="x86_64" machine="q35">hvm</type></os><features><acpi/></features><cpu mode="host-passthrough"/>
<devices>
<disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="$DIR/disk.qcow2"/><target dev="vda" bus="virtio"/></disk>
<disk type="file" device="cdrom"><driver name="qemu" type="raw"/><source file="$DIR/seed.img"/><target dev="sda" bus="sata"/><readonly/></disk>
<interface type="user"><model type="virtio"/></interface>
<controller type="usb" model="qemu-xhci"/><controller type="virtio-serial" index="0"/>
<channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
<serial type="pty"><target port="0"/></serial><console type="pty"><target type="serial" port="0"/></console>
<graphics type="vnc" autoport="yes" listen="127.0.0.1"/><video><model type="virtio"/></video>
<input type="tablet" bus="usb"/><memballoon model="none"/>
<rng model="virtio"><backend model="random">/dev/urandom</backend></rng>
<watchdog model="itco" action="reset"/><panic model="isa"/>
</devices></domain>
X
virsh start $NAME >/dev/null
LOG=/var/log/libvirt/qemu/$NAME.log
PID=$(cat /run/libvirt/qemu/$NAME.pid)
echo "qemu $(dpkg-query -W -f='${Version}' qemu-system-x86), pid $PID"

agent() { virsh qemu-agent-command $NAME "$1" 2>/dev/null; }
# gexec <shell command>: run it in the guest through the agent, print its stdout.
gexec() {
	local pid out
	pid=$(agent "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')],\"capture-output\":true}}" |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])' 2>/dev/null)
	for _ in $(seq 1 120); do
		out=$(agent "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")
		if python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["return"]["exited"] else 1)' "$out" 2>/dev/null; then
			python3 -c 'import base64,json,sys; r=json.loads(sys.argv[1])["return"]; sys.stdout.write(base64.b64decode(r.get("out-data","")).decode()); sys.exit(r.get("exitcode",1))' "$out"
			return
		fi
		sleep 0.5
	done
	die "guest command timed out: $1"
}

for _ in $(seq 1 120); do agent '{"execute":"guest-ping"}' >/dev/null && break; sleep 5; done
agent '{"execute":"guest-ping"}' >/dev/null || die "the guest agent never answered"
ok "guest agent answers"

# Tablet: enumerated, and pointer events reach the guest.
gexec 'grep -q "QEMU USB Tablet" /proc/bus/input/devices' || die "no USB tablet in the guest"
ev=$(gexec 'grep -A5 "QEMU USB Tablet" /proc/bus/input/devices | grep -o "event[0-9]*" | head -1')
gexec "(timeout 15 cat /dev/input/$ev > /tmp/ev 2>/dev/null < /dev/null &) ; echo started" >/dev/null
sleep 2
for i in $(seq 1 20); do
	virsh qemu-monitor-command $NAME "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$((i * 1000))}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$((i * 700))}}]}}" >/dev/null
	sleep 0.1
done
sleep 14
bytes=$(gexec 'stat -c %s /tmp/ev')
[ "${bytes:-0}" -gt 0 ] || die "the guest got no tablet events"
ok "tablet delivered ${bytes} bytes of input events"

# Hot-plug and unplug a second tablet on the same xHCI controller.
virsh qemu-monitor-command $NAME '{"execute":"device_add","arguments":{"driver":"usb-tablet","id":"t2","bus":"usb.0"}}' >/dev/null
sleep 3
[ "$(gexec 'grep -c "QEMU USB Tablet" /proc/bus/input/devices')" = 2 ] || die "the hot-plugged tablet did not appear"
virsh qemu-monitor-command $NAME '{"execute":"device_del","arguments":{"id":"t2"}}' >/dev/null
sleep 3
[ "$(gexec 'grep -c "QEMU USB Tablet" /proc/bus/input/devices')" = 1 ] || die "the unplugged tablet did not go away"
ok "second tablet hot-plugged and unplugged"

# Guest agent: restart it (the port closes and reopens), and it still answers.
# Restart from a timer: the agent running the command is the one being restarted.
gexec 'systemd-run -q --on-active=2 systemctl restart qemu-guest-agent' >/dev/null
sleep 6
for _ in $(seq 1 20); do agent '{"execute":"guest-ping"}' >/dev/null && break; sleep 1; done
agent '{"execute":"guest-get-osinfo"}' | grep -q ubuntu || die "the guest agent did not come back after a restart"
ok "guest agent answers after a restart"

# Entropy: virtio-rng serves the guest's hwrng.
[ "$(gexec 'cat /sys/class/misc/hw_random/rng_current')" = virtio_rng.0 ] || die "hwrng is not virtio_rng.0"
distinct=$(gexec 'timeout 60 head -c 1048576 /dev/hwrng | od -An -tx1 -v | tr -s " " "\n" | sort -u | grep -c .')
[ "$distinct" = 256 ] || die "1 MiB from /dev/hwrng had $distinct distinct byte values"
ok "1 MiB read from virtio-rng"

if grep -q "Blocked re-entrant IO" "$LOG"; then die "QEMU blocked re-entrant IO in normal use: $(grep 'Blocked re-entrant' "$LOG" | head -1)"; fi
[ "$(virsh domstate $NAME)" = running ] && kill -0 "$PID" || die "the guest is not running"
ok "no blocked re-entrant IO; guest running"
echo OK
