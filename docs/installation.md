# Installing postmarketOS on the Daylight DC-1

This guide installs postmarketOS on the DC-1 (`jagar`) using the artifacts
built by this repository's CI. Read the whole page once before starting.

> **Warning.** CI proves the build compiles, not that it boots. Releases
> record `hardware_verified=false`. Flashing is at your own risk. The
> procedure below only ever writes the `boot_a` slot and the `userdata`
> partition, plus A/B metadata in `misc` through `fastboot set_active a` and
> the installed slot manager. It never touches anything else (see
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
   after the initial fastboot sequence. Needs Wi-Fi.
2. **USB install from a computer (advanced / fallback).** A script on your
   computer drives the install over the USB cable. Use it when there is no
   Wi-Fi, or when you want the image streamed from a host you control. See
   [Install from a computer](#install-from-a-computer-advanced--fallback).

Both paths write the same filesystem to the same place; they differ only in
who asks the questions and how the image reaches the device.

Both are implemented and offline-tested. The full published-release path from
installer flash through provisioning, first login, and first update has not
yet been exercised end-to-end on hardware.

## What you need

- A Daylight DC-1.
- A computer with `fastboot` (from `android-tools`) and a USB cable — for the
  initial flash, slot-selection, and reboot sequence (both paths).
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
rolling release over TLS. It checks each file's SHA-256 **in full before the
transferred rootfs becomes mountable** (the first MiB, containing the ext4
superblock, is written last, only after everything verified), writes the
rootfs to `userdata`, grows it to fill the partition, applies your answers
(user, password hash — the cleartext is never stored — hostname, timezone,
Wi-Fi), writes the boot image to `boot_a`, and reboots.

The installed system is a GNOME Mobile desktop on Wayland/systemd. The boot
initramfs finds the root filesystem by its ext4 label `jagar-root` on
`userdata`. An interrupted or mismatched image transfer is never left
mountable. Provisioning starts after that commit and can fail independently;
rerunning the installer is the supported recovery in either case.

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
fastboot flash boot_a installer-boot.img
fastboot set_active a
fastboot reboot
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

### The side buttons

The power and volume paths work. The two spare buttons use Daylight's official names
("Quick Action", "Back Button" — stock Android assigns neither), and this
port maps them to `XF86Launch1`/`XF86Launch2` via a udev hwdb remap so they
never collide with application function keys:

| Button | Location | Key it emits | Default action |
| --- | --- | --- | --- |
| Power | side | `KEY_POWER` | GNOME power menu |
| Volume up / down | side | `KEY_VOLUMEUP` / `KEY_VOLUMEDOWN` | volume |
| Quick Action | top left | `XF86Launch1` (`KEY_PROG1`) | screenshot UI |
| Back Button (Walkie Talkie) | bottom right | `XF86Launch2` (`KEY_PROG2`) | activities overview |

The Quick Action and Back Button defaults are only schema defaults: to rebind
either one, open GNOME Settings → Keyboard → View and Customize Shortcuts →
Custom Shortcuts, add a shortcut, and press the physical button when asked
for the key — it registers as `Launch1`/`Launch2`. To detach a button from
its default first, clear the matching entry (`show-screenshot-ui` under
System → Screenshots, `toggle-overview` under Navigation) in the same
Keyboard panel.

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
- flashes the installer to `boot_a`, selects slot A, and reboots;
- waits for the installer's USB network interface (fixed host-side MAC
  `02:1a:11:00:00:01`), assigns `172.16.42.2/24`, and waits for the device
  at `172.16.42.1`. The device's USB listener runs from boot; nothing has
  to be selected on the panel;
- decompresses the rootfs, hashes it, and streams it with the answers to
  the device on TCP port 5555, fail-closed: a short or mismatched stream is
  scrubbed rather than left mountable;
- after the device reports `DC1-INSTALL: OK` and reboots into fastboot,
  flashes the real image, selects slot A, and reboots.

If the device is already in installation mode, run the script without
`--installer-boot` and finish manually with
`fastboot flash boot_a jagar-boot.img && fastboot set_active a && fastboot
reboot`. Other options:
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
- The installer's main menu has a **Debug tools** entry (device info,
  partition checksums, log collection); everything it collects is strictly
  read-only and lands in `/tmp/debug`. See
  [docs/debugging.md](debugging.md) for what each tool shows and how to
  pull the files off the device.

If a download or transfer aborts partway, nothing is lost: the target
filesystem is only made mountable after the full image hash verified, so
you can simply run the installer again. Wi-Fi diagnostics stay on the
device under `/tmp/wifi` (they are never written to the kernel log, which
is streamed over USB).

## Staying current

An installed device keeps itself converging on the published release; a
re-flash is never needed for userland fixes.

- `dc1-update.timer` runs `apk update` + `apk upgrade` about 15 minutes
  after every boot and weekly thereafter (`Persistent=true` catches a
  missed week while the device was powered off). Kernel packages arm the
  inactive slot exactly like a manual upgrade — the new kernel applies on
  the next reboot.
- Each run writes a summary to `/var/lib/dc1/update-state` and the journal
  (`journalctl -u dc1-update.service`), including how far the three overlay
  packages (`mutter-mobile`, the kernel, the device package) are from the
  rolling release.
- Toggle automatic updates in **Settings → Charging Profile**, or opt out with
  `touch /var/lib/dc1/no-auto-update` / `systemctl mask dc1-update.timer`.

### Updating an old (pre-August-2026) installation

Devices installed before the signed package repository existed (device
package pkgrel < 45) cannot upgrade even by hand: apk fails with
`UNTRUSTED signature` because they have neither the repository key nor the
repository list. The release ships a one-shot repair script; run it ON THE
DEVICE as root (over ssh or the debug shell):

    curl -fsSL -o /tmp/dc1-repair-apk.sh \
      https://github.com/denysvitali/dc-1-pmos/raw/main/installer/host/dc1-repair-apk.sh
    sh /tmp/dc1-repair-apk.sh

(on a device without curl, busybox `wget -O` works too). Each release
directory also contains the script alongside `dc1-apk.rsa.pub`. The script
fetches the repository public key from the release, verifies it against
that release's `SHA256SUMS`, installs it — **refusing to overwrite a
*different* already-installed key** instead of silently replacing a trust
anchor — writes the repository list only if absent, restores missing
Alpine key links into `/etc/apk/keys`, then runs `apk update` +
`apk upgrade` and prints the resulting package versions. Afterwards the
normal `dc1-update.timer` path takes over.

## Charging mode

**Experimental / not yet hardware-verified:** the boot-reason reader works,
but a real charger-insert boot still owes the calibration that confirms code
`1` and the complete enter/exit cycle. A dark panel is not proof of charging.

The feature is designed so plugging USB power into a cleanly-powered-off DC-1 boots it into a minimal
headless **charging mode** instead of the full desktop (device package
pkgrel >= 79). The panel, frontlight, network, and desktop all stay off;
the device is dark and silent. Charging itself never depends on any of
that: the MT6375 charger runs its CC/CV profile to the pack's 4.35 V limit
in hardware, the kernel raises the input limit to 1.5 A and the charge
target to 3.15 A as soon as VBUS appears, and USB-PD contracts are negotiated
in-kernel without desktop userspace. Pack-temperature-informed current
control remains unavailable while the BQ78Z100 does not answer.

| You do | The device does |
| --- | --- |
| Plug USB power into a cleanly powered-off device | Boots silently into charging mode |
| Unplug while in charging mode | Powers off cleanly after a few seconds |
| Press power briefly | Warm-reboots into the normal desktop |
| Hold power until the PMIC hard-reset fires | Hard-resets into the normal desktop |

While charging, systemd, the journal, udev, logind, and the USB gadget stay
up, so the recovery channels keep working: the debug shell on TCP 4444 at
`172.16.42.1` over the cable, and both USB serial ports. Everything else —
GNOME, Wi-Fi, Bluetooth, sshd — is stopped. The boot watchdog is stood down
for the duration, so leaving the device on a dumb charger cannot
reboot-loop it.

Detection reads why the device powered on. Every boot, the bootloader
leaves a fresh console log in reserved memory (kept mapped by the device
tree), and its last `BOOT_REASON:` line names the cause — charger insert,
power key, RTC alarm, watchdog, warm reboot, kernel panic. A
charger-insert boot enters charging mode outright when power is present;
watchdog and warm-reboot boots never enter it — which is exactly what
makes the brief power-key press above able to exit to the desktop even
while docked. Any other boot — power key, alarm, panic, unknown code, or
an unreadable log — falls back to the older heuristic: the timestamp
recorded at the last clean shutdown (`dc1-poweroff-flag.service` writes
`/var/lib/dc1/poweroff-clean`; reboots leave no flag), valid for 7 days.
Two conditions apply either way: `/var/lib/dc1/no-charging-mode` must not
exist, and the device must have finished its first-boot setup once
(`/var/lib/dc1/first-boot-apps-done`) — a system that has never completed
provisioning always boots to the desktop, so a fresh install rebooting
with the flash cable still attached does not wake as silent dark glass.
Four consequences worth knowing:

- Pressing power **while plugged in** after a clean poweroff lands in
  charging mode first — press power again to continue to the desktop.
- After a battery death (an unclean shutdown leaves no flag) the next
  boot goes straight to the desktop, exactly as before.
- A wrong guess costs one extra keypress at most; it never takes away the
  old behavior.
- A port that suspends its VBUS for longer than the ~6 s unplug debounce
  (some laptops do this) reads as "unplugged": the device powers off, then
  boots back into charging mode when the port wakes — a slow but harmless
  cycle, and by design.

Opt out permanently with:

```sh
touch /var/lib/dc1/no-charging-mode
```

The same switch is available in **Settings → Charging Profile**.

Diagnose with `journalctl -t dc1-charging`. The boot-cause readout itself
is verified on hardware, but confirming that real charger boots report
the charger code is still owed one calibration session — so charging mode
ships **not yet hardware-verified** until a real charger boot has been
cycled.

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
  what earlier revisions of this page said. The tooling that could still
  write it (`dc1-boot-sync`'s old `DC1_DEPLOY_VENDOR_BOOT=1`,
  `dc1-install.sh --vendor-boot-image`, the release's `jagar-vendor-boot.img`)
  has been removed: it could not ship a device tree, so keeping it only
  invited a flash that buys nothing.
- **Never write `dtbo`.** LK authenticates it (`img_auth_required = 1`,
  `sbc_en = 1`, `dtbo cert chain vfy pass`). An unsigned overlay fails that
  check and LK marks the slot dead before the kernel runs — no log, no
  display, no USB. Both slots on the development device were lost this way.
  Shipping a mainline tree through `lk`/`dtbo` would require signing them,
  which this project cannot do. The supported route (since 2026-08-19,
  hardware-verified) is the `boot/dtbswap` stub inside the boot images —
  both `jagar-boot.img` and, since issue #1 (some units black-screen
  installation mode on the stock tree), `installer-boot.img`: LK
  boots the unauthenticated boot image as usual, and the stub hands the
  kernel our device tree instead of LK's merged one. No signed partition is
  ever written.
- The device has A/B slots; this flow only uses `boot_a`.
- If a flashed slot fails before Linux starts, LK's A/B metadata governs its
  fallback; once Linux starts, the reachability watchdog can reset an
  unreachable boot into LK fastboot. You can then reflash `boot_a` and try
  again, as long as the documented partition boundary was respected.
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
