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
| Charging display | Validate r116's DRM handoff: firmware image clears and panel TE stops with frontlights off; repeat charging entry/exits on an exact published release | [Power hardware](hw/power.md) |
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

- **Suspend/resume:** confirm physical relight/redraw and touch on the
  build with verified RTC wake, then qualify owner power-key wake. Handle
  Wi-Fi resume failures, test the owner opt-in screen-off cycle and measure
  battery current.
  Keep sleep masked by default. See [suspend](hw/suspend.md).
- **Pack gauge:** establish live BQ78Z100 ACK and protocol before enabling it.
  Learned capacity and pack-temperature-informed charging depend on this.
  Mainline `bq27xxx_battery` already supports the part. Collect the
  [read-only I2C survey](../tools/i2c-survey/README.md) on battery and
  while charging; if `0x55` stays silent on every bus, try a 100 kHz test
  overlay before treating the pack connector as a hardware fault.
  See [power hardware](hw/power.md).
- **Ambient light/proximity:** qualify the native raw ALS driver across cold
  boots and sensor faults, calibrate the reflective display's light policy,
  and identify a safe proximity configuration before exposing that channel.
  Keep AP/SCP pin ownership exclusive. See [sensors](hw/sensors.md).
- **Secondary charger:** RT9471 stays unbound. The mainline driver resets the
  chip, sets `CHG_EN`, clears JEITA and enables BC1.2 detection at probe, so
  it is not a safe first bind. Gates, in order: survey evidence (ID, GPIO151
  pad level, VBUS-good while plugged), a working pack-temperature source, a
  driver variant that leaves those bits alone, and a bench trial capped at
  1 A with external current and temperature measurement.
- **Single-charger shortfall:** on 2026-10-14 (linux r65), a 9 V/3 A contract
  with a 3.15 A charger target delivered 1.79–1.93 A into the pack at
  20 % with the warmest zone at 38.5 °C, against about 2.94 A measured at the
  12 V contract on 2026-08-23. Explain this (input power, regulation loop or
  calibration) before any second charge path. A loaded 2026-10-18 session
  confirmed lower current with the main charger's own ADC and a 99–100 °C
  charger junction; MIVR was inactive after reconnect. Repeat with low system
  load and an external meter to distinguish system demand from thermal
  regulation. The r67 decimal-rounding correction still needs live readback.
- **Source power validation:** measure external VBUS current margin and
  thermals before increasing the conservative USB source allowance. The only
  hard limit is the MT6375 boost current-limit field (`OTG_C`, code 0 in
  `mt6375-source-role.patch`), whose current mapping is undocumented. The
  device cannot measure VBUS or see boost overcurrent, so use an inline
  USB-C meter and load; raise `OTG_C` before the PDO. Also confirm the
  charger input is not reprogrammed from our own source contract.
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
