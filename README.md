# postmarketOS for Daylight DC-1

[![build](https://github.com/denysvitali/dc-1-pmos/actions/workflows/build.yml/badge.svg)](https://github.com/denysvitali/dc-1-pmos/actions/workflows/build.yml)

A mainline Linux port of postmarketOS / Alpine Linux for the Daylight DC-1
(`jagar`, MediaTek MT8781 / Helio G99), with GNOME Mobile on Wayland and a
touchscreen installer. Public CI builds the kernel, device and compositor
packages, root filesystem, and both boot images from pinned sources.

**Start here:** [Installation](docs/installation.md) ·
[Downloads](https://github.com/denysvitali/dc-1-pmos/releases/latest) ·
[Documentation](docs/README.md) · [Contributing](CONTRIBUTING.md)

> [!CAUTION]
> This is an experimental port. Individual subsystems have hardware evidence,
> but the complete published-release install → provisioning → first login →
> first update path remains unverified. Releases record
> `hardware_verified=false`; successful CI does not prove booting.
>
> Installation erases `userdata`. The supported initial installation writes
> only `boot_a`, `userdata`, and required A/B boot-control data in `misc`.
> Installed kernel updates use the inactive boot slot with A/B fallback.
> **Never flash `preloader`, `lk`, `dtbo`, `vendor_boot`, or UFS boot LUNs.**
> There is no general recovery channel if the boot chain is damaged, and no
> supported complete factory-restore procedure. Read the
> [installation and recovery limits](docs/installation.md#recovery-notes)
> before flashing.

## Installing

Follow the [installation guide](docs/installation.md) for prerequisites,
bootloader unlocking, checksum verification, and the exact flashing sequence.

1. Download and verify `installer-boot.img` and `SHA256SUMS` from one release.
2. Flash the installer to `boot_a`, select slot A, and reboot using fastboot.
3. Use **Install from network** on the tablet to configure Wi-Fi and your
   account, then download and install the system.

The [Linux host installer](docs/installation.md#install-from-a-computer-advanced--fallback)
provides a USB fallback when Wi-Fi or the touch UI is unavailable. Both paths
are implemented and offline-tested; neither has completed the published-release
acceptance cycle on record. Dual boot and tethered `fastboot boot` are not
supported installation paths.

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
- **Offline use is supported.** Network loss does not trigger automatic reboots.
- **Normal desktop boots expose the recovery channels.** SSH listens on port
  22 over configured networks; USB SSH/ECM still awaits a host-side test. Raw
  TCP 4444 and two USB serial ports are cable-only. Charging mode stops sshd
  and Wi-Fi but keeps the raw USB channels. The full exposure matrix is in
  [docs/security.md](docs/security.md); the
  installer additionally offers read-only on-screen debug tools
  ([docs/debugging.md](docs/debugging.md)).

## When things go wrong

| Problem | Next step |
| --- | --- |
| Installation or provisioning fails | Rerun the installer; see [progress and debugging](docs/installation.md#watching-progress-and-debugging). Installation replaces the existing data. |
| Installer or desktop diagnostics needed | Use [debugging](docs/debugging.md) and review the [debug-channel exposure](docs/security.md) before attaching a host. Keep raw logs and dumps private. |
| An old install reports `UNTRUSTED signature` | Follow the [package-repository repair procedure](docs/installation.md#updating-an-old-pre-august-2026-installation). |
| Fastboot remains reachable | Follow the [recovery notes](docs/installation.md#recovery-notes) to reinstall a known image. |
| Bootloop before fastboot | The [last-resort recovery page](docs/preloader-recovery.md) covers only damaged `misc` state and requires vendor files this project does not distribute. |

For community discussion, use
[`#linux-on-dc-1`](https://discord.gg/jNGuzVYk6F) in the Daylight Hacker Wiki
Community. This project is not officially supported by Daylight.

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

Use the [build guide](docs/building.md) for the pinned-source workflow,
requirements, and artifact boundaries. For kernel-only changes on the device,
see [local kernel development](docs/kernel-development.md).

The [contribution guide](CONTRIBUTING.md) describes validation, package version
bumps, and public-data rules. The [documentation index](docs/README.md) maps
source directories and hardware records. Open acceptance work lives in the
[roadmap](docs/roadmap.md), with dated results in the
[verification ledger](docs/verification.md).

## License

See [LICENSE](LICENSE) for the repository's MIT license. Files with their own
SPDX or license notices retain those terms; the kernel is maintained in the
separate [kernel repository](https://github.com/denysvitali/dc-1-linux-kernel).

Numbered installer builds are retained alongside `latest`; see [release versions](docs/releases.md).
