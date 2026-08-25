# postmarketOS for Daylight DC-1

[![build](https://github.com/denysvitali/dc-1-pmos/actions/workflows/build.yml/badge.svg)](https://github.com/denysvitali/dc-1-pmos/actions/workflows/build.yml)

A mainline-Linux port of postmarketOS / Alpine Linux for the
[Daylight DC-1](https://daylightcomputer.com) — the 10.5″ reflective-LCD
tablet with a Wacom pen — codename `jagar`, MediaTek Helio G99 (MT8781).

This repository does two things:

1. Documents how to install and run Linux on the DC-1.
2. Builds everything needed to do so — kernel package, device package,
   compositor package, root filesystem, and a bootable installer image —
   from pinned sources, on every commit, on public GitHub runners.

The end result is a GNOME Mobile desktop (Wayland/systemd) that installs
from a touchscreen wizard: flash one image over fastboot, answer a few
questions on the panel, and the device downloads, verifies, and installs
the rest itself.

> **Warning — read before flashing.**
> A green CI build proves the artifacts *compile*, not that they *boot*.
> Releases record `hardware_verified=false`: individual subsystems are
> heavily measured on real hardware ([docs/status.md](docs/status.md)),
> but nobody has executed this release's install flow outside this
> repository yet. Flashing is at your own risk.
>
> The DC-1 has **no general recovery channel without a working kernel** —
> the authenticated preloader accepts no arbitrary download agent — so the
> partition rules are absolute:
>
> - This guide only ever writes **`boot_a`** and **`userdata`** (plus the
>   A/B boot-control bytes in `misc` once Linux is running). Those writes
>   are redoable: if a flashed image fails to boot, the watchdog returns
>   the device to LK fastboot and you reflash.
> - **Never** write `preloader`, `lk`, `dtbo`, `vendor_boot`, or the UFS
>   boot LUNs. `lk` and `dtbo` are signature-checked; one bad write marks
>   the slot dead before Linux starts, with no way back over USB.

## Hardware support at a glance

Details, measurements, and dates for every row:
[docs/status.md](docs/status.md).

| Area | State | Notes |
| --- | --- | --- |
| Display & touch | ✅ | 1200×1600 @ 60 Hz over DSI, GPU-accelerated (Panfrost), reliable blank/wake |
| Pen digitizer | ✅ | Wacom EMR: pressure, barrel button, eraser end (in tablet-aware apps); edge-alignment refit awaits a final hands-on pass |
| Screen auto-rotation | 🟡 | Accelerometer-driven end to end; the on-glass tilt matrix still awaits its hands-on test |
| Wi-Fi | ✅ | MT7902, mainline `mt7921s`, Wi-Fi 6 |
| Bluetooth | 🚧 | Controller comes up reliably; pairing/streaming not yet exercised |
| Audio | ✅ | Stereo speakers, stereo mic capture; no headphone jack (hardware) |
| Front light | ✅ | White + amber channels, PWM-free dimming, warmth slider in quick settings |
| Buttons | ✅ | Phone-like power key; volume; Quick Action / Back Button, remappable in GNOME Settings |
| Storage & microSD | ✅ | UFS internal storage; microSD slot works |
| Battery & charging | 🟡 | USB-C PD negotiates (12 V PDO verified); charging defaults conservative (~22 %/h), tunable toward ~40 %/h via sysfs; charge % is real coulomb-counting but re-seeds from voltage at every boot |
| USB-C networking | 🚧 | Serial console works, USB ethernet comes up; SSH from a host end-to-end still to be proven |
| Suspend/sleep | ❌ | Unavailable by design — the power key blanks instead; see [Living with it](#living-with-it) |
| Ambient light / proximity sensor | ❌ | Part identified on the bus, no mainline driver yet |
| Gyro, magnetometer, cellular, GPS, cameras | ❌ | Not fitted/exposed on this hardware |

✅ works · 🟡 works, with stated caveats · 🚧 being worked on · ❌ unavailable

## Installing

Two paths lead to the same system:

1. **On-device installer (recommended)** — needs a computer with `fastboot`
   for one command, then Wi-Fi. Everything else happens on the tablet's
   touchscreen.
2. **USB install from a computer (fallback)** — a host script streams the
   image and answers over the cable when there is no Wi-Fi. See
   [Install from a computer](docs/installation.md#install-from-a-computer-advanced--fallback).

What you need either way: a DC-1, a USB cable, `fastboot` on the computer
(package `android-tools`), and `installer-boot.img` + `SHA256SUMS` from the
[rolling release](https://github.com/denysvitali/dc-1-pmos/releases).
Verify the download:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

### Walkthrough

**1. Enter fastboot mode.** Power off, then hold **Power + Volume Up**
until the bootloader menu appears, and select fastboot. From stock Android
with USB debugging you can instead run `adb reboot bootloader`; from an
already-installed postmarketOS, `sudo dc1-reboot-fastboot`. Confirm the
host sees the device: `fastboot devices`.

**2. Flash the installer and reboot.**

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot
```

The panel comes up with the installer menu. (Tethered `fastboot boot` is
unverified on this bootloader, which is why the image is flashed.)

**3. Answer the installer.** Tap **Install from network**, pick a Wi-Fi
network (or type an SSID), enter the passphrase, then set a username,
password, hostname, and timezone. **Install now** warns that the Linux
data partition will be erased, then the device downloads the release over
TLS, checks every byte against `SHA256SUMS` before anything becomes
mountable, writes the rootfs, applies your answers (the password is hashed
on-device; the cleartext is never stored), writes the real boot image to
`boot_a`, and reboots.

An interrupted install loses nothing: nothing half-written is ever left
mountable, so run the flow again.

**4. First boot.** The installed system downloads the desktop app set
(Chromium, Ghostty, GNOME Console/Calculator/Text Editor, Nautilus) once
from Alpine, then logs you in.

The full procedure — including the USB fallback, pre-made answers, and
what each menu option does — is in
[docs/installation.md](docs/installation.md).

## Living with it

- **Updates are automatic.** `dc1-update.timer` runs `apk upgrade` shortly
  after boot and weekly, converging the device on the rolling release —
  kernel updates included (they arm the inactive A/B slot and apply on the
  next reboot). No reflashing for userland fixes. Opt out with
  `touch /var/lib/dc1/no-auto-update`.
- **Charging while powered off.** Plugging USB power into a cleanly
  powered-off DC-1 boots a silent headless charging mode instead of the
  desktop — unplug to power it off again, press power briefly to continue
  to the desktop. Opt out with `touch /var/lib/dc1/no-charging-mode`;
  details in
  [docs/installation.md](docs/installation.md#charging-mode). For charge
  rates, the battery percentage's caveats, and the fast-charge lever,
  see [docs/power.md](docs/power.md).
- **Offline use needs one setting.** Because a boot that succeeds but can't
  be reached would otherwise be unrecoverable on a device with no serial
  header, `dc1-boot-watchdog` reboots the device after 10 unreachable
  minutes (escalating to fastboot only if consecutive boots stay
  unreachable). If you will use the tablet away from every network, opt
  out once: `sudo touch /etc/dc1/boot-watchdog.disabled`.
- **Debug channels are always up.** SSH on port 22 (reachable over Wi-Fi
  or the USB cable), plus a raw root shell on TCP 4444 and two USB serial
  ports (USB cable only — those bind to the USB interface and are never
  exposed over Wi-Fi). The full exposure matrix, including how to close
  each channel, is in [docs/security.md](docs/security.md); the
  installer additionally offers read-only on-screen debug tools
  ([docs/debugging.md](docs/debugging.md)).

## When things go wrong

- **Install fails partway** — rerun it; see above.
- **The installer misbehaves** — its Debug tools entry collects logs and
  partition checksums read-only; pull them over USB per
  [docs/debugging.md](docs/debugging.md).
- **Bootloop before fastboot is reachable** — last-resort page:
  [docs/preloader-recovery.md](docs/preloader-recovery.md). It requires
  proprietary vendor files this project does not ship.
- **An old installation can't upgrade** (`UNTRUSTED signature`) — devices
  installed before the signed package repository existed repair themselves
  with the release's `dc1-repair-apk.sh`; see
  [docs/installation.md](docs/installation.md#updating-an-old-pre-august-2026-installation).
- **Stranded somewhere unexpected** — as long as `fastboot devices` shows
  the device, you can always reflash `boot_a`. A failed boot is annoying,
  not fatal.

## Release contents

Every push to `main` rebuilds and republishes the rolling prerelease:

- `installer-boot.img` — the installation-mode boot image;
- `jagar-boot.img` — the installed system's boot image;
- `jagar-rootfs.ext4.zst` / `.tar.gz` — the root filesystem (ext4, label
  `jagar-root`);
- the three overlay packages as `.apk`, plus the signed
  `APKINDEX.tar.gz`;
- `dc1-install.sh` and `dc1-repair-apk.sh` (host-side helpers),
  `dc1-apk.rsa.pub`, `PROVENANCE`, `SOURCES`, `FILES.tsv`, and one
  `SHA256SUMS` covering all of it.

`PROVENANCE` records exact source pins and honestly says
`hardware_verified=false`. No secrets, credentials, or proprietary Android
blobs are ever baked into published artifacts: MT7902 Wi-Fi/Bluetooth
firmware and `regulatory.db` come from upstream `linux-firmware` /
`wireless-regdb`, fetched at build time under exact size and SHA-256 pins.

## Building from source

Sources are pinned by commit in `scripts/versions.env`
(`PMAPORTS_COMMIT`, `PMBOOTSTRAP_COMMIT`, `KERNEL_COMMIT`,
`SOURCE_DATE_EPOCH`). The kernel source is
[denysvitali/dc-1-linux-kernel](https://github.com/denysvitali/dc-1-linux-kernel),
branch `jagar`.

- `scripts/prepare.sh WORK` fetches the pinned inputs and stages the local
  pmaports overlays.
- `scripts/build-rootfs.sh WORK OUTPUT` builds the three aarch64 packages
  and a non-deploying pmbootstrap rootfs, then exports artifacts.
- `installer/build.sh` creates both initramfs images and — given
  `KERNEL_IMAGE` and the mandatory `KERNEL_DTB` — both dtbswap Android
  boot images.
- `scripts/verify.sh` and `installer/tests/run-tests.sh` are the offline
  gates; `.github/workflows/build.yml` runs them plus a native arm64 build
  on every push and PR.

Repository layout:

- `pmaports/device/testing/` — three postmarketOS recipes in upstream
  layout: `device-daylight-jagar`,
  `linux-postmarketos-mediatek-mt6789`, and `mutter-mobile` (staged by
  `prepare.sh` into the upstream systemd extra-repo location pmbootstrap
  expects).
- `installer/` — the installation-mode initramfs (C entry points, POSIX
  shell, a CGO-free Go multi-call binary), the host-side fallback
  installer, and offline tests.
- `boot/` — Android boot-image v4 tooling (`mkboot`, `repack-boot.sh`)
  and the freestanding `dtbswap` DT handoff stub. The kernel device tree
  does **not** come from `vendor_boot`: LK builds its tree from signed
  partitions we cannot replace, so the stub inside our (unsigned) boot
  image swaps in the mainline DTB at handoff — fail-safe back to LK's
  tree. See [boot/dtbswap/README.md](boot/dtbswap/README.md).
- `docs/` — installation, hardware status, debugging, preloader recovery.
- `tools/` — hardware probe utilities retained for re-measurement.

## Upstreaming

Getting the DC-1 into upstream postmarketOS is a design goal. The packages
under `pmaports/device/testing/` are laid out exactly as they would land
upstream, and device-specific installation policy lives in the installer
and build scripts, not in the APKBUILDs. When the port is mature enough,
the packages are meant to be submitted as-is; what still separates the
port from that — including the open hardware-verification checklist —
is tracked in [docs/roadmap.md](docs/roadmap.md), with the
per-subsystem verification ledger in
[docs/verification.md](docs/verification.md).

## License

MIT — see [LICENSE](LICENSE).
