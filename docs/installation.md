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
- Optionally a Wi-Fi network (WPA/WPA2 passphrase): the installer can
  provision the installed system's Wi-Fi for you, but it is not needed to
  install — the rootfs comes over the USB cable.
- The release asset `installer-boot.img` (plus `SHA256SUMS`) from the
  [rolling release](https://github.com/denysvitali/dc-1-pmos/releases).

Verify the download first:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

## How the flow works

The DC-1 boots via MediaTek LK with A/B slots, and LK provides `fastboot`.

1. An **installer boot image** is flashed to `boot_a`. It boots into
   "installation mode": the panel shows install progress, and USB gadget
   networking plus a serial console come up. The install itself is driven
   from your computer over that USB link, by `dc1-install.sh`.
2. The host script asks for your username, password, hostname, timezone
   and optional Wi-Fi credentials, then streams `jagar-rootfs.ext4.zst` to
   the device. The device checks the image's SHA-256 **in full before a
   single byte becomes mountable** (the first MiB, containing the ext4
   superblock, is written last, only after everything verified), writes it
   to `userdata`, resizes it to the whole partition, and applies your
   answers (user, password hash — the cleartext is never stored — hostname,
   timezone, Wi-Fi).
3. The device reboots into fastboot, the script flashes the verified
   `jagar-boot.img` to `boot_a` (the same slot you already flashed, nothing
   else), and the device boots the installed system.

A fully on-device installer — the same questions, answered on the panel's own
touch keyboard, with no computer involved after step 1 — is built and shipped
(`dc1-ask`). Its dialogs render **inside PID 1**, which owns the panel: a
second DRM modeset blackens this panel, so `dc1-ask` is a thin client that
forwards each prompt to PID 1's in-process dialog server over a Unix socket,
and PID 1 draws the screen into the surface it already committed (using the
hardware-measured touch mapping). It is **enabled by default but not yet
hardware-verified end-to-end** — the plumbing builds and its offline tests
pass, but a freshly flashed image running the full on-device flow has not been
confirmed on a panel. Until it is, the USB flow below is the path with
hardware behind it.

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

From a running postmarketOS system, run:

```sh
sudo dc1-reboot-fastboot
```

It does what LK's own `fastboot reboot-bootloader` does: put 3 in the boot
mode nibble of the watchdog register that survives a reset (`0x10007024`),
then reboot. LK reads it on the way up and enters fastboot. `-n` reports what
it would do and changes nothing.

What it does *not* do is write `boot-fastboot` into the misc partition's
bootloader control block. That is the AOSP-shaped answer, and on this LK it is
a trap: the only two commands it compares against are `boot-recovery` and
`boot-fastboot`, **both mean recovery**, and a match returns before LK ever
looks at the nibble or at the Volume-Up boot menu — so an armed BCB does not
reach fastboot and takes the other two ways in with it. `dc1-reboot-fastboot`
clears a stale one for exactly that reason.

Confirm the host sees it:

```sh
fastboot devices
```

### 2. Flash the installer

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot
```

Leave the cable attached: the computer drives the rest of the install over
it, and it also carries the serial log.

### 3. Run the installer from your computer

The panel shows install progress, but the questions are asked by the host
script over the USB link:

```sh
./dc1-install.sh --rootfs jagar-rootfs.ext4.zst \
                 --boot-image jagar-boot.img
```

It asks for a **username**, **password** (hashed on your machine — the
cleartext never leaves it), **hostname**, **timezone** and optional **Wi-Fi
credentials**, then streams the rootfs to the device, which verifies and
writes it, provisions it with your answers, and reboots into fastboot so the
script can flash the real `jagar-boot.img`. Full options, host requirements
and what each step does are in [the section below](#the-install-itself-from-your-computer).

The boot initramfs finds the root filesystem by its ext4 label `jagar-root`
on `userdata`. If anything fails, nothing half-written is ever left
mountable, so you can simply run it again.

## The install itself, from your computer

This is the install path, not a fallback: the on-device touch installer that
would let the device download its own rootfs over Wi-Fi is disabled (see
above), so the answers and the image both come over the USB cable from a
Linux host. You need `jagar-boot.img` and
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
  at `172.16.42.1`. The device's USB listener runs from boot; nothing has
  to be selected on the panel;
- decompresses the rootfs, hashes it, and streams it with the answers to
  the device on TCP port 5555, fail-closed: a short or mismatched stream is
  scrubbed rather than left mountable;
- after the device reports `DC1-INSTALL: OK` and reboots into fastboot,
  flashes the real image: `fastboot flash boot_a jagar-boot.img` followed
  by `fastboot reboot`.

If the device is already in installation mode, run the script without
`--installer-boot` and finish manually with
`fastboot flash boot_a jagar-boot.img && fastboot reboot`. Other options:
`--answers FILE` supplies pre-made answers non-interactively;
`--skip-provision` installs with **no** answers at all — the image is written
but not provisioned, so on first boot the installed system's on-device UI runs
onboarding (Wi-Fi, username, password, hostname, timezone) on the panel's
touchscreen instead of asking at install time;
`--device-ip` / `--host-ip` override the defaults. See the header comment
of `installer/host/dc1-install.sh` for the full usage.

## On-device UI

The installed system ships a Flutter shell (hardware-rendered via Panfrost on
the Mali-G57) backed by a Go control plane. On a provisioned install it shows
a first-light screen; on an **unprovisioned** install (`--skip-provision`) it
runs first-boot onboarding on the touchscreen. The control plane binds a Unix
socket only — it never listens on a network address, so neither the USB host
nor any Wi-Fi peer can reach onboarding.

The onboarding flow (Wi-Fi, username, password, hostname, timezone) can be
tried in a browser before flashing: the same Flutter source compiles to the
web and is published at
<https://denysvitali.github.io/dc-1-pmos/>.

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
