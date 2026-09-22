# Building from pinned sources

This repository builds four aarch64 packages (kernel, kernel modules, device, and Mutter)
from three recipes,
a GNOME Mobile rootfs, and installer/system boot images. The
[build workflow](../.github/workflows/build.yml) is the complete release recipe.
Local rootfs export is an intermediate output, not a complete installer release.
For kernel-only work on the DC-1, use [local kernel development](kernel-development.md).

## Host and dependencies

Use a Linux build host with enough disk space for pmbootstrap chroots, kernel
objects, caches, and rootfs exports. CI uses `ubuntu-24.04-arm` for native
aarch64 builds and `ubuntu-24.04` for offline verification. Prefer CI for full
builds when working on the tablet; do not consume its recovery system's free
space or assume unattended `sudo` is available.

The rootfs path needs Git, Python 3, curl, tar, zstd, checksum/coreutils tools,
e2fsprogs, and privileges for pmbootstrap's chroots. Pigz speeds up rootfs
archive creation. The workflow installs the remaining host packages explicitly.
The kernel's clang/LLVM 20 toolchain is installed inside pmbootstrap; it is
separate from the host compiler used for the small DT swap stub.

Boot-image assembly additionally uses a C compiler with static linking, Go
(the version is declared in `installer/gotools/go.mod`), lz4, cpio, xz,
binutils, and dtc (`fdtget`/`fdtput`). The stub requires clang, LLD, and
llvm-objcopy. CI explicitly uses LLVM 19 for the hardware-proven stub; the
Makefile defaults to Alpine's LLVM 20 path. Root is needed for initramfs device
nodes. The installer builder downloads its pinned Alpine busybox-static;
Ubuntu's busybox-static lacks required applets.

## Source and package identity

[`scripts/versions.env`](../scripts/versions.env) pins the pmaports,
pmbootstrap, and public kernel commits, plus `SOURCE_DATE_EPOCH`.
Do not substitute branch tips to reproduce a release. The build writes its
source inventory to `WORK/SOURCES`.

Three local recipes live under `pmaports/device/testing/`. Preparation copies
the device and kernel overlays to upstream `device/testing/`, and Mutter to
`extra-repos/systemd/mutter-mobile`. Every recipe or effective package-input
change needs a `pkgrel` bump: caches deliberately reuse an unchanged package
version, and releases refuse to replace an existing APK filename with different
bytes. Restored pmbootstrap signing caches require the public-key handoff in
`scripts/restore-local-apk-key.sh`; keep that step when reproducing CI caches.

## Build and export the rootfs

Run from the repository root. `work/` and `out/` are ignored build directories;
`out/` must be empty before export.

```sh
sh scripts/prepare.sh work/postmarketos
sh scripts/build-rootfs.sh --validate-only --verify-sources work/postmarketos out
sh scripts/build-rootfs.sh work/postmarketos out
```

The validation step fetches pinned sources and validates package metadata and
checksums; it still needs network access. The full builder prepares sources
again as needed, builds packages, and installs with
`--no-image --no-sshd --no-firewall --no-recommends` before exporting.
It never selects a device, flashes a slot, or writes a block-device target.

The rootfs export contains:

- `jagar-rootfs.tar.gz` and `jagar-rootfs.ext4.zst` (ext4 label `jagar-root`);
- exact-version copies of the four overlay APKs;
- kernel and DTB inputs under `boot/`;
- `FILES.tsv`, `PACKAGES.tsv`, `SOURCES`, `PROVENANCE`, and `SHA256SUMS`.

At this stage provenance says `flash_method=none`,
`boot_image_included=false`, and `deployable=rootfs-image-only`.
The build-time placeholder account must be replaced during provisioning; this
export is not an already-provisioned system to expose on a network.

## Build the two boot images

[`installer/build.sh`](../installer/build.sh) builds both initramfs images.
Supplying `KERNEL_IMAGE` requires `KERNEL_DTB`; both installer and installed
system images carry the [dtbswap payload](../boot/dtbswap/README.md). Use the
kernel and matching DTB exported by the same rootfs build. For example, with
absolute paths to the standard exported filenames:

```sh
sudo env KERNEL_IMAGE="$(pwd)/out/boot/Image.gz" \
  KERNEL_DTB="$(pwd)/out/boot/mt8781-daylight-jagar.dtb" sh installer/build.sh
```

On Ubuntu with the CI stub toolchain, add
`DTBSWAP_LLVM=/usr/lib/llvm-19/bin/ DTBSWAP_LLD=/usr/bin/ld.lld-19`
to that `env` invocation. On Alpine the default LLVM 20 paths apply.

The kernel APK requires its exact-version `-modules` APK; both are exported
and included in the signed index. Gate A also compares module bytes and kmod
metadata against the rootfs. Optional docking drivers remain modules, while
the USB controller and recovery gadget stay built in.

When the rootfs ships kernel modules, also set `MODDIR` to its matching modules
directory as the workflow does. Only the explicit legacy gadget module
allowlist enters the installer ramdisk; dock modules stay on the rootfs.
Outputs are under `installer/out/`, including
`installer-boot.img` and `jagar-boot.img`. Downloaded inputs are cached in
`installer/dl/`; temporary staging lives in `installer/root/`.
See the [installer implementation guide](../installer/README.md#building)
for input validation and firmware provenance.

The image contract is Android header v4, gzip-compressed DT swap payload,
legacy-frame LZ4 ramdisk, and the recorded nonzero 4096-byte AVB0 signature
page. `vendor_boot` is never built or flashed for DT delivery. Low-level packers
can produce images outside this contract; use the installer builder for release
images and preserve the workflow's payload and kernel-identity checks.

## Release assembly and verification

CI combines the rootfs export with both boot images, host helpers, and the
public APK signing key. Publishing runs sign `APKINDEX.tar.gz` using the CI-only
`DC1_APK_PRIVATE_KEY`, then write a final `SHA256SUMS` covering the release.
Pull requests upload an artifact without the signed index and receive no
signing secret. A default-branch push publishes the rolling `latest`
prerelease; manual dispatch can publish a `pmos-v*` prerelease tag.

Release provenance changes to `flash_method=dc1-installer`,
`boot_image_included=true`, and `deployable=complete-installer-release`, with
the full release commit. CI proves that the kernel APK, rootfs kernel, and both
boot images contain the same kernel. Hardware acceptance is separate:
`hardware_verified=false` remains until the published install/update cycle is
tested and recorded in the [verification ledger](verification.md).

Run the [contribution validation gates](../CONTRIBUTING.md#validation-gates)
for local changes. Keep build outputs, signing material, device captures, and
credentials out of commits. Neither private repositories nor stock Android
firmware blobs are needed for this build.
