# kernel-livepatches

Linux livepatch modules for EZGH Cloud hosts. Each module is built for one exact
stock Ubuntu kernel and is published as a signed apt package.

| Module | Kernel | Package |
| --- | --- | --- |
| `livepatch-xfrm-pcpu` (sysfs `livepatch_xfrm_pcpu`) | `Ubuntu 7.0.0-38.38-generic 7.0.14` | `ezgh-livepatch-xfrm-pcpu-7.0.0-38-generic` 1.0.0 |

## The bugs

Both are in `net/xfrm/xfrm_state.c` per-CPU SA handling (RFC 9611), added by
1ddf9916ac09 ("xfrm: Add support for per cpu xfrm state handling."). Both
patches carry that `Fixes:` tag.

- [`patches/0001`](patches/0001-xfrm-state-use-the-fallback-SA-while-a-per-CPU-acqui.patch):
  while a per-CPU acquire is pending, `xfrm_state_find()` ignores the valid
  fallback SA and returns `-EAGAIN`, so packets on that CPU are dropped until the
  key manager installs the CPU's SA. Sent to the ipsec tree.
- [`patches/0002`](patches/0002-xfrm-state-prefer-the-CPU-s-own-SA-over-a-newer-fall.patch):
  `xfrm_state_look_at()` lets a fallback SA added after the CPU's own SA replace
  it as best, which starts a duplicate acquire and leaves the CPU's SA unused. Not
  yet sent upstream and has no `Signed-off-by` yet.

Both were written against ipsec master (base 835912998ca5) and apply unchanged
to the Ubuntu 7.0.0-38.38 tree: identical context, offset -24 lines, no fuzz.
The patch files are byte-for-byte the ones submitted or prepared for upstream.

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
- Builder: the tree's own `scripts/livepatch/klp-build`, run with `--no-replace`
  so that loading this module never displaces another livepatch.
- Debug info stays on. The stock config uses `CONFIG_GENDWARFKSYMS`, so the
  modversion CRCs come from DWARF. The build does not run `debian/rules`, so no
  dbgsym or other Ubuntu packages are produced.

## Static compatibility check

[`check.sh`](check.sh) runs as part of every build and fails it on any mismatch.
Its output is published as `static-check.txt`.

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
apt-get install ezgh-livepatch-xfrm-pcpu-7.0.0-38-generic
```

Compare the key with [`keys/apt.asc`](keys/apt.asc) (fingerprint
`B42D D9D0 2D37 8220 233C  E607 5398 FA60 DA2D 5332`).

- The module is installed in `/usr/lib/modules/7.0.0-38-generic/updates/ezgh/`.
  `/usr/lib/modules-load.d/livepatch-xfrm-pcpu.conf` loads it at boot.
- postinst runs `depmod`. It loads the patch immediately only if `uname -r` is
  `7.0.0-38-generic` and `/proc/version_signature` is exactly
  `Ubuntu 7.0.0-38.38-generic 7.0.14`. It then waits up to 120 s for
  `/sys/kernel/livepatch/livepatch_xfrm_pcpu/transition` to reach 0, and fails
  the install if it does not.
- The module is not signed with a key that the kernel trusts. This kernel does
  not enforce module signatures, so it loads with the `E` (unsigned) and `K`
  (livepatch) taint flags.

Check that the patch is active:

```sh
cat /sys/kernel/livepatch/livepatch_xfrm_pcpu/enabled     # 1
cat /sys/kernel/livepatch/livepatch_xfrm_pcpu/transition  # 0
```

## Uninstall

```sh
apt-get remove ezgh-livepatch-xfrm-pcpu-7.0.0-38-generic
```

prerm writes 0 to `enabled` and waits up to 120 s for the patch to go away. It
then unloads the module, and fails loudly if either step does not complete.

## Verify a download

There are no GitHub Releases. The apt repository and the per-version files on
get.ezghcloud.com are the distribution:

```
https://get.ezghcloud.com/kernel-livepatches/files/v1.0.0/
  livepatch-xfrm-pcpu.ko  ezgh-livepatch-xfrm-pcpu-7.0.0-38-generic_1.0.0_amd64.deb
  SHA256SUMS  SHA256SUMS.asc  BUILDINFO  static-check.txt
  config-7.0.0-38-generic  0001-*.patch  0002-*.patch
```

```sh
gpg --dearmor < keys/apt.asc > apt.gpg
gpgv --keyring ./apt.gpg SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
gpgv --keyring ./apt.gpg InRelease   # .../kernel-livepatches/apt/dists/resolute/InRelease
```

`SHA256SUMS` also covers the stock config and both patches, so the inputs can be
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

## License

GPL-2.0, see [LICENSE](LICENSE). The patches are contributions to the Linux
kernel under the same license.
