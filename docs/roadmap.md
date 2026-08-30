# Roadmap — what "complete" means for this port

The status table in [README.md](../README.md#hardware-support-at-a-glance) says what works *today*. This
page says what is left, organized as three tiers: each tier is a
definition of done for a progressively stronger claim. Every item names
what it needs — a first boot carrying newer packages than the device
runs, actual hands, or an external user. Nothing here writes a partition
or touches slots; run as the normal user unless a step says otherwise.

## Current dmesg triage (r50 baseline, closures rechecked on r54)

The warning-level ring was normalized by signature and checked against
live subsystem state. Counts below are from a roughly nine-minute boot;
rate-limited messages understate the underlying event rate. This is a
remediation queue, not a claim that every line is a user-visible failure.

| Priority / category | Signatures | Assessment and exit criterion |
| --- | --- | --- |
| **Closed P0 interrupt storm — hardware-verified in r48** | `rtc-s35390a ... alarm IRQ with INT2 flag clear` (750 printed, 74 suppression notices on r46); GPIO14 rose by 984 interrupts in 2 s | About 492 IRQ/s was a CPU/idle-power and diagnostics defect. Kernel `8f0bfe8f8a4c` stops registering the unusable board alarm IRQ while retaining RTC timekeeping. On the 2026-08-28 r48 boot, at 10m15s uptime: no `8-0030` IRQ existed in `/proc/interrupts`, no S35390A alarm/error line had appeared, the driver had set the system clock from the RTC, and its sysfs clock was advancing. Closed; keep this row as the baseline for later dmesg audits. |
| **Closed P1 log-noise fixes — boot-verified on r54 (2026-08-29)** | SCP `invalid resource` (10); PMIC auxadc/key child probe failures; `fhctl` clocks, `socinfo`, display `mboxes`; missing optional audio pinctrl states | Kernel `ffd5800b0ba3` removes the false optional-resource errors, redundant PMIC child, disabled-FHCTL lookup, unsupported socinfo probe, absent optional DRM mailbox request and optional audio-state warnings. It also removes stale PMIC-wrapper bring-up errors. Acceptance met on the live r54 boot (2026-08-29): zero `invalid resource` lines, no `fhctl`/`socinfo` signatures, PMIC keys registered (`mt6358-keys` input), display and audio live. The r46 MUSB `VBUS_ERROR` remains closed: packaged r50 enumerated the same dock with no VBUS or over-current error. |
| **Closed P2 known absent hardware — hardware-verified in r50** | `bq78z100-0` `-ENXIO` property/uevent spam (30 printed plus suppression); its thermal zone disables itself | The pack gauge does not ACK at `0x55`; this is known hardware/bus reality, not a transient probe. Kernel `15fd2e78b746` disables the production DT node while preserving the measured MT6358 voltage-based fallback. On the r50 boot, only the three intended power supplies and 15 real thermal zones registered, with no BQ signature in dmesg. Re-enable only with a live ACK/protocol measurement. |
| **P2 desktop fixes closed on r54; external-hub reconnect still pending** | hub `activate --> -11`; missing FUSE, Landlock/BPF-LSM, uinput/uhid and Bluetooth BNEP/RFCOMM; absent core/sysrq/SYN-cookie sysctls; orientation's early Mutter traceback; invalid WWAN key and unused ModemManager plugin ABI warnings | A live r52/r87 boot on 2026-08-28 confirmed FUSE/uinput/uhid, sysctls, orientation, Bluetooth state, the ModemManager condition, and a successful A/B boot. The live r54/device r90 audit on 2026-08-29 then closed its securityfs+BTF and LocalSearch loader follow-ups: systemd's BPF-LSM policy and the Landlock-confined extractors ran without the earlier failures. Only the physical USB-hub reconnect check remains open for this row; the Lenovo 40B0 downstream-connect limitation remains a separate hardware compatibility item. |
| **P3 expected probe/takeover noise** | SD/MMC discovery commands, one UFS DME attribute failure, simplefb region conflict, CPU dummy supplies, unused clock/domain/regulator notices; one `Playback_12` open of an intentionally unrouted FE | Storage, DRM, working UCM routes and regulator-free CPU DVFS are live. Keep as baselines; investigate only if the associated function fails or a message repeats after steady state. The initramfs now tries the hardware-observed `musb-hdrc.4.auto` UDC first; verify the four failed binds and final `UDC bind failed` line disappear on the next boot. |
| **Closed P4 desktop-log fixes — boot-verified on r54 (2026-08-29)** | missing `autofs4`; journald BPF-firewall and ACL warnings; unsupported `bootconfig` command-line token | Kernel `ffd5800b0ba3` enables autofs, cgroup BPF/BPF syscalls, ext4 POSIX ACLs and bootconfig. Acceptance met on the live r54 boot (2026-08-29): `bootconfig` parsed cleanly (`Load bootconfig: 588 bytes 41 nodes`), no missing-`autofs4` line, no journald BPF-firewall or ACL warnings, with journald persistence, sandboxing and the boot path intact. |

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

### Pen digitizer (r54 is running; hands still owed)

The edge-misalignment root cause (stale `prop.max_*` inversion pivot in
`wacom_i2c`) is fixed in r38, and the eraser-as-pen root cause (tool
latched on proximity entry, ignored mid-proximity flips) is fixed in
r41. Both fixes are present on the live r54 build, but their physical behavior
has not had the final hands-on check. Draw
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

### Quick Action / Back Button — physical key confirmation (needs hands)

Press each spare side button once while watching `wev` or `evtest`. Quick
Action must arrive as `XF86Launch1`/`KEY_PROG1`, and Back Button as
`XF86Launch2`/`KEY_PROG2`; then confirm the shipped screenshot and overview
shortcuts fire once each. This closes the last yellow portion of the Buttons
row. Details: [hw/input.md](hw/input.md).

### GNOME session lifecycle — logout and greeter (needs hands)

Log out of the owner session, confirm gdm's Wayland greeter appears with its
on-screen keyboard, log back in, and confirm the three DC-1 shell extensions
and orientation bridge recover after the compositor replacement. This is
separate from autologin: the greeter path was once observed aborting during
the GNOME migration and has not been exercised on the converged GNOME-50
stack. Run only with a working USB recovery path. Details: [gnome.md](gnome.md).

### Bluetooth — one session (needs a boot of device ≥ r65's boot image + a peer)

After a boot whose initramfs stages `BT_RAM_CODE_MT7902_1_1_hdr.bin`:
hci0 must complete setup with
**no** `Failed to setup 79xx firmware` line (the race won outright),
`bluetoothctl show` reporting the controller up, and
`dc1-bluetooth.service` active (exited) with no rebind evidence because
its dmesg gate held; the oneshot intentionally remains active after a
no-op. On older images the service may still recover the controller once
— that is the repair path doing its job. Then: enable pairable, pair a
peer, stream A2DP, and close the row. Details:
[hw/wireless.md](hw/wireless.md).

### USB gadget — SSH over ECM end-to-end (needs a USB host)

Plug a USB host into the port; `usb0` should carrier-up. From the host:
`ssh <user>@172.16.42.1` (password set at install). That single command
closes the row. Details: [hw/usb.md](hw/usb.md).

### System initramfs — clean UDC bind (needs the next ordinary boot)

On the next normal boot, inspect the initramfs log and require the first bind
to use the hardware-observed `musb-hdrc.4.auto` UDC, with no earlier failed
candidate binds and no final `UDC bind failed`. The currently running system
predates that candidate-order fix; checking files on disk cannot close a boot
handoff claim. Details: [hw/usb.md](hw/usb.md).

### USB host — downstream peripheral and gadget return (needs a USB 2.0 hub and a PC)

The live register A/B on 2026-08-28 proved the charging hub reaches data
host / power sink and enumerates once the T-PHY receives valid UTMI session
inputs. Linux r50 reproduced that packaged behavior without a manual register
write. The attached Lenovo 40B0 Thunderbolt dock enumerated its internal hub,
MCU, and Billboard interface but did not assert connection on any otherwise
empty powered downstream hub port, even after port-power and full-hub resets.
The same session's second attach exposed a separate PIO-MUSB bug: the false
`HCD_DMA` flag made usbcore reject the hub status URB with `-EAGAIN`.
Kernel `05abbc2ae75c` removes that flag for PIO-only builds; verify repeated
detach/attach and post-enumeration device hotplug on the next boot.
Use an ordinary USB 2.0-capable charging hub next and prove a keyboard or mouse
enumerates. Then unplug the hub, attach a PC, and prove `usb0`/ECM returns
without restarting `dc1-usb-gadget`. Do not unbind the UDC or remove configfs
objects during the session. Details: [hw/usb.md](hw/usb.md).

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
2. Close or explicitly scope every Tier 1 hardware row against the same
   release. A successful install alone does not prove its USB host return,
   Bluetooth peer, physical controls, greeter, or charging-boot calibration.
3. After that, a release may record `hardware_verified=true` **for the
   artifact set actually booted** (kernel pkgrel, device pkgrel, boot
   image hash — see `PROVENANCE`), with the
   [verification.md](verification.md) ledger as the fine print.
4. The README hardware table reaches all ✅ except deliberate,
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
until tiers 1 and 2 close for one exact published artifact set. With a single public unit, the mitigation for
reviewer skepticism is measurement depth: README.md (plus the
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

1. **Suspend/resume** — the biggest open item in the README table and the
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
4. **Owner control surfaces — completed in device r92.** Charging Profile
   shows live PD/charger state, selects the 2.00/3.15 A charge-current target,
   and exposes authenticated Charging mode and Automatic updates switches.
   The existing marker/sysfs interfaces remain documented in
   [power.md](power.md).
5. **Kernel patch series for the lists** — the tier-3 kernel items,
   split per driver, are also standalone upstream contributions and can
   start any time.
