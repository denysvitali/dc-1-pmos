# Security and exposure — what listens where

This port deliberately keeps debug channels open: a tablet with no
serial header and no general recovery channel is only serviceable if you
can always get in. This page states exactly what is exposed, to whom,
and how to close each channel if you do not want it. The matrix below
was measured on a running installed system on 2026-08-26 (device pkgrel
r76, kernel r37); the code that establishes each property is referenced.

## Exposure matrix — installed system

| Channel | Binds to | Authentication | Reachable via | How to close |
| --- | --- | --- | --- | --- |
| sshd, TCP 22 | `0.0.0.0` + `[::]` (all interfaces) | Password of the account created at install (sshd defaults; no `PermitRootLogin`/`PasswordAuthentication` overrides are shipped) | Wi-Fi **and** USB | `systemctl disable --now sshd`, or restrict with a `ListenAddress`/firewall |
| Root shell, TCP 4444 | `172.16.42.1` **only** (usb0) — never `0.0.0.0` | **None** (busybox `nc -lk -e /bin/sh`) | USB cable only | `systemctl disable --now dc1-debug-shell` |
| kmsg stream, `/dev/ttyGS0` | USB ACM function | None (one-way log stream) | USB cable only | same unit as above |
| Interactive root shell, `/dev/ttyGS1` | USB ACM function | **None** | USB cable only | same unit as above |
| DNS `127.0.0.53`/`127.0.0.54:53`, LLMNR 5355 | loopback / all (LLMNR) | n/a (systemd-resolved) | LLMNR is link-local multicast | `LLMNR=no` in resolved.conf |

Source: `dc1-debug-shell.service`/`.initd` in the device package — the
TCP shell's usb0-only bind is deliberate ("never 0.0.0.0, so a later
Wi-Fi connection cannot expose an unauthenticated root shell on the
LAN"); sshd is enabled unconditionally by installer provisioning
(`apply_sshd`) because when GNOME does not come up, SSH is the recovery
path.

Caveats worth knowing:

- The 4444 shell is safe from Wi-Fi **because of the bind address**. A
  Wi-Fi network itself numbered `172.16.42.0/24` (or a route to it) would
  make the USB link-local net reachable over the air — if you use such a
  range, disable the unit.
- The two USB ACM channels are physical-access channels. Anyone holding
  the cable and the device holds root. That is the trade the recovery
  argument makes; it is stated here so it is a decision, not a surprise.
- Password quality of the sshd channel is whatever was set in the
  installer; there is no rate limiting beyond sshd defaults.

## Exposure matrix — installer mode (installation initramfs)

| Channel | Binds to | Authentication |
| --- | --- | --- |
| sshd, TCP 22 | `172.16.42.1` (usb0) only | root, **blank password** |
| Root shell, TCP 4444 | `172.16.42.1` only | none |
| sh on ttyGS1/ttyACM0/ttyS0/tty1 | USB serial / console | none |

Installer mode is a transient recovery environment on a USB link-local
address; it never joins Wi-Fi before credentials are given, and the
installed system it writes contains none of these credentials.

## What is *not* exposed

- Published artifacts contain no user-provided credentials: the build
  signs only its APK index, `PROVENANCE` records pins, and the installer
  provisions the real account and password on-device (hashed at rest
  from the first moment). The build-time placeholder account is not a
  user secret.
- No proprietary blobs ship; firmware is fetched from upstream
  linux-firmware/wireless-regdb at build time under size + SHA-256 pins.
- The charging-mode target (device pkgrel ≥ 79) keeps the USB recovery
  channel (`dc1-usb-gadget` + `dc1-debug-shell` + `unudhcpd@usb0`) but
  excludes NetworkManager, wpa_supplicant, and sshd — a docked device
  has **no** Wi-Fi listeners at all.

## If you want a quieter device

```sh
# close the unauthenticated USB shells (keeps sshd):
systemctl disable --now dc1-debug-shell
# close sshd entirely (keeps USB serial shells if left enabled):
systemctl disable --now sshd
# opt out of the reachability watchdog's reboots:
sudo touch /etc/dc1/boot-watchdog.disabled
```

Re-enabling any of these later requires a working login path — do not
close every channel at once unless you are confident in the surviving
one.
