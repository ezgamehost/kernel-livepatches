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
[`qemu/patches`](qemu/patches), as `1:10.2.1+ds-1ubuntu3.2+ezgh1`: the packages a
hypervisor installs from the `qemu` source (`qemu-system-x86`, `-common`, `-gui`,
`-modules-opengl`, `-modules-spice`, `qemu-block-extra`, `qemu-utils`). Ubuntu's
`qemu-system-data` stays as it is. Hosts get them as exact pins in their OS release.

- [`0001`](qemu/patches/0001-block-throttle-count-a-discard-as-one-request-not-by.patch):
  the throttle filter charged a discard's full length to the group's bps buckets, so a
  guest trimming free space used up its volume's MB/s budget and its writes waited for
  seconds behind the trims. A discard now counts as one request of no bytes: still
  against the IOPS limits, never against the bps ones.

[`qemu/check.sh`](qemu/check.sh) tests this with `qemu-io` over a `null-co` disk (no
guest or KVM): a 4 KiB write after a 100 MiB discard through a 10 MB/s group must
finish in under 1 s (stock QEMU: 10.4 s), and 30 discards through a 10 IOPS group must
take at least 1.5 s. Run it on a host after an upgrade; the build runs it against the
built `qemu-utils` before anything is published.

`OUT=out qemu/build.sh` in `ubuntu:26.04` (amd64, root, the host CA at `/hostca.pem`)
takes hours, since Ubuntu's rules build every target, and publishes from a
`qemu-v10.2.1+ds-1ubuntu3.2+ezgh1` tag. The release files hold the source package
(`.dsc`, `.debian.tar.xz`, the patches); its `qemu_10.2.1+ds.orig.tar.xz` is
Ubuntu's, from the same snapshot.

A running VM keeps the QEMU it started with until it restarts or migrates.

## License

GPL-2.0, see [LICENSE](LICENSE). The patches are contributions to the Linux
kernel under the same license; the QEMU patches are contributions to QEMU, under
GPL-2.0-or-later like the file they change.
