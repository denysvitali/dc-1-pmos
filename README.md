# dc-1-pmos

[![build](https://github.com/denysvitali/dc-1-pmos/actions/workflows/build.yml/badge.svg)](https://github.com/denysvitali/dc-1-pmos/actions/workflows/build.yml)

postmarketOS / Alpine Linux for the Daylight DC-1 tablet (codename `jagar`,
MediaTek MT8781/MT6789). This repository does two things:

1. Documents how to install and run Linux on the DC-1.
2. Builds everything needed to do so — kernel package, device package, rootfs
   image, and a bootable installer image — from pinned sources, on every
   commit, on public GitHub runners.

> **Warning — read before flashing.**
> A green CI build proves the artifacts *compile*, not that they *boot*.
> Every release records `hardware_verified=false`. The DC-1 has **no recovery
> channel without a working kernel**: if you write the wrong partition, there
> is no download mode to save you. The flow below only ever writes `boot_a`
> and `userdata`; never flash `preloader`, `lk`, `dtbo`, `vendor_boot`, or
> the UFS boot LUNs. Flashing is entirely at your own risk.

## Quickstart

Download `installer-boot.img` and `SHA256SUMS` from the
[rolling release](https://github.com/denysvitali/dc-1-pmos/releases),
verify, put the device in fastboot mode (Power + Volume Up at power-on,
`adb reboot bootloader` from stock Android, or `sudo dc1-reboot-fastboot`
from an already-installed postmarketOS), then:

```sh
sha256sum --ignore-missing -c SHA256SUMS
fastboot flash boot_a installer-boot.img && fastboot reboot
```

The device boots into the on-device installer. Tap **Install from network**,
pick a Wi-Fi network, enter a username / password / hostname / timezone, then
**Install now**. The device downloads the release over Wi-Fi, checks every
byte against `SHA256SUMS` before anything becomes mountable, writes the
rootfs, grows it, writes the boot image, and reboots into postmarketOS. On
first boot it installs the desktop apps (Chromium, Ghostty, GNOME apps) from
Alpine.

No Wi-Fi, or want the image from your computer instead? Use the host script
(`installer/host/dc1-install.sh`) over USB — the advanced / fallback path.
The full, explained procedure is in
[docs/installation.md](docs/installation.md); current hardware support is
in [docs/status.md](docs/status.md). The installer's on-screen debug tools
are documented in [docs/debugging.md](docs/debugging.md). If a device ends
up bootlooping before it reaches `fastboot`, see
[docs/preloader-recovery.md](docs/preloader-recovery.md).

## What CI builds

Every push to `main` builds from source and publishes the artifacts to a
rolling prerelease on GitHub, so the latest build is always fetchable:

- `installer-boot.img` — bootable installation-mode image (kernel + minimal
  installer initramfs).
- `jagar-boot.img` — the real boot image for the installed system.
- `jagar-rootfs.ext4.zst` — the postmarketOS root filesystem as a raw ext4
  image (label `jagar-root`), zstd-compressed.
- `jagar-rootfs.tar.gz` — the same rootfs as a tarball.
- The two overlay packages as `.apk` files, a `PROVENANCE` file recording
  exact source pins and `hardware_verified=false`, and `SHA256SUMS` covering
  everything.

No secrets, credentials, or proprietary Android blobs are ever baked into
published artifacts. MT7902 Wi-Fi/Bluetooth firmware comes exclusively from
upstream `linux-firmware` and `wireless-regdb`, pinned by size and SHA-256
(the installer image carries the same pinned pair so it can download the
rootfs over Wi-Fi).

## Repository layout

- `pmaports/device/testing/` — the two postmarketOS packages
  (`device-daylight-jagar`, `linux-postmarketos-mediatek-mt6789`) in upstream
  pmaports layout.
- `scripts/` — pinned-source preparation, rootfs build, artifact export,
  ext4 image creation, `versions.env`, offline tests.
- `installer/` — the installation-mode initramfs and the host-side
  `dc1-install.sh`.
- `boot/` — Android boot-image v4 tooling (`mkboot`, `repack-boot.sh`) that
  owns this device's boot-image invariants.
- `docs/` — installation guide, hardware status, debugging tools, and
  preloader recovery.
- `tools/` — hardware probe tools kept for re-measurement (`i2cbb`).
- `.github/workflows/` — CI.

Sources are pinned by commit in `scripts/versions.env`. The kernel is
[denysvitali/dc-1-linux-kernel](https://github.com/denysvitali/dc-1-linux-kernel),
branch `jagar`.

## Upstreaming

Getting the DC-1 into upstream postmarketOS is a design goal. The packages
under `pmaports/device/testing/` are laid out exactly as they would land in
upstream pmaports, and device-specific installation hacks live in the
installer, not in the packages. When the port is mature enough, the two
packages are meant to be submitted to pmaports as-is.

## License

MIT — see [LICENSE](LICENSE).
