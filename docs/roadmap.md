# Roadmap and acceptance

[README](../README.md#hardware-support-at-a-glance) describes support;
[verification](verification.md) records tested claims. This page contains open
work and its acceptance criteria. Check the installed package versions before
any hardware session. A file on disk or a green build does not prove the
running image has exercised a change.

## Hardware acceptance

| Area | Required result | Reference |
| --- | --- | --- |
| Pen | Ink tracks the nib at edges/corners; eraser switching works, including flips during hover, in a tablet-v2 app | [Input](hw/input.md) |
| Rotation | All four physical poses render upright with aligned touch; rotation lock freezes the transform and unlock catches up; no duplicate sensor/compositor rotation | [Sensors](hw/sensors.md) |
| Power key | Short press locks/blanks; next press wakes; hold opens the power menu; no double toggle | [Input](hw/input.md) |
| Spare buttons | Quick Action and Back emit KEY_PROG1/KEY_PROG2 and trigger their shortcuts exactly once | [Input](hw/input.md) |
| GNOME lifecycle | Logout reaches the Wayland greeter; OSK login works; extensions and orientation recover; lock-screen prompt remains visible above the keyboard | [GNOME](gnome.md) |
| Bluetooth | Cold boot completes controller setup without repair; peer pairing and A2DP work | [Wireless](hw/wireless.md) |
| USB gadget | A host gets ECM carrier and can SSH to the installed account at 172.16.42.1; initramfs binds the correct UDC without failed candidates | [USB](hw/usb.md) |
| USB host | Matching modules, sink-host peripherals, Ethernet/storage/audio/UVC, repeated hotplug and gadget return pass the acceptance procedure | [Docking](usb-docking.md#hardware-acceptance-session) |
| Charging boot | Clean poweroff then USB insertion enters charging mode; LK's last BOOT_REASON is 1 with handoff marker; unplug and power-key exits work | [Power hardware](hw/power.md) |
| Audio route | With owner approval, a controlled physical PCM0/DL1 probe confirms both speaker channels | [Audio](hw/audio.md) |

Do not close a whole subsystem row from a narrower result. Controller-up is
not Bluetooth pairing, a hub is not downstream input, and dark glass is not
proof of charging. Record dates, running APK versions and artifact hashes
where applicable.

Hardware sessions must preserve recovery. Keep gadget objects bound; use a
working recovery channel before logging out. Audio needs the owner's go-ahead.
Power cycles and suspend require an agreed local recovery plan. Use the
subsystem runbooks rather than improvising register writes.

## Published-release acceptance

1. Install one exact published release using its installer and checksums.
   Exercise account/Wi-Fi provisioning, first boot, first login and first
   automatic update. Installation erases userdata.
2. Check installed versions against all four release APKs, boot-image/kernel
   parity, repository trust and the A/B update/fallback path.
3. Close or explicitly scope the hardware acceptance rows for that release.
4. Only then mark the tested artifact set `hardware_verified=true`, with
   [verification](verification.md) describing the scope and remaining limits.

A development unit upgraded over time does not replace fresh-rootfs acceptance.

## Remaining features

- **Suspend/resume:** qualify the shallow WFI timekeeping path in a long
  systemd-managed cycle with uninterrupted desktop input on the installed
  build. Handle Wi-Fi resume failures, then test the owner
  opt-in screen-off cycle and measure battery current.
  Keep sleep masked by default. See [suspend](hw/suspend.md).
- **Pack gauge:** establish live BQ78Z100 ACK and protocol before enabling it.
  Learned capacity and pack-temperature-informed charging depend on this.
  See [power hardware](hw/power.md).
- **Ambient light/proximity:** identify the i2c1 `0x49` part and its protocol
  before binding a driver. Keep AP/SCP pin ownership exclusive.
  See [sensors](hw/sensors.md).
- **Source power validation:** measure external VBUS current margin and
  thermals before increasing the conservative USB source allowance.
  See [USB](hw/usb.md).

## Upstreaming

Package recipes should remain conventional and reproducible. Kernel promotion
needs a released stable base with a reviewable patch series instead of a
rolling board branch. Split independent driver/config changes into signed-off
upstream submissions.

Move device installation/update policy out of packages or make it optional
where upstream requires that separation. Submit the UCM profile to
alsa-ucm-conf, and retire compatibility shims only after their removal is
tested with the selected package set.

Promotion beyond testing also needs a named maintainer, upstream CI and an
externally reproduced installation. This port uses its dedicated installer;
generic `pmbootstrap flasher` remains unsupported.
