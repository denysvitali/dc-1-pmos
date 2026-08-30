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

The project builds a GNOME Mobile desktop (Wayland/systemd) and a touchscreen
installer: flash one image over fastboot, answer a few questions on the panel,
and the device is designed to download, verify, and install the rest itself.
The installer boot/UI and individual subsystems have hardware evidence; the
complete published-release install through first update does not yet.

> [!CAUTION]
> A green CI build proves the artifacts *compile*, not that they *boot*.
> Releases record `hardware_verified=false`: individual subsystems are
> heavily measured on real hardware (see the support summary below and the
> [verification ledger](docs/verification.md)). No published release has yet
> completed the full install → provisioning → first boot → update path
> end-to-end, and no external-user install is on record.
> Flashing is at your own risk.
>
> The DC-1 has **no general recovery channel without a working kernel** —
> the authenticated preloader accepts no arbitrary download agent — so the
> partition rules are absolute:
>
> - This guide only ever writes **`boot_a`** and **`userdata`**, plus the A/B
>   boot-control bytes in `misc` through `fastboot set_active a` and the
>   installed slot manager. Those writes are redoable. LK's A/B fallback
>   covers a pre-kernel slot failure; once Linux starts, the reachability
>   watchdog can return an unreachable boot to LK fastboot.
> - **Never** write `preloader`, `lk`, `dtbo`, `vendor_boot`, or the UFS
>   boot LUNs. `lk` and `dtbo` are signature-checked; one bad write marks
>   the slot dead before Linux starts, with no way back over USB.
>
> There is currently **no official, supported way to return the tablet
> completely to stock** after installing Linux. You can make raw backups of
> `dtbo_a`, `dtbo_b`, `boot_a`, and `boot_b` before starting and reflash them
> later, but that is not necessary for this installation and does not amount
> to a complete factory restore.

## Hardware support at a glance

Detailed measurements and dates live in the linked subsystem records under
[`docs/hw/`](docs/hw/) and in the [verification ledger](docs/verification.md).
The [hardware reference](docs/hardware.md) explains the boot/update safety
model and records sourced board specifications.

| Area | State | Notes |
| --- | --- | --- |
| Desktop / fresh install | 🟡 | GNOME Mobile runs on the converged development unit; fresh published-rootfs delivery, provisioning, and first login remain unverified |
| Display & touch | ✅ | 1200×1600 @ 60 Hz over DSI, GPU-accelerated (Panfrost), reliable blank/wake |
| Pen digitizer | 🟡 | Wacom EMR events, pressure, and barrel button verified; mid-hover eraser flips and edge alignment await a final hands-on pass |
| Screen auto-rotation | 🟡 | Accelerometer/SensorProxy plus bridge-driven Mutter transforms are live and honor rotation lock; native Mutter claim/animation and four-pose sign-off remain |
| Wi-Fi | ✅ | MT7902 on mainline `mt7921s`; cold-boot association works (the hardware is Wi-Fi 6, but negotiated HE mode is not recorded) |
| Bluetooth | 🟡 | Controller-up via the repair path is verified; fresh-boot no-repair setup, active discovery, pairing, and A2DP remain |
| Audio | ✅ | Stereo speaker playback and DMIC capture verified; no headphone jack (hardware) |
| Front light | ✅ | White + amber channels, PWM-free dimming, warmth slider in quick settings |
| Buttons | 🟡 | Power/volume event paths work; Quick Action / Back remaps are shipped but still need on-device confirmation |
| Storage & microSD | ✅ | UFS internal storage; microSD slot works |
| Battery & charging | 🟡 | USB-C PD negotiates (12 V PDO verified); Charging Profile selects 3.15 A or 2.00 A; charge % is restored only after a valid clean reboot within ten minutes; pack-temperature control is unavailable |
| USB-C data | 🟡 | USB 2.0 ACM serial works; ECM is configured device-side but host Ethernet/SSH remains unverified, and host mode is partial. No SuperSpeed, video Alt Mode, or Thunderbolt |
| Suspend/sleep | 🚧 | One pre-pin s2idle cycle completed; a current-build cycle and wake path remain unverified, so sleep targets stay masked |
| Ambient light / proximity sensor | ❌ | An unidentified MN29-family part ACKs at `0x49`; protocol and driver remain unknown |
| Gyro, magnetometer, cellular, GPS, cameras | ❌ | Not fitted/exposed on this hardware |

✅ works · 🟡 works, with stated caveats · 🚧 being worked on · ❌ unavailable

## Installing

Two paths lead to the same system:

1. **On-device installer (recommended)** — needs a computer with `fastboot`
   for a brief flashing sequence, then Wi-Fi. Everything else happens on the
   tablet's touchscreen.
2. **USB install from a computer (fallback)** — a host script streams the
   image and answers over the cable when there is no Wi-Fi. See
   [Install from a computer](docs/installation.md#install-from-a-computer-advanced--fallback).

Both paths are implemented and offline-tested. The complete flow from a
published release has not yet been hardware-verified end-to-end.

What you need either way: a DC-1, a USB cable, `fastboot` on the computer
(package `android-tools`), and `installer-boot.img` + `SHA256SUMS` from the
[rolling release](https://github.com/denysvitali/dc-1-pmos/releases).
Verify the download:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

### Walkthrough

**1. Unlock the bootloader.** In stock Android, tap **Settings > About
tablet > Build number** seven times to enable Developer Options, then enable
**OEM unlocking** under **Settings > System > Developer options**. Reboot to
fastboot and check the current state:

```sh
fastboot getvar unlocked
```

> [!WARNING]
> If the command reports `no`, copy off anything important before running
> `fastboot flashing unlock` and confirming on the tablet. **Unlocking erases
> all user data.**

**2. Enter fastboot mode.** Power off, then hold **Power + Volume Up**
until the bootloader menu appears, and select fastboot. From stock Android
with USB debugging you can instead run `adb reboot bootloader`; from an
already-installed postmarketOS, `sudo dc1-reboot-fastboot`. Confirm the
host sees the device: `fastboot devices`.

**3. Flash the installer, select its slot, and reboot.**

```sh
fastboot flash boot_a installer-boot.img
fastboot set_active a
fastboot reboot
```

> [!IMPORTANT]
> Dual booting is not currently supported. The slot containing Linux must be
> the active slot: because this example flashes `boot_a`, it explicitly
> selects slot A with `fastboot set_active a` before rebooting. If a future
> procedure uses `boot_b`, the corresponding command is `fastboot set_active
> b`.

> [!NOTE]
> Tethered `fastboot boot` is unverified on this bootloader, which is why the
> image is flashed. The panel comes up with the installer menu after reboot.

**4. Answer the installer.** Tap **Install from network**, pick a Wi-Fi
network (or type an SSID), enter the passphrase, then set a username,
password, hostname, and timezone. **Install now** warns that the Linux
data partition will be erased, then the device downloads the release over
TLS, checks every byte against `SHA256SUMS` before anything becomes
mountable, writes the rootfs, applies your answers (the password is hashed
on-device; the cleartext is never stored), writes the real boot image to
`boot_a`, and reboots.

> [!TIP]
> If image transfer is interrupted, run the flow again: the ext4 superblock is
> committed only after the full image verifies. Provisioning happens after
> that commit; if it fails later, rerunning the installer is still supported.

**5. First boot.** The installed system downloads the desktop app set
(Chromium, Ghostty, GNOME Console/Calculator/Text Editor, Nautilus) once
from Alpine, then logs you in.

The full procedure — including the USB fallback, pre-made answers, and
what each menu option does — is in
[docs/installation.md](docs/installation.md).

> [!NOTE]
> For community support, I will try to be reachable in
> [`#linux-on-dc-1`](https://discord.gg/jNGuzVYk6F) in the Daylight Hacker
> Wiki Community on Discord. This project is **not officially supported by
> Daylight**, and you are expected to understand the flashing process and its
> risks rather than rely on step-by-step recovery help.

## Living with it

- **Updates are automatic.** `dc1-update.timer` runs `apk upgrade` shortly
  after boot and weekly, converging the device on the rolling release —
  kernel updates included (they arm the inactive A/B slot and apply on the
  next reboot). No reflashing for userland fixes. Toggle it in **Settings →
  Charging Profile** (or use `/var/lib/dc1/no-auto-update`).
- **Charging while powered off is experimental.** The shipped logic is
  designed so plugging USB power into a cleanly powered-off DC-1 boots a
  silent headless charging mode instead of the
  desktop — unplug to power it off again, press power briefly to continue
  to the desktop. The real charger-insert code and exit cycle still need one
  calibration session; darkness alone is not proof of charging. Toggle the
  feature in **Settings → Charging Profile**;
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
- **Normal desktop boots expose the recovery channels.** SSH listens on port
  22 over configured networks; USB SSH/ECM still awaits a host-side test. Raw
  TCP 4444 and two USB serial ports are cable-only. Charging mode stops sshd
  and Wi-Fi but keeps the raw USB channels. The full exposure matrix is in
  [docs/security.md](docs/security.md); the
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
  installed before the signed package repository existed can be repaired
  manually with the release's `dc1-repair-apk.sh`; see
  [docs/installation.md](docs/installation.md#updating-an-old-pre-august-2026-installation).
- **Stranded somewhere unexpected** — as long as `fastboot devices` shows
  the device, you can always reflash `boot_a`. A failed boot is annoying,
  not fatal.

## Release contents

Every successful push build on `main` republishes the rolling prerelease:

- `installer-boot.img` — the installation-mode boot image;
- `jagar-boot.img` — the installed system's boot image;
- `jagar-rootfs.ext4.zst` / `.tar.gz` — the root filesystem (ext4, label
  `jagar-root`);
- the three overlay packages as `.apk`, plus the signed
  `APKINDEX.tar.gz`;
- `dc1-install.sh` and `dc1-repair-apk.sh` (host-side helpers),
  `dc1-apk.rsa.pub`, `PROVENANCE`, `SOURCES`, `FILES.tsv`, the exact installed
  package inventory `PACKAGES.tsv`, and one `SHA256SUMS` covering all of it.

Release-level `PROVENANCE` records exact source pins, the release commit,
`flash_method=dc1-installer`, both boot images' inclusion, and honestly says
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
