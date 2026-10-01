# Suspend/resume

Current constraints and measurements for the *Suspend/sleep* row in
[README.md](../../README.md#hardware-support-at-a-glance). User policy is in the
[power guide](../power.md); remaining acceptance is in the
[roadmap](../roadmap.md#remaining-features).

## Current status

The installed kernel r65 (`#66-postmarketos-mediatek-mt6789`, 7.2.0-rc5)
passed automatic-return display tests and two systemd-managed s2idle cycles
on 2026-10-02. The packaged MT6358 RTC alarm woke both cycles automatically.
The longer cycle recorded 237.2 seconds asleep with timekeeping frozen,
unchanged logind/journald/GDM processes and retained GNOME input access.
Physical display/touch confirmation on this build remains outstanding.

Only `[s2idle]` is exposed in `/sys/power/mem_sleep`; hardware `deep` suspend
is unavailable. Battery-current savings have not been measured. Automatic
sleep remains opt-in: `sleep.target` and `suspend.target` are masked and
`/var/lib/dc1/enable-auto-suspend` is absent. Wi-Fi still reports resume
`-EIO`, then recovers.

## Display restoration

Display-domain power loss reset two parts of the active DMA path:

- LARB0/1 port `MMU_EN` bits changed from zero to one although the DT has no
  enabled IOMMU and OVL submits physical addresses. Kernel `110d34e0792a`
  links physical-DMA overlays to their SMI suppliers and restores MMU bypass
  with checked readback. Active OVL0 holds LARB0 and SMI common; OVL2L/LARB1
  remain suspended because they are unused in the production path.
- OVL request limits, urgent requests and buffer thresholds reverted to
  reset values. The output-clamp bit also cleared. Kernel `2e706d50b9c8`
  caches this policy only after a successful first-frame check, then restores
  it with checked readback before later pipeline starts.

The observed request limits changed from `0xf1ff5555` to `0x41ffbbbb`, urgent
requests from `0x5555` to `0x20305555`, low thresholds from zero to `0x30020`,
and high thresholds from `0x80000000` to `0x40000`. FIFO controls and
second-stage GMC settings did not change. The fixes preserve the translated
DMA path and all first-frame underflow/quarantine checks. These are
kernel-only updates; the running DT, dtbswap stub and initramfs are preserved.

## Timekeeping and desktop input

A previous 20-minute r63 cycle woke with the power key and restored the image,
but journald's three-minute watchdog expired and logind restarted. GNOME lost
its input descriptors and could not reopen them until GDM was restarted at
the greeter. The touchscreen controller was still delivering valid events.
Restarting GDM in a logged-in session would discard that session.

With `CONFIG_CPU_IDLE` unset, `cpuidle_idle_call()` used `default_idle_call()`
before the s2idle path that freezes the tick. `CLOCK_MONOTONIC` continued
through sleep while userspace was frozen. Systemd 262's
[service watchdog uses CLOCK_MONOTONIC](https://github.com/systemd/systemd/blob/v262/src/core/service.c).

The board-gated `jagar_wfi` driver now registers architectural
`cpu_do_idle()` WFI on all eight CPUs, preserving interrupt masking. Its
second state, `WFI-S2`, supplies `enter_s2idle` so the cpuidle core can freeze
the tick and timekeeping; state zero is excluded from s2idle selection.
`suspend.config` requires `CONFIG_CPU_IDLE=y` and
`CONFIG_ARM_JAGAR_CPUIDLE=y`. No new PSCI state or device-tree change is
needed. High-resolution timers, the periodic awake tick and service watchdogs
are retained.

## Current-build validation (2026-10-02)

The r65 kernel and matching modules were built natively with LLVM 20. The
packaged config includes the WFI driver and `CONFIG_RTC_DRV_MT6397=m`.
Installation verified kernel/package parity and the complete 64 MiB inactive
slot readback. The candidate boot confirmed slot a, keeping the successful
r64 slot b as fallback. These are local-development results; they do not
qualify an exact published release artifact set.

With USB power connected and the panel on at 60 Hz, automatic-return tests
passed `devices` once and `platform` three times. Return times were
11.15–11.26 seconds. All four preserved active LARB0 physical routing, all
ten OVL request/buffer policy registers and the output-clamp bit. First-frame
status was `0x4003`, with no underflow or quarantine, and TE was 59.18 Hz.

The PMIC RTC registered automatically as `rtc1`, while the built-in S35390A
remained `rtc0` and the boot-time clock source. The PMIC clock was synchronized
to the system clock before testing. A 20-second awake alarm produced one RTC
alarm interrupt (`RTC_AF`) and disarmed correctly. Then a one-shot helper
armed and read back each alarm, temporarily lifted the sleep masks and
requested `systemctl suspend`:

| Alarm delay | Recorded sleep | Monotonic elapsed | Boottime elapsed |
| --- | --- | --- | --- |
| 30 s | 26.608 s | 15.455 s | 42.063 s |
| 240 s | 237.205 s | 15.639 s | 252.844 s |

Elapsed values include suspend preparation, device resume and an eight-second
post-resume observation. Sleep is the increase in `CLOCK_BOOTTIME` minus the
increase in `CLOCK_MONOTONIC`. Kernel printk timestamps therefore no longer
measure the time asleep.

Both cycles received exactly one RTC alarm interrupt and logged wake from
MT6358 parent IRQ 152. Power-key IRQ counts did not change. Every CPU's
`WFI-S2` s2idle usage counter increased. Logind, journald and GDM retained
their PIDs with zero restarts; GNOME retained the same process and all five
input-device descriptors. No display quarantine or first-frame failure was
logged; first-frame status was `0x4003`. After the long cycle, TE was 59.18 Hz
and OVL policy/physical LARB0 routing still matched the stage-test baseline.
These checks establish service/input access and display-path restoration;
human relight, redraw and touch checks remain necessary.

The known mt7921s resume `-EIO` occurred in each test; NetworkManager was
connected after both real cycles. Final `suspend_stats` showed success=6,
fail=0 and failed_resume=6, including the four debug cycles. Alarms were
cleared, the sleep masks restored, PM diagnostics restored to zero and the
boot-time test service/timer removed. The automatic-sleep marker was never
created.

## Test and recovery constraints

For s2idle, automatic-return `pm_test` supports `freezer`, `devices` and
`platform`. The kernel rejects `processors` and `core` with `-EAGAIN` before
testing them. Device tests can break display resume even though they return
without a wake event; establish local recovery before using them.

Keep configfs gadget objects bound. Removing gadget functions can wedge tasks
in D state and prevent freezing. A freezer-only pass does not prove device
resume or a wake path.

The external S35390A supplies timekeeping only; its unusable board alarm IRQ
stays disabled. The packaged PMIC RTC supplies the verified timed wake path;
see the [RTC reference](power.md#rtc). Before another timed test, identify the
PMIC RTC, check its clock and wake-enable state, refuse an existing alarm,
and verify the new alarm's readback. Clear the alarm and restore the original
sleep policy after the test. Do not rely on an RTC number without checking
its name. USB gadget and hall-switch wake remain unqualified.

The PMIC power key woke r63 from real s2idle. The hardware watchdog is **not**
a timed recovery path: `mtk_wdt_suspend()` stops it until resume.

## Automatic sleep and remaining acceptance

The enabled `dc1-sleep-on-blank` service stays inactive without the opt-in
marker. It requests sleep once per screen-off cycle after DRM and both
frontlights have been off for 60 seconds on battery. It unmasks the package's
sleep targets immediately before its first request. Keep the marker absent
until physical display/touch behavior and owner wake behavior are verified
on the installed build.

Next confirm physical relight/redraw and touch, handle or explicitly scope
Wi-Fi's resume failure, then test the owner opt-in screen-off cycle and
measure battery current while asleep. RTC wake and frozen timekeeping do not
establish hardware deep sleep or power savings.
