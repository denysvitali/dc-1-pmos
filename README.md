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

That is all the computer does. The device's own display and touchscreen
take it from there: pick your Wi-Fi network on the touch keyboard, enter
username / password / hostname / timezone, and the installer downloads the
rootfs from the rolling release, verifies every byte against `SHA256SUMS`
before anything becomes mountable, provisions it (the password is hashed
on-device), writes the verified real boot image to `boot_a`, and reboots
into postmarketOS.

No Wi-Fi? The USB fallback (`installer/host/dc1-install.sh`) streams the
rootfs from a Linux host over USB networking with the same fail-closed
verification. The full, explained procedure is in
[docs/installation.md](docs/installation.md); current hardware support is
in [docs/status.md](docs/status.md).

## Try the setup in your browser

The first-boot onboarding — Wi-Fi, username, password, hostname, timezone —
is a Flutter app that runs on the device. The same source compiles to the
web, so an interactive preview of the exact screens is published from
`main`:

<https://denysvitali.github.io/dc-1-pmos/>

It runs the real onboarding code in the browser (with an in-browser stand-in
for the backend), so you can click through Wi-Fi setup and account creation
before flashing anything.

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
- `docs/` — installation guide and hardware status.
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
