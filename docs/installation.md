# Installing postmarketOS on the Daylight DC-1

This guide installs postmarketOS on the DC-1 (`jagar`) using the artifacts
built by this repository's CI. Read the whole page once before starting.

> **Warning.** CI proves the build compiles, not that it boots. Releases
> record `hardware_verified=false`. Flashing is at your own risk. The
> procedure below only ever writes the `boot_a` slot (via fastboot) and the
> `userdata` partition (via the installer). It never touches anything else —
> and neither should you (see [Recovery notes](#recovery-notes)).

## What you need

- A Daylight DC-1 and a USB cable to your computer.
- A Linux host. The host script uses `ip(8)` to configure the USB network
  interface, so macOS is not currently supported by the script as-is.
- On the host: `fastboot` (from `android-tools`), `zstd`, `nc`,
  `sha256sum`, `ip`, and one of `mkpasswd`, `openssl`, or `busybox` (for
  password hashing). Run the installer script as root, or have `sudo`
  available for the `ip` calls.
- The release assets: `installer-boot.img`, `jagar-boot.img`,
  `jagar-rootfs.ext4.zst`, `SHA256SUMS` — from the
  [rolling release](https://github.com/denysvitali/dc-1-pmos/releases).
- The host script `installer/host/dc1-install.sh` from this repository.

Verify the downloads first:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

## How the flow works

The DC-1 boots via MediaTek LK with A/B slots, and LK provides `fastboot`.
The install happens in three stages:

1. An **installer boot image** is flashed to `boot_a`. It boots into
   "installation mode": a minimal initramfs that brings up USB gadget
   networking (device `172.16.42.1`, host `172.16.42.2`) and a serial
   console, then waits for the host.
2. The host script streams the raw ext4 rootfs to the device over that USB
   network. The device verifies the SHA-256 of the whole stream **before**
   the filesystem becomes mountable (the first MiB, containing the ext4
   superblock, is written last, only after the hash checks out), writes it
   to `userdata`, resizes it to the full partition, applies your answers
   (user, password hash, hostname, timezone, Wi-Fi), and reboots back into
   LK fastboot.
3. The **real boot image** is flashed to `boot_a` over the installer, and
   the device reboots into the installed system.

Note: tethered `fastboot boot <img>` (boot without flashing) is unverified
on this LK — there is no recorded evidence it works. That is why the
installer is flashed to `boot_a` and then replaced, rather than booted
tethered.

## Step by step

### 1. Put the device in fastboot mode

Boot the DC-1 into LK fastboot mode: power the device off, then hold
**Power + Volume Up** until the bootloader menu appears and select fastboot.

Alternatively, from the stock Android system with Developer Options and USB
debugging enabled:

```sh
adb reboot bootloader
```

From a running Linux system the same transition is done by writing
`boot-fastboot` to the misc partition's bootloader control block; the
installer initramfs ships a `rebootbl` tool that does exactly this.

Confirm the host sees it:

```sh
fastboot devices
```

### 2. Run the installer

The simplest path lets `dc1-install.sh` drive everything, including both
fastboot steps:

```sh
./dc1-install.sh --rootfs jagar-rootfs.ext4.zst \
                 --installer-boot installer-boot.img \
                 --boot-image jagar-boot.img
```

The script:

- asks for a **username**, **password**, **hostname** (default `dc1`),
  **timezone** (default `UTC`), and an optional **Wi-Fi SSID and
  passphrase** (WPA passphrase, 8–63 characters; leave the SSID empty to
  skip). The password is hashed on the host (crypt sha512); cleartext never
  leaves your machine;
- flashes the installer: `fastboot flash boot_a installer-boot.img` followed
  by `fastboot reboot`;
- waits for the installer's USB network interface (fixed host-side MAC
  `02:1a:11:00:00:01`), assigns `172.16.42.2/24`, and waits for the device
  at `172.16.42.1`;
- decompresses the rootfs, hashes it, and streams it with the answers to
  the device on TCP port 5555. This takes a few minutes;
- after the device reports `DC1-INSTALL: OK` and reboots into fastboot,
  flashes the real image: `fastboot flash boot_a jagar-boot.img` followed
  by `fastboot reboot`.

The device then boots the installed system. The boot initramfs finds the
root filesystem by its ext4 label `jagar-root` on `userdata`.

### Manual variant

You can also perform the fastboot steps yourself. First:

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot
```

Then, once the device is in installation mode, run the script without
`--installer-boot`:

```sh
./dc1-install.sh --rootfs jagar-rootfs.ext4.zst
```

and finish manually when it reports success:

```sh
fastboot flash boot_a jagar-boot.img && fastboot reboot
```

Other options: `--answers FILE` supplies pre-made answers non-interactively;
`--device-ip` / `--host-ip` override the defaults. See the header comment of
`installer/host/dc1-install.sh` for the full usage.

## Watching progress and debugging

- The device paints install progress on its panel.
- The install log is streamed on the first USB serial port
  (`/dev/ttyACM0` on the host).
- A debug shell listens on TCP port 4444 (`nc 172.16.42.1 4444`) and on the
  second USB serial port.

If the transfer aborts partway, nothing is lost: the target filesystem is
only made mountable after the full image hash verified, so you can simply
run the installer again.

## Recovery notes

- **There is no recovery channel without a working kernel.** The DC-1's
  authenticated preloader does not accept a download agent for storage
  writes. If the partitions LK itself depends on are damaged, the device
  cannot be recovered over USB. For this reason, **never flash `preloader`,
  `lk`, `dtbo`, `vendor_boot`, or the UFS boot LUNs.** The documented flow
  never writes them, and the device-side installer refuses to touch them by
  construction (it resolves its target strictly by the GPT partition name
  `userdata`).
- The device has A/B slots; this flow only uses `boot_a`.
- If a flashed boot image fails to boot, the watchdog resets the device
  back into LK fastboot, so you can reflash `boot_a` and try again. A
  failed boot is annoying, not fatal — as long as you only ever wrote
  `boot_a` and `userdata`.
