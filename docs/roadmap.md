# Roadmap — what "complete" means for this port

The status table in [status.md](status.md) says what works *today*. This
page says what is left, organized as three tiers: each tier is a
definition of done for a progressively stronger claim. Every item names
what it needs — a first boot carrying newer packages than the device
runs, actual hands, or an external user. Nothing here writes a partition
or touches slots; run as the normal user unless a step says otherwise.

## Current dmesg triage (2026-08-28, live kernel r46)

The warning-level ring was normalized by signature and checked against
live subsystem state. Counts below are from a roughly nine-minute boot;
rate-limited messages understate the underlying event rate. This is a
remediation queue, not a claim that every line is a user-visible failure.

| Priority / category | Signatures | Assessment and exit criterion |
| --- | --- | --- |
| **Closed P0 interrupt storm — hardware-verified in r48** | `rtc-s35390a ... alarm IRQ with INT2 flag clear` (750 printed, 74 suppression notices on r46); GPIO14 rose by 984 interrupts in 2 s | About 492 IRQ/s was a CPU/idle-power and diagnostics defect. Kernel `8f0bfe8f8a4c` stops registering the unusable board alarm IRQ while retaining RTC timekeeping. On the 2026-08-28 r48 boot, at 10m15s uptime: no `8-0030` IRQ existed in `/proc/interrupts`, no S35390A alarm/error line had appeared, the driver had set the system clock from the RTC, and its sysfs clock was advancing. Closed; keep this row as the baseline for later dmesg audits. |
| **P1 real but currently non-blocking hardware gaps** | SCP `invalid resource` (10); PMIC auxadc/key child probe failures; `fhctl` clocks, `socinfo`, display `mboxes`; missing audio pinctrl states / `Playback_12`; one MUSB `VBUS_ERROR` | These expose incomplete DT/driver descriptions even where the primary desktop path works. Triage one subsystem at a time against its `docs/hw/` record; close only when the relevant function is exercised and its signatures disappear without regressing it. USB role errors get first attention if the hub session reproduces them; SCP stays behind suspend and sensorhub work. |
| **P2 known absent hardware** | `bq78z100-0` `-ENXIO` property/uevent spam (30 printed plus suppression); its thermal zone disables itself | The pack gauge does not ACK at `0x55`; this is known hardware/bus reality, not a transient probe. Suppress the phantom DT node so it cannot pollute power-supply UI or logs, while preserving the measured MT6358 voltage-based fallback. Re-enable only with a live ACK/protocol measurement. |
| **P3 expected probe/takeover noise** | SD/MMC discovery commands, one UFS DME attribute failure, simplefb region conflict, initramfs UDC busy, CPU dummy supplies, unused clock/domain/regulator notices | Storage, DRM, gadget handoff and regulator-free CPU DVFS are live. Keep as baselines; investigate only if the associated function fails or a message repeats after steady state. The initramfs UDC retry should eventually be made quiet without weakening its fatal final check. |
| **P4 userspace/kernel-policy cleanup** | missing `autofs4`; journald BPF-firewall and ACL warnings; unsupported `bootconfig` command-line token | No hardware failure. Align packaged systemd/kernel config and remove the inherited boot token when its LK source is understood; acceptance is a clean boot without weakening journald persistence, sandboxing, or the boot path. |

The capture also contains successful `dc1-boot-watchdog` and initramfs
handoff messages because those facilities log at warning priority; they
are state reports, not errors, and are excluded from the queue.

## Tier 1 — close the open hardware-verification items

Each item is one boot or one hands-on session. When one closes, update
the linked `docs/hw/` record and the [verification.md](verification.md)
ledger in the same change.

### Audio — one-time physical probe (needs explicit permission)

The speakers are loud; never run audio without the owner's explicit
go-ahead. With permission, once per hardware:
`speaker-test -D hw:0,0 -c2` closes the PCM0=DL1 physical probe.
Everything else in audio is closed, including the idle-gain shadow fix
(verified 2026-08-26 on the r37 boot). If the wireplumber journal ever
says `UCM not available for card`, apply the fallback relabel rule
(matched on `alsa.card_name="mt6789-mt6366"`, never the numeric index)
and bump the device pkgrel. Details: [hw/audio.md](hw/audio.md).

### Pen digitizer (needs a boot of kernel ≥ pkgrel 41, then hands)

The edge-misalignment root cause (stale `prop.max_*` inversion pivot in
`wacom_i2c`) is fixed in r38, and the eraser-as-pen root cause (tool
latched on proximity entry, ignored mid-proximity flips) is fixed in
r41 — both compile/DTB-verified only. After booting r41 or newer: draw
in Rnote or Xournal++ across the glass edges and corners — ink must
land under the nib everywhere — and flip the pen: the eraser end must
erase (only tablet-v2 apps show tool switching), including a flip made
quickly while hovering. If edges still miss, refit the visible envelope
from new correspondence taps against the now-straight chain; do not
re-open calibration generally. Details: [hw/input.md](hw/input.md).

### Rotation tilt test (never yet performed — needs hands)

Sanity first:
`cat /sys/devices/platform/soc/1101a000.i2c/i2c-6/6-004c/iio:device0/name`
must read `mc3416`, `busctl --system get-property net.hadess.SensorProxy
/net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer` must
read `true`, and (root) `in_mount_matrix` should still read
`0, -1, 0; -1, 0, 0; 0, 0, -1`. If `/proc/device-tree/model` is wrong
instead, the stock DT booted and the dtbswap handoff needs inspecting —
do not reflash. Then hold each edge-up pose at least three seconds while
watching `AccelerometerOrientation` follow the physical quadrant (a
natural portrait hold is calibrated to read `bottom-up`). Expect paired
journal lines within about a second per tilt — iio-sensor-proxy's
orientation emit followed by `dc1-orientation: <label> -> transform N` —
with content ending upright and touch tracking in all four poses, and
returning to the start pose restoring the picture. An animated ~260 ms
transition means mutter finally claimed the sensor (then watch for
double-apply races); an instant snap with exactly one `ClaimAccelerometer`
this boot means the bridge-only path drove it and mutter's orientation
manager is still dormant. Judge poses by sign/dominance, never magnitude
(`in_accel_scale` implies ~10 g at rest). Details:
[hw/sensors.md](hw/sensors.md).

### Power key — first human exercise (needs hands)

Short press must lock (shield up) and DPMS-off the panel; the next short
press wakes to the lock screen; a ≥2 s hold opens GNOME's power menu with
restart / power off. Watch that the first press does not double-apply
(blank then immediate wake) and that an untouched shield re-darkens
after ~10 s. The event path is proven by the working menu grab; what
needs hands is only whether the feel/timing matches a phone. Details:
[hw/input.md](hw/input.md).

### Bluetooth — one session (needs a boot of device ≥ r65's boot image + a peer)

After a boot whose initramfs stages `BT_RAM_CODE_MT7902_1_1_hdr.bin`:
hci0 must complete setup with
**no** `Failed to setup 79xx firmware` line (the race won outright),
`bluetoothctl show` reporting the controller up, and
`dc1-bluetooth.service` inactive because its dmesg gate held. On older
images the service may still recover the controller once — that is the
repair path doing its job. Then: enable pairable, pair a peer, stream
A2DP, and close the row. Details: [hw/wireless.md](hw/wireless.md).

### USB gadget — SSH over ECM end-to-end (needs a USB host)

Plug a USB host into the port; `usb0` should carrier-up. From the host:
`ssh <user>@172.16.42.1` (password set at install). That single command
closes the row. Details: [hw/usb.md](hw/usb.md).

### USB host — packaged-kernel boot and gadget return (needs r49 and a PC)

The live register A/B on 2026-08-28 proved the charging hub reaches data
host / power sink and enumerates once the T-PHY receives valid UTMI session
inputs. Boot linux r49, attach the hub, and confirm that packaged behavior
without a manual register write. Then unplug the hub, attach a PC, and prove
`usb0`/ECM returns without restarting `dc1-usb-gadget`. Do not unbind the UDC
or remove configfs objects during the session. Details:
[hw/usb.md](hw/usb.md).

### Charging mode — calibration session (needs a power cycle; owner only)

Power the device off cleanly, plug USB power, and confirm the device
stays dark (charging target) rather than booting the desktop. Then from
a booted session (power-key exit or afterwards): read the LK ring —
`dd if=/dev/mem bs=4096 skip=$((0x7ffbf000/4096)) count=64 | strings |
grep -E 'BOOT_REASON|jump to linux'` — and confirm the LAST
`BOOT_REASON:` line reads `1` (USB charger) with the `jump to linux
kernel 64Bit` tail marker present. Optionally pin the MT6358 CHRIN bit
via the `000c:` line of the PMIC regmap under debugfs as a
second opinion. Until this session happens, the feature stays
`hardware_verified=false`. Details: [hw/power.md](hw/power.md).

## Tier 2 — flip the honesty flags

1. **One end-to-end fresh install from a published release, executed on
   hardware.** Flash `installer-boot.img` from the rolling release,
   walk the touch installer, first boot, first `dc1-update` convergence.
   This exercises paths that have never run end-to-end: installer
   delivery of the GNOME shim set (the shims are verified, their
   delivery is not — [gnome.md](gnome.md)), and the full release
   artifact chain as published.
2. After that, a release may record `hardware_verified=true` **for the
   artifact set actually booted** (kernel pkgrel, device pkgrel, boot
   image hash — see `PROVENANCE`), with the
   [verification.md](verification.md) ledger as the fine print.
3. The README hardware table reaches all ✅ except deliberate,
   documented limits (suspend; ALS) — or those close too (see the
   feature track).

## Tier 3 — upstream complete

Assessment 2026-08-23 of what separates this port from leaving
`device/testing` (documented only; no MR without explicit approval).

Already upstream-shaped: no proprietary blobs anywhere in the port —
MT7902 Wi-Fi/Bluetooth firmware and `regulatory.db` are fetched from
upstream at build time under exact size + SHA-256 pins; the kernel
compiler boundary is plain clang/LLVM; the device package follows the
normal pmbootstrap layout; and the overlay scope is small. The
mutter-mobile recipe's staging into the upstream systemd extra repo is a
prepare.sh concern, not a packaging deviation.

**Blocking, kernel side:** the source is a rolling `jagar` branch pinned
by commit, while upstream pmaports expects linux-* recipes built from
released stable trees with a reviewable patch series. Until the jagar
work is expressed as a series against such a base, the kernel package
cannot move. The individually upstreamable pieces are clear: the mt6358
shadow-read fix (`6e54631d`), the wacom_i2c
OF/reset/power-sequencing/resolution/visible-area work, tcpci_mt6375,
the mt6375-charger AICR policy, the MC3416 compatible, and the config
fixes (REGULATOR_GPIO, USB). Each needs its own mailing-list thread with
sign-off discipline; none blocks on another.

**Blocking, device side:** operating policy no upstream device package
would carry must move out or become optional — dc1-update.timer with its
parity gates, dc1-boot-sync references, postboot-checks.sh,
install-specific gschema overrides, and the dmesg-gated bluetooth
repair service (which should dissolve once initramfs staging proves the
race is won). The UCM2 profile belongs in upstream alsa-ucm-conf once
hardware-verified, not in the device package forever. None of this
blocks an MR *into* `device/testing` quality-wise — much of it already
landed there — but it blocks promotion beyond testing and inflates
review surface.

**Blocking, evidence:** releases honestly say `hardware_verified=false`
until tier 1 closes. With a single public unit, the mitigation for
reviewer skepticism is measurement depth: docs/status.md (plus the
docs/hw/ records) should travel with any MR as the wiki page's backbone.

**Process shape:** pmaports merge request against master, green CI, a
named maintainer, and a demonstrated generic pmbootstrap install. That
last one this device satisfies structurally — the installer writes only
`boot_a`, `userdata`, and the boot-control bytes in `misc`, never
authenticated partitions — but nobody outside this repository has
executed it yet; one external install attempt would be worth more than
any amount of internal verification.

## Feature track (beyond verification)

Ordered by user value per effort:

1. **Suspend/resume** — the one ❌ in the README table and the biggest
   battery/UX win for a tablet. Escalation plan in
   [hw/suspend.md](hw/suspend.md): pm_test level by level, establish a
   wake path (PMIC RTC `rtc-mt6397` support for mt6358, or verified
   gadget/hall wake), absorb the mt7921s resume `-EIO`, then unmask
   sleep targets behind owner opt-in.
2. **BQ78Z100 pack gauge (P7.1)** — hardware item (pack connector SMBus
   pair or the gauge's I²C block). Unlocks learned capacity, persistent
   SoC across reboots, and temperature-informed adaptive charge-current
   control. [hw/power.md](hw/power.md).
3. **ALS driver for the i2c1 `0x49` part** — auto-brightness on a
   reflective panel (frontlight is the main power draw). The AP now owns
   the bus and ships a write-free ACK probe, but implementation remains
   blocked on exact part ID and protocol (MEMSic `mn29xxx` family;
   possibly only reachable with SCP context). [hw/sensors.md](hw/sensors.md).
4. **Phantom `bq78z100-0` power-supply suppression** — repeated PSU
   property/uevent errors plus enumeration pollution; small DT change,
   but preserve the voltage-based battery fallback.
5. **Surfaces for owner levers** — a Settings panel or extension for the
   flag opt-outs and charge-rate sysfs, so end users do not need shell
   flags ([../power.md](power.md) documents the current levers).
6. **Kernel patch series for the lists** — the tier-3 kernel items,
   split per driver, are also standalone upstream contributions and can
   start any time.
