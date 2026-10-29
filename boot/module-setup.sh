#!/bin/bash
# ezgh-livepatch-boot: drop the EZGH livepatch modules-load.d entries from the initramfs
# (90-ezgh-livepatch.conf omits the modules), so the initrd's systemd-modules-load doesn't
# try to load a module that isn't there. The root filesystem's entries load them.
check() { return 0; }
depends() { return 0; }
install() {
    rm -f "$initdir"/usr/lib/modules-load.d/livepatch-*.conf "$initdir"/etc/modules-load.d/livepatch-*.conf
}
