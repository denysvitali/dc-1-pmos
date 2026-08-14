# Installing postmarketOS on the Daylight DC-1

This guide installs postmarketOS on the DC-1 (`jagar`) using the artifacts
built by this repository's CI. Read the whole page once before starting.

> **Warning.** CI proves the build compiles, not that it boots. Releases
> record `hardware_verified=false`. Flashing is at your own risk. The
> procedure below only ever writes the `boot_a` slot and the `userdata`
> partition. It never touches anything else — and neither should you (see
> [Recovery notes](#recovery-notes)).

## What you need

- A Daylight DC-1 and a USB cable to a computer with `fastboot` (from
  `android-tools`) — needed only for the two commands that enter
  installation mode.
- A Wi-Fi network (WPA/WPA2 passphrase) for the recommended on-device
  install. No Wi-Fi? Use the [USB fallback](#usb-install-fallback).
- The release asset `installer-boot.img` (plus `SHA256SUMS`) from the
  [rolling release](https://github.com/denysvitali/dc-1-pmos/releases).

Verify the download first:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

## How the flow works

The DC-1 boots via MediaTek LK with A/B slots, and LK provides `fastboot`.

1. An **installer boot image** is flashed to `boot_a`. It boots into
   "installation mode": the device's own display and touchscreen drive the
   whole install from there. (USB gadget networking and a serial console
   also come up, for the fallback flow and for debugging.)
2. You pick your Wi-Fi network and enter your credentials on the panel's
   touch keyboard. The device downloads `jagar-rootfs.ext4.zst` and
   `SHA256SUMS` from the rolling release over verified TLS, checks the
   image's SHA-256 **in full before a single byte becomes mountable** (the
   first MiB, containing the ext4 superblock, is written last, only after
   everything verified), writes it to `userdata`, resizes it to the whole
   partition, and applies your answers (user, password hash — hashed
   on-device, never stored in cleartext — hostname, timezone, Wi-Fi).
3. The device then downloads `jagar-boot.img`, verifies it against
   `SHA256SUMS`, writes it to `boot_a` (the same slot you already flashed,
   nothing else), and reboots into the installed system. No computer is
   involved after step 1.

Note: tethered `fastboot boot <img>` (boot without flashing) is unverified
on this LK — there is no recorded evidence it works. That is why the
installer is flashed to `boot_a` and then replaced, rather than booted
tethered.

## Step by step (on-device install, recommended)

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

### 2. Flash the installer

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot
```

This is the last thing the computer does. You can unplug the cable now
(leave it attached if you want the serial log or the USB fallback).

### 3. Follow the prompts on the device

The panel shows the installer menu. Choose **Install from network
(recommended)** and the touch keyboard walks you through:

- **Wi-Fi**: pick your network from the scan (or type its name), enter the
  WPA passphrase (8–63 characters).
- **Username**, **password** (entered twice; hashed on-device with crypt
  sha512 — the cleartext is never stored), **hostname** (default `dc1`),
  and **timezone** (pick from the list or type `Area/City`).
- Confirm. The device downloads the rootfs (a few hundred MiB — expect a
  few minutes on ordinary Wi-Fi), verifies it against `SHA256SUMS`, writes
  and provisions it, writes the verified `jagar-boot.img` to `boot_a`, and
  reboots into the installed system.

The boot initramfs finds the root filesystem by its ext4 label
`jagar-root` on `userdata`. If anything fails, the error is shown on the
panel and the menu returns — nothing half-written is ever left mountable,
so you can just try again (or fall back to USB).

## USB install (fallback)

If the device has no usable Wi-Fi, install over the USB cable from a Linux
host instead. You additionally need `jagar-boot.img` and
`jagar-rootfs.ext4.zst` from the release, the host script
`installer/host/dc1-install.sh` from this repository, and on the host:
`zstd`, `nc`, `sha256sum`, `ip`, and one of `mkpasswd`, `openssl`, or
`busybox` (password hashing). The host script uses `ip(8)`, so macOS is not
currently supported as-is; run it as root or with `sudo` available.

With the device in fastboot mode, the script can drive everything,
including both fastboot steps:

```sh
./dc1-install.sh --rootfs jagar-rootfs.ext4.zst \
                 --installer-boot installer-boot.img \
                 --boot-image jagar-boot.img
```

The script:

- asks for a **username**, **password**, **hostname**, **timezone**, and
  optional **Wi-Fi credentials** (the password is hashed on the host;
  cleartext never leaves your machine);
- flashes the installer to `boot_a` and reboots;
- waits for the installer's USB network interface (fixed host-side MAC
  `02:1a:11:00:00:01`), assigns `172.16.42.2/24`, and waits for the device
  at `172.16.42.1`. On the device, choosing **Install via USB from a
  computer** in the menu shows these instructions on the panel — but the
  USB listener runs regardless of what the menu shows;
- decompresses the rootfs, hashes it, and streams it with the answers to
  the device on TCP port 5555. The device applies the same fail-closed
  verification as the network install;
- after the device reports `DC1-INSTALL: OK` and reboots into fastboot,
  flashes the real image: `fastboot flash boot_a jagar-boot.img` followed
  by `fastboot reboot`.

If the device is already in installation mode, run the script without
`--installer-boot` and finish manually with
`fastboot flash boot_a jagar-boot.img && fastboot reboot`. Other options:
`--answers FILE` supplies pre-made answers non-interactively;
`--device-ip` / `--host-ip` override the defaults. See the header comment
of `installer/host/dc1-install.sh` for the full usage.

## Watching progress and debugging

- The device paints install progress on its panel.
- The install log is streamed on the first USB serial port
  (`/dev/ttyACM0` on the host).
- A debug shell listens on TCP port 4444 (`nc 172.16.42.1 4444`) and on the
  second USB serial port.

If a download or transfer aborts partway, nothing is lost: the target
filesystem is only made mountable after the full image hash verified, so
you can simply run the installer again. Wi-Fi diagnostics stay on the
device under `/tmp/wifi` (they are never written to the kernel log, which
is streamed over USB).

## Recovery notes

- **There is no recovery channel without a working kernel.** The DC-1's
  authenticated preloader does not accept a download agent for storage
  writes. If the partitions LK itself depends on are damaged, the device
  cannot be recovered over USB. For this reason, **never flash `preloader`,
  `lk`, `dtbo`, `vendor_boot`, or the UFS boot LUNs.** The documented flow
  never writes them, and the device-side installer refuses to touch them by
  construction (it resolves its target strictly by the GPT partition name
  `userdata`, and writes a boot image only to the GPT partition named
  `boot_a` — the slot you already flashed — after verifying the image
  against `SHA256SUMS`).
- The device has A/B slots; this flow only uses `boot_a`.
- If a flashed boot image fails to boot, the watchdog resets the device
  back into LK fastboot, so you can reflash `boot_a` and try again. A
  failed boot is annoying, not fatal — as long as you only ever wrote
  `boot_a` and `userdata`.
