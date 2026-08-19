# Installing postmarketOS on the Daylight DC-1

This guide installs postmarketOS on the DC-1 (`jagar`) using the artifacts
built by this repository's CI. Read the whole page once before starting.

> **Warning.** CI proves the build compiles, not that it boots. Releases
> record `hardware_verified=false`. Flashing is at your own risk. The
> procedure below only ever writes the `boot_a` slot and the `userdata`
> partition, plus `misc` for the A/B slot metadata once the system is
> running. It never touches anything else — and neither should you (see
> [Recovery notes](#recovery-notes)).
>
> One partition is deliberately left out of the default flow: `vendor_boot`.
> Earlier revisions of this page believed LK reads the device tree from it;
> that was measured false (see Recovery notes). The mainline device tree ships
> *inside* `jagar-boot.img` itself since 2026-08-19 — a small stub in the
> kernel slot swaps it in at boot — so the normal flow below already installs
> it, and `vendor_boot` stays untouched.

## Choose an install path

Two ways to install. The first is the default.

1. **On-device installer (recommended).** You flash one boot image over
   `fastboot`, then answer everything on the device's touchscreen. The device
   downloads the release over Wi-Fi and installs itself — no computer involved
   after the first command. Needs Wi-Fi.
2. **USB install from a computer (advanced / fallback).** A script on your
   computer drives the install over the USB cable. Use it when there is no
   Wi-Fi, or when you want the image streamed from a host you control. See
   [Install from a computer](#install-from-a-computer-advanced--fallback).

Both paths write the same filesystem to the same place; they differ only in
who asks the questions and how the image reaches the device.

## What you need

- A Daylight DC-1.
- A computer with `fastboot` (from `android-tools`) and a USB cable — for the
  one command that enters installation mode (both paths).
- **On-device path:** a Wi-Fi network with a WPA passphrase (the device
  downloads the release over it).
- **USB path:** the host script and a few host tools, listed in that section.
- The release asset `installer-boot.img` (plus `SHA256SUMS`) from the
  [rolling release](https://github.com/denysvitali/dc-1-pmos/releases).

Verify the download first:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

The on-device installer fetches everything else it needs over Wi-Fi itself.

## How the flow works

The DC-1 boots via MediaTek LK with A/B slots, and LK provides `fastboot`.

An **installer boot image** is flashed to `boot_a`. It boots into
"installation mode": the panel runs a touch UI (`dc1-ask`) drawn by the
installer's PID 1, and USB gadget networking plus a serial console come up in
parallel. The touch UI is the front door; the USB link stays up the whole time
so a host can always take over.

The recommended path is **Install from network**: the device scans Wi-Fi,
connects, then downloads `jagar-rootfs.ext4.zst` and `jagar-boot.img` from the
rolling release over TLS. It checks each file's SHA-256 **in full before a
single byte becomes mountable** (the first MiB, containing the ext4
superblock, is written last, only after everything verified), writes the
rootfs to `userdata`, grows it to fill the partition, applies your answers
(user, password hash — the cleartext is never stored — hostname, timezone,
Wi-Fi), writes the boot image to `boot_a`, and reboots.

The installed system is a GNOME Mobile desktop on Wayland/systemd. The boot
initramfs finds the root filesystem by its ext4 label `jagar-root` on
`userdata`. If anything fails, nothing half-written is ever left mountable, so
you can simply run the flow again.

Note: tethered `fastboot boot <img>` (boot without flashing) is unverified on
this LK — there is no recorded evidence it works. That is why the installer is
flashed to `boot_a` and then replaced, rather than booted tethered.

## Install from the device (recommended)

### 1. Get the installer

Download `installer-boot.img` and `SHA256SUMS` from the rolling release and
verify:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

### 2. Put the device in fastboot mode

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

### 3. Flash the installer

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot
```

The device boots into installation mode and shows the installer menu.

### 4. Walk through the touch installer

Choose **Install from network**. (The other menu options are *Install via USB
from a computer* — the advanced path below — and *Reboot to fastboot*.)

- **Wi-Fi.** The device scans and lists nearby networks, strongest first. Tap
  yours, or choose *Type network name* to enter an SSID by hand. Enter the
  passphrase (8–63 characters). The device connects and requests an IP address
  by DHCP.
- **Account.** Set up now: choose a **username**, a **password** (entered
  twice), a **hostname**, and a **timezone** (a short list of common zones,
  plus *Type another* for anything else). The password is hashed on the device
  before it is stored; the cleartext is never written anywhere. The installer
  also offers a *set up later* option that skips account setup; setting
  everything up now is the recommended path.
- **Install now.** Tap **Install now** (it warns that this erases the Linux
  data partition). The device downloads the release over Wi-Fi, verifies each
  file, writes the rootfs, grows it, applies your answers, writes the boot
  image, and reboots.

Leave it to finish — the panel shows download and write progress, and the
install ends in a reboot into the installed system.

### 5. First boot

On the first boot the installed system downloads and installs the desktop app
set — Chromium, Ghostty, GNOME Console, GNOME Calculator, GNOME Text Editor,
and Nautilus — from Alpine over the network. This runs once and is skipped on
later boots; if the network is not ready on the first boot it retries on the
next one.

## Install from a computer (advanced / fallback)

This is the fallback path for when there is no Wi-Fi, or when you want the
image streamed from a host you control. The image and the answers both come
over the USB cable; the on-device touch UI is not used. You need
`jagar-rootfs.ext4.zst` and `jagar-boot.img` from the release, the host script
`installer/host/dc1-install.sh` from this repository, and on the host: `zstd`,
`nc`, `sha256sum`, `ip`, and one of `mkpasswd`, `openssl`, or `busybox`
(password hashing). The host script uses `ip(8)`, so macOS is not currently
supported as-is; run it as root or with `sudo` available.

With the device in fastboot mode, the script can drive everything, including
both fastboot steps:

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
but not provisioned;
`--device-ip` / `--host-ip` override the defaults. See the header comment
of `installer/host/dc1-install.sh` for the full usage.

## Watching progress and debugging

- The device paints download and write progress on its panel.
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

- **There is no general recovery channel without a working kernel.** The DC-1's
  authenticated preloader does not accept an arbitrary download agent for
  storage writes. The one exception is the vendor's *signed* download agent,
  with the matching auth blob — proprietary files this repository does not and
  will not ship, but which do open a USB channel if you have them; see
  [Recovering a bootlooping device](preloader-recovery.md). Short of that, if
  the partitions LK itself depends on are damaged, the device cannot be
  recovered over USB. For this reason, **never flash `preloader`,
  `lk`, `dtbo`, or the UFS boot LUNs.** The documented flow never writes
  them, and the device-side installer refuses to touch them by construction
  (it resolves its target strictly by the GPT partition name `userdata`, and
  writes a boot image only to the GPT partition named `boot_a` — the slot you
  already flashed — after verifying the image against `SHA256SUMS`).
- **Writing `vendor_boot` does not change the device tree.** LK takes the
  kernel's DT from `lk_main_dtb` (a signed image inside the `lk` partition)
  merged with the signed `dtbo`; the DTB inside `vendor_boot` never reaches
  the kernel. This was measured from LK's own log on 2026-08-18 and corrects
  what earlier revisions of this page said. `dc1-boot-sync`'s
  `DC1_DEPLOY_VENDOR_BOOT=1` and `dc1-install.sh --vendor-boot-image` still
  exist, but they cannot ship a device tree — treat them as no-ops for that
  purpose.
- **Never write `dtbo`.** LK authenticates it (`img_auth_required = 1`,
  `sbc_en = 1`, `dtbo cert chain vfy pass`). An unsigned overlay fails that
  check and LK marks the slot dead before the kernel runs — no log, no
  display, no USB. Both slots on the development device were lost this way.
  Shipping a mainline tree through `lk`/`dtbo` would require signing them,
  which this project cannot do. The supported route (since 2026-08-19,
  hardware-verified) is the `boot/dtbswap` stub inside `jagar-boot.img`: LK
  boots the unauthenticated boot image as usual, and the stub hands the
  kernel our device tree instead of LK's merged one. No signed partition is
  ever written.
- The device has A/B slots; this flow only uses `boot_a`.
- If a flashed boot image fails to boot, the watchdog resets the device
  back into LK fastboot, so you can reflash `boot_a` and try again. A
  failed boot is annoying, not fatal — as long as you only ever wrote
  `boot_a` and `userdata`.
- **Reachability watchdog.** A boot that *succeeds* but cannot be reached is
  the worst failure mode on a device with no serial header: the system pets
  the hardware watchdog forever while you cannot get in. The boot image
  therefore deploys `dc1-boot-watchdog` into the installed system on every
  boot. While any shell channel is provably alive — an established inbound
  connection on ports 22/4444, or a listener on one of them plus an answering
  peer (the USB host at `172.16.42.2`, or the Wi-Fi default gateway) — it
  stays quiet. After 10 minutes of none of that, it reboots the device into
  LK fastboot, where an attached host can always re-flash. Pat it explicitly
  with `dc1-boot-watchdog pat` (disarms for the current boot), or opt out
  persistently with `touch /etc/dc1/boot-watchdog.disabled` — do that if you
  use the tablet away from any network, or an offline session will reboot
  under you after 10 minutes. A second, longer deadman (15 minutes) is armed
  from the initramfs and covers the case where systemd never manages to start
  the watchdog service at all.
