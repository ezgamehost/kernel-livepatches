# kernel-livepatches

Linux livepatch modules for EZGH Cloud hosts. Each module is built for one exact
stock Ubuntu kernel and is published as a signed apt package.

| Module | Kernel | Package |
| --- | --- | --- |
| `livepatch-xfrm-pcpu-2` (sysfs `livepatch_xfrm_pcpu_2`) | `Ubuntu 7.0.0-38.38-generic 7.0.14` | `ezgh-livepatch-xfrm-pcpu-2-7.0.0-38-generic` 1.1.0 |
| `livepatch-xfrm-pcpu` (sysfs `livepatch_xfrm_pcpu`), superseded | `Ubuntu 7.0.0-38.38-generic 7.0.14` | `ezgh-livepatch-xfrm-pcpu-7.0.0-38-generic` 1.0.0 |

From 1.1.0, each module is cumulative and built with atomic replace: loading it
supersedes every livepatch on the host, including the previous release, in one
transition. Each release has a new module and package name, so an upgrade
installs the new package (which loads over the old one) instead of upgrading
the old package, whose prerm would unload it first. The old package can stay
installed. The new package blacklists every older module name in
`/usr/lib/modprobe.d/`, because systemd-modules-load (systemd 259) probes
modules in parallel: an older module loaded after the new one would be patched
on top of it and win, while both report enabled. An explicit `modprobe` of an
older module still works, for a rollback. 1.0.0 was built with `--no-replace`.

Roll back 1.1.0 to 1.0.0 by removing the 1.1.0 package (its prerm disables and
unloads the module, leaving the kernel unpatched), then `modprobe -r
livepatch_xfrm_pcpu && modprobe livepatch_xfrm_pcpu`: a replaced livepatch
cannot be re-enabled, only reloaded.

Identify a loaded build by its module name and GNU build-id. Read the build-id
from `/sys/module/NAME/notes/.note.gnu.build-id` as root (the last 20 bytes of
the note) or with `readelf -n` on the `.ko`. Do not use `srcversion`: klp-build
computes it from its generated module stub, so every module here reports
`83A1BA27BABEED7E191B9DA` whatever it patches.

| Tag | `.ko` | Build-id | `.ko` sha256 |
| --- | --- | --- | --- |
| `v1.1.0` | `livepatch-xfrm-pcpu-2.ko` | `afeed34a00a9e6eea5f65c0eec640d8c1d65743a` | `b47e1eea575524d2160bbb3fb3f1483048a5095d4187340ec3a8d34ee8bf3d85` |
| `v1.0.0` | `livepatch-xfrm-pcpu.ko` | `280da6ff9ffa60e252bf51f91aac68a9e26883d8` | `6f6394dd17027f1b1dd2fcd59c26204143da755428f62287b08bf9fc07abc7a5` |

For v1.0.0, two independent CI builds produced the same `.ko`, and the
published `.deb` has sha256
`c36a55de9c59f06225261b8cb7a0e551a75cb75911c7fba18f13917be66eba77`.

## The bugs

All are in `net/xfrm/xfrm_state.c` per-CPU SA handling (RFC 9611), added by
1ddf9916ac09 ("xfrm: Add support for per cpu xfrm state handling."). Every
patch carries that `Fixes:` tag. 0001–0003 are the ipsec v2 series, which
replaced the single v1 patch after review; they apply in order.

- [`patches/0001`](patches/0001-xfrm-state-don-t-return-an-unchecked-state-from-xfrm.patch):
  under a packet-offload `XFRM_POLICY_CPU_ACQUIRE` policy, `xfrm_state_find()`
  can return a state that a walk stopped on without checking it.
- [`patches/0002`](patches/0002-xfrm-state-ignore-other-CPUs-acquires-in-xfrm_state_.patch):
  another CPU's pending acquire stops this CPU from starting its own, so
  per-CPU SAs are negotiated one CPU at a time.
- [`patches/0003`](patches/0003-xfrm-state-use-the-fallback-SA-while-a-per-CPU-acqui.patch):
  while a per-CPU acquire is pending, `xfrm_state_find()` ignores the valid
  fallback SA and returns `-EAGAIN`, so packets on that CPU are dropped until the
  key manager installs the CPU's SA. Also covers a wildcard-source fallback.
  This is v1's fix (the only patch in 1.0.0), extended.
- [`patches/0004`](patches/0004-xfrm-state-prefer-the-CPU-s-own-SA-over-a-newer-fall.patch):
  `xfrm_state_look_at()` lets a fallback SA added after the CPU's own SA replace
  it as best, which starts a duplicate acquire and leaves the CPU's SA unused.
  Rebased onto the v2 series; not yet sent upstream.

They were written against ipsec master (base 835912998ca5) and apply in order
to the Ubuntu 7.0.0-38.38 tree without fuzz. The patch files are the ones
prepared for upstream, without the submitter's `Signed-off-by`.

## Provenance and pins

The build reproduces the stock kernel build environment and fails on any
difference:

- Container `ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944`.
  Its apt sources point only at the Ubuntu snapshot
  `https://snapshot.ubuntu.com/ubuntu/20261018T000000Z` (resolute, -updates,
  -security). All packages are checked against the Ubuntu archive signature.
- Toolchain: `apt-get build-dep linux=7.0.0-38.38`. The build asserts gcc-15
  `15.2.0-16ubuntu1` (`x86_64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0`)
  and binutils `2.46-3ubuntu2` (`GNU ld (GNU Binutils for Ubuntu) 2.46`), the
  versions in the stock `/proc/version`.
- Source: `apt-get source linux=7.0.0-38.38`.
- Config: `/boot/config-7.0.0-38-generic` from the stock
  `linux-modules-7.0.0-38-generic` package. `make olddefconfig` must leave it
  unchanged, including the gcc, rustc and pahole version strings.
- Make variables: Ubuntu's `kmake` from `debian/rules.d/0-common-vars.mk`
  (`CC=x86_64-linux-gnu-gcc`, `KERNELRELEASE=7.0.0-38-generic`,
  `CONFIG_DEBUG_SECTION_MISMATCH=y`, `KBUILD_BUILD_VERSION=38`,
  `CFLAGS_MODULE=-DPKG_ABI=38`, etc.), passed via `MAKEFLAGS`.
- Builder: the tree's own `scripts/livepatch/klp-build`, with atomic replace
  (its default), so that the module supersedes earlier releases.
- Debug info stays on. The stock config uses `CONFIG_GENDWARFKSYMS`, so the
  modversion CRCs come from DWARF. The build does not run `debian/rules`, so no
  dbgsym or other Ubuntu packages are produced.

## Static compatibility check

[`check.sh`](check.sh) runs as part of every build and fails it on any mismatch.
Its output is published as `static-check.txt`.

- It lists the module's `import_ns` tags. klp-build copies every namespace import
  of the patched objects (all of vmlinux.o's built-in drivers). These are inert
  unless the module uses a namespaced symbol. The check fails on a `module:`
  import, which the loader rejects. Added after v1.0.0, whose module has none.
- The `vermagic` equals that of the stock modules.
- The build's `Module.symvers` is identical to the stock
  `linux-headers-7.0.0-38-generic` one, CRCs included. Every modversion CRC
  that the module imports matches it.
- Every `.klp.sym.<obj>.<name>,<sympos>` symbol that the module resolves at load
  time exists in the stock `System.map-7.0.0-38-generic`. The same-name count
  matches the build's unpatched `vmlinux.o`, so each sympos selects the same
  symbol.
- Every patched function (`xfrm_state_find`, `xfrm_state_look_at`) is unique in
  the stock `System.map`.

## Install

The signed apt repository is at `https://get.ezghcloud.com/kernel-livepatches/apt`
(suite `resolute`, component `main`):

```sh
curl -fsSL https://get.ezghcloud.com/kernel-livepatches/apt.asc \
  -o /etc/apt/keyrings/ezgh-kernel-livepatches.asc
echo 'deb [signed-by=/etc/apt/keyrings/ezgh-kernel-livepatches.asc] https://get.ezghcloud.com/kernel-livepatches/apt resolute main' \
  > /etc/apt/sources.list.d/ezgh-kernel-livepatches.list
apt-get update
apt-get install ezgh-livepatch-xfrm-pcpu-2-7.0.0-38-generic
```

Compare the key with [`keys/apt.asc`](keys/apt.asc) (fingerprint
`B42D D9D0 2D37 8220 233C  E607 5398 FA60 DA2D 5332`).

- The module is installed in `/usr/lib/modules/7.0.0-38-generic/updates/ezgh/`.
  `/usr/lib/modules-load.d/livepatch-xfrm-pcpu-2.conf` loads it at boot, and
  `/usr/lib/modprobe.d/livepatch-xfrm-pcpu-2.conf` blacklists older modules.
- postinst runs `depmod`. It loads the patch immediately only if `uname -r` is
  `7.0.0-38-generic` and `/proc/version_signature` is exactly
  `Ubuntu 7.0.0-38.38-generic 7.0.14`. It then waits up to 120 s for
  `/sys/kernel/livepatch/livepatch_xfrm_pcpu_2/transition` to reach 0, and fails
  the install if it does not.
- The module is not signed with a key that the kernel trusts. This kernel does
  not enforce module signatures, so it loads with the `E` (unsigned) and `K`
  (livepatch) taint flags.

Check that the patch is active:

```sh
cat /sys/kernel/livepatch/livepatch_xfrm_pcpu_2/enabled     # 1
cat /sys/kernel/livepatch/livepatch_xfrm_pcpu_2/transition  # 0
```

### Hosts that boot with dracut: `ezgh-livepatch-boot`

Install `ezgh-livepatch-boot` too on any host whose initramfs is built by dracut
(Ubuntu 26.04 installs that use dracut rather than initramfs-tools). dracut copies
the modules listed in `modules-load.d` into the initramfs and strips them. Stripping
rewrites a livepatch's `.klp.rela.*` sections into a type the kernel ignores, so
the patch loads from the initramfs without its relocations: `enabled` is 1,
`transition` 0 and the build-id matches, but its `.klp.sym.*` symbols stay at 0 in
`/proc/kallsyms` and the patched code faults on first use. On gp1-01 (2026-10-29)
that was a general protection fault in `xfrm_state_find` at the first per-CPU
acquire, and a kernel panic.

The package adds `/usr/lib/dracut/dracut.conf.d/90-ezgh-livepatch.conf`
(`omit_drivers` for every `livepatch_*` module) and a dracut module that drops
their `modules-load.d` entries from the image, then regenerates the dracut
initramfs of each kernel that has EZGH livepatches. The livepatch then loads from
the root filesystem, unstripped. It takes effect at the next boot. It has no
postrm, because regenerating after removal would put the stripped module back.
Hosts on initramfs-tools never put the module in the initramfs and need nothing.

Check a loaded patch's relocations (as root):

```sh
grep '\[livepatch_xfrm_pcpu_2\]' /proc/kallsyms | grep ' .klp.sym.'   # no address may be 0
lsinitrd | grep -i livepatch                                         # dracut: only the modprobe.d blacklist
```

Build it with `OUT=out boot/build.sh` in `ubuntu:26.04` (seconds; no kernel tree),
and publish it from a `boot-v*` tag.

## Uninstall

```sh
apt-get remove ezgh-livepatch-xfrm-pcpu-2-7.0.0-38-generic
```

prerm writes 0 to `enabled` and waits up to 120 s for the patch to go away.
From the next livepatch package on it does so only on removal: 1.1.0's prerm also
runs on an in-place upgrade, which would unpatch a running host until the new
postinst loads the module again, so 1.1.0 is never upgraded in place. It
then unloads the module, and fails loudly if either step does not complete.

## Verify a download

There are no GitHub Releases. The apt repository and the per-version files on
get.ezghcloud.com are the distribution:

```
https://get.ezghcloud.com/kernel-livepatches/files/v1.1.0/
  livepatch-xfrm-pcpu-2.ko  ezgh-livepatch-xfrm-pcpu-2-7.0.0-38-generic_1.1.0_amd64.deb
  SHA256SUMS  SHA256SUMS.asc  BUILDINFO  static-check.txt
  config-7.0.0-38-generic  0001-*.patch ... 0004-*.patch
```

```sh
gpg --dearmor < keys/apt.asc > apt.gpg
gpgv --keyring ./apt.gpg SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
gpgv --keyring ./apt.gpg InRelease   # .../kernel-livepatches/apt/dists/resolute/InRelease
```

`SHA256SUMS` also covers the stock config and the patches, so the inputs can be
compared with this repository.

## Build

```sh
docker run --rm -v "$PWD:$PWD" -w "$PWD" \
  -v /etc/ssl/certs/ca-certificates.crt:/hostca.pem:ro \
  -e WORK="$PWD/work" -e OUT="$PWD/out" \
  ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 \
  "$PWD/build.sh"            # add --preflight for the checks only
```

The build needs amd64, about 4 CPUs for several hours, and up to 100 GB of
disk. klp-build builds the whole kernel with debug info, including modules,
keeps a copy of every object, and then rebuilds the patched objects. `mkrepo.sh` adds a build to the apt tree and signs it. EZGH's CI runs both
scripts from a private repository on internal runners and uploads the signed
tree to get.ezghcloud.com.

## QEMU

The same apt repository carries Ubuntu's QEMU rebuilt with the patches in
[`qemu/patches`](qemu/patches), as `1:10.2.1+ds-1ubuntu3.2+ezgh2`: the packages a
hypervisor installs from the `qemu` source (`qemu-system-x86`, `-common`, `-gui`,
`-modules-opengl`, `-modules-spice`, `qemu-block-extra`, `qemu-utils`). Ubuntu's
`qemu-system-data` stays as it is. Hosts get them as exact pins in their OS release.

- [`0001`](qemu/patches/0001-block-throttle-count-a-discard-as-one-request-not-by.patch):
  the throttle filter charged a discard's full length to the group's bps buckets, so a
  guest trimming free space used up its volume's MB/s budget and its writes waited for
  seconds behind the trims. A discard now counts as one request of no bytes: still
  against the IOPS limits, never against the bps ones.
- [`0002`](qemu/patches/0002-hw-usb-hcd-xhci-Set-reentrancy-guard-in-timer-functi.patch)–[`0004`](qemu/patches/0004-hw-usb-hcd-xhci-More-reentrancy-guard-fixes-for-the-.patch),
  upstream f91b0544fe1f, 89e653b77369 and cfa70f3a82f5, unchanged: qemu-xhci ran its timers
  (0002, CVE-2026-17588) and its USB port and bus callbacks (0004, CVE-2026-111819:
  transfer completion, endpoint and port wakeup, attach and detach, which the USB tablet
  reaches on every input event) without the device's reentrancy guard, so an event-ring
  write or an MSI-X message the guest aimed at the controller's own doorbell could run
  commands that free state the outer call still uses. 0003 limits the controller's
  descriptor and event writes to RAM. 0004 is needed as well as 0002: MSI-X writes are not
  descriptor writes, so 0003 does not cover them.
- [`0005`](qemu/patches/0005-hw-char-virtio-serial-bus-fix-guest-triggerable-OOM-.patch),
  posted upstream and not yet merged: virtio-serial allocated and filled a buffer as long
  as the guest's control-queue descriptors claimed (up to 1024 × 4 GiB, aliasing the same guest pages), to read eight
  bytes from it. It now copies only the eight-byte control header; every message the
  guest agent's driver sends is that header, and is handled as before.
- [`0006`](qemu/patches/0006-hw-virtio-virtio-rng-bound-each-entropy-request.patch):
  virtio-rng asked its backend for as many bytes as the guest's buffers held (the rate
  limit is unset), and the backend allocates each request. It now asks for at most 64 KiB
  at a time; a larger buffer comes back partly filled and further requests follow while
  buffers remain. Upstream caps the same size in the backend (70074cc48f45).

[`qemu/check.sh`](qemu/check.sh) tests this with `qemu-io` over a `null-co` disk (no
guest or KVM): a 4 KiB write after a 100 MiB discard through a 10 MB/s group must
finish in under 1 s (stock QEMU: 10.4 s), and 30 discards through a 10 IOPS group must
take at least 1.5 s. Run it on a host after an upgrade; the build runs it against the
built `qemu-utils` before anything is published.

[`qemu/guest-check.sh`](qemu/guest-check.sh) boots a disposable Ubuntu guest under the
installed QEMU and libvirt with hostd's device set and checks normal service from the
patched devices: the USB tablet enumerates, delivers pointer events, and a second tablet
hot-plugs and unplugs; the guest agent answers before and after it restarts; 1 MiB reads
from virtio-rng; and QEMU logs no blocked re-entrant I/O. It sends no malformed requests.
Run it on a test host (root, KVM, `libvirt-daemon-system`, `cloud-image-utils`), never on
a hypervisor serving instances.

`OUT=out qemu/build.sh` in `ubuntu:26.04` (amd64, root, the host CA at `/hostca.pem`)
takes hours, since Ubuntu's rules build every target, and publishes from a
`qemu-v10.2.1+ds-1ubuntu3.2+ezgh2` tag. The release files hold the source package
(`.dsc`, `.debian.tar.xz`, the patches); its `qemu_10.2.1+ds.orig.tar.xz` is
Ubuntu's, from the same snapshot.

A running VM keeps the QEMU it started with until it restarts or migrates: upgrading the
package fixes nothing for it, and a guest reboot keeps the same QEMU process. After an
upgrade, every domain whose QEMU started before the install still runs the old build, and
needs a stop/start or a live migration to an upgraded host.
[`qemu/running-check.sh <version>`](qemu/running-check.sh) finds them on a host
(read-only; the install time is the mtime of dpkg's file list for `qemu-system-x86`): it fails unless `qemu-system-x86` is at `<version>` and no running QEMU started
before it was installed, and names each stale domain.

Rolling out a new `+ezghN`: register an OS release for each cell that copies the cell's
current one and changes only the seven pins above (`qemu-system-data` stays Ubuntu's),
roll it out cell by cell, run `qemu/running-check.sh` on every host, then migrate or
stop/start each stale domain until it passes. `+ezgh1` and `+ezgh2` live-migrate to each
other both ways with hostd's device set (they change no migration state); a cell with a single hypervisor
can only stop/start. A guest-facing fix protects an instance only once its own QEMU
restarted on the new build.

## NFS-Ganesha

The same apt repository carries upstream NFS-Ganesha V15.10 for EZGH Files gateway hosts,
as `15.10-1+ezgh5`: `nfs-ganesha`, `nfs-ganesha-ceph` and `nfs-ganesha-rados-grace`, the
names (and `/usr/bin/ganesha.nfsd`) of Ubuntu's packages. Ubuntu 26.04's `6.5-8` has
neither RPC-with-TLS nor per-export QoS, and it is built against Ubuntu's Ceph 20.2.0
libraries, which can't read the AES256K keys a 20.2.4 cluster issues. This build has:

- RPC-with-TLS through OpenSSL with kTLS (`-DUSE_TLS=ON -DUSE_OPENSSL=ON`) and QoS
  (`-DENABLE_QOS=ON`), FSAL_CEPH, the `rados_cluster` recovery backend, RADOS URL
  configuration (`%url`, `RADOS_URLS`) and `ganesha-rados-grace`; NFSv4 only (no NFSv3,
  NLM, RQUOTA or 9P), no other FSAL, no admin tools. The cmake flags are files-stack's
  `deploy/proofs/image-upstream`, the build Files' proofs tested.
- Three patches, [`ganesha/patches`](ganesha/patches) (applied by `build.sh` with quilt).
  TLS (0001):
  `ganesha.nfsd` exits at startup when `TLS_CONFIG` enables TLS and its certificate or key
  doesn't load (V15.10 logs it and serves without TLS). A CA file that doesn't load
  (`TLS_CA_File` unset and nothing at the default `/etc/ganesha/tls/ca.crt`) isn't fatal:
  client certificates are optional, so none is requested then; with a CA, clients without a
  certificate are accepted as before. SIGHUP (or D-Bus `reread_config`) rereads
  `TLS_CONFIG` first, before the blocks that can fail a reread, and when the certificate,
  key or CA file changed (path, inode, size or times) a certificate and key that load into a
  fresh `SSL_CTX` are swapped in for new connections; established TLS sessions keep the one
  they started with, and one that fails to load leaves the current certificate in place,
  with an error logged once. Turning TLS on or off takes a restart. V15.10 reads
  `TLS_CONFIG` only at startup.
- Fencing (0002): the `rados_cluster` recovery backend writes `addrs.<nodeid>` (WriteFull,
  in `RADOS_KV`'s pool and namespace, the grace database's) right after its RADOS client
  connects and before it touches the grace database: `host <hostname>`, `pid <pid>`, then
  one `<role> <addr>` line per RADOS client, `recov` and, with RADOS URLs, `urls`, each
  address as `rados_getaddrs()` returns it, so whoever takes the node over can blocklist
  them (host and pid tell this instance from a replacement). If anything is missing or the
  write fails, `ganesha.nfsd` exits; once published, no new RADOS URLs client is created (a
  reread that needs one is refused). Failover (0003): grace-database notifies wait 1 s for
  acks instead of 3 s (a dead node's watch lingers 30 s; nothing reads the acks; librados
  sends whole seconds and the OSD reads 0 as its 30 s default), and the last expected
  `RECLAIM_COMPLETE` wakes the reaper, so grace lifts then rather than at its next tick.
- Upstream Ceph `20.2.4-1noble` client libraries from `download.ceph.com/debian-20.2.4`
  (checked against [`ganesha/ceph-release.asc`](ganesha/ceph-release.asc), fingerprint
  `08B7 3419 AC32 B4E9 66C1  A330 E84A C2C0 460F 3994`), the repository the hosts' OS
  release already carries for `librados2`. `nfs-ganesha-ceph` and `nfs-ganesha-rados-grace`
  depend on `libcephfs2` and `librados2` at exactly `20.2.4-1noble`: `libcephfs2` uses
  hundreds of `libceph-common`'s private symbols, which come from `librados2`, so the two
  move in lockstep and never with a different Ceph build.
- `libcephfs2` needs ICU 74, which only noble has: the release also publishes Ubuntu's
  noble-updates `libicu74` `74.2-1ubuntu3.1`, unchanged, from the same Ubuntu snapshot, so
  a gateway host needs nothing from noble `main` (`librados2`'s `libthrift-0.19.0t64` comes
  from noble `universe`, which the cell's OS release already carries). The build installs that same version
  (noble pinned at priority 100 there, so it serves only what resolute lacks).
- The bundled ntirpc (`libntirpc.so.15.7`, in `nfs-ganesha`; Ubuntu's `libntirpc6.3` is
  `.so.6.3` and may stay installed). Ganesha's own libraries are in `/usr/lib/ganesha`
  (RPATH), ntirpc and FSAL_CEPH in `/usr/lib/x86_64-linux-gnu` (`ganesha/` for the FSAL), as
  Ubuntu lays them out.
- `nfs-ganesha` depends on `libtirpc-common` for `/etc/netconfig`, without which
  `ganesha.nfsd` exits at startup.
- Upstream's D-Bus policy for `org.ganesha.nfsd`, but no systemd units and no
  `/etc/ganesha`: files-stack ships `ganesha@.service` with filesd and renders each rank's
  config, so nothing starts on install. Each rank owns `rank<r>.org.ganesha.nfsd` (its
  `Dbus_Name_Prefix`); files-stack's `files-gateway` Ansible role installs the policy that
  lets root own those.

The source is the `V15.10` tag at `38f542cd5ef8` with its submodules (ntirpc with its
prometheus-cpp-lite, and libkmip), cloned from GitHub; the build fails if the tag or a
submodule points anywhere else. The packaging is [`ganesha/debian`](ganesha/debian).

[`ganesha/check.sh`](ganesha/check.sh) checks the installed packages without a cluster:
every binary and library resolves its libraries, `libcephfs.so.2` and `librados.so.2` come
from Ceph's packages at one and the same version (`>= 20.2.4`) and they and the FSAL and
RADOS modules resolve every symbol (`ldd -r`), ntirpc comes from `nfs-ganesha` with
OpenSSL (not GnuTLS), and TLS and QoS are compiled in (`ganesha.nfsd` is run on throwaway
configs that it stops reading before it binds anything). Ganesha reads `TLS_CONFIG` and
`QOS_DEFAULT_CONFIG` only when they are, so an out-of-range value in either must stop it,
and a valid pair (TLS on with kTLS and a throwaway certificate, QoS on) must get past both
with the RADOS URLs library loaded; the `rados_cluster` recovery backend must load; a
missing certificate must make `ganesha.nfsd` exit at startup, and a missing CA must not.
Then it starts a server on `127.0.0.1:32049` (`PORT`) with a throwaway certificate as its
own CA and, with `openssl s_client` presenting no client certificate: a handshake gets the
certificate and an NFS NULL call gets its reply; a session opened before a SIGHUP that
swaps in a new certificate still gets a NULL reply afterwards and closes cleanly, while new
handshakes get the new certificate; a SIGHUP with unchanged files doesn't reload, a broken
certificate is refused once and the current one kept, turning TLS off is refused once; and
20 more reloads leave it serving the last certificate and exiting cleanly. Run it on a host after an upgrade; the build runs it before anything is
published and publishes its output as `ganesha-check.txt`, with that of
[`ganesha/addrs-check.sh`](ganesha/addrs-check.sh): a `rados_cluster` `ganesha.nfsd` on a
stub `librados` (built with `cc` there) must write `addrs.<nodeid>` with its `host`, `pid`,
`recov` and `urls` lines before its grace-database membership check, and exit when the write
fails or a client has no address.
[`ganesha/gateway-check.sh`](ganesha/gateway-check.sh) installs what a gateway host gets
(the Ubuntu snapshot's resolute and noble `universe`, this repository, download.ceph.com,
the exact versions)
from the published repositories and runs `check.sh` on it; the publish CI runs it after
publishing.

`OUT=out ganesha/build.sh` in `ubuntu:26.04` (amd64, root, the host CA at `/hostca.pem`)
takes minutes, and publishes from a `ganesha-v15.10-1+ezgh5` tag. arm64 builds too, as a
smoke of the packaging, with `snapshot-apt.sh` pointed at `ports.ubuntu.com` (the snapshot
has no arm64); only amd64 is published. The release files hold the source package
(`.dsc`, `.orig.tar.xz`, `.debian.tar.xz`).

Ganesha is LGPL-3.0-or-later and ntirpc BSD-style, and the patch is a contribution to them
under their licenses; `ganesha/debian` is GPL-2.0 like the rest of this repository.

## License

GPL-2.0, see [LICENSE](LICENSE). The patches are contributions to the Linux
kernel under the same license; the QEMU patches are contributions to QEMU, under
GPL-2.0-or-later like the file they change.
