# Suspend/resume

Current constraints and measurements for the *Suspend/sleep* row in
[README.md](../../README.md#hardware-support-at-a-glance). User policy is in the
[power guide](../power.md); remaining acceptance is in the
[roadmap](../roadmap.md#remaining-features).

## Current status

The installed kernel r63 (`#64-postmarketos-mediatek-mt6789`, 7.2.0-rc5)
passed automatic-return device and platform resume tests on 2026-09-30. The
OVL underflow/quarantine regression was resolved in these tests by restoring
physical memory routing and the overlay's proven FIFO policy after display
power loss. On 2026-10-01, the same build completed a real s2idle cycle and
woke through the PMIC power key. The owner confirmed the restored image.
Touch events also resumed, but a login-manager restart left GNOME without
input until the greeter was restarted. Automatic sleep remains unqualified.

Only `[s2idle]` is exposed in `/sys/power/mem_sleep`; hardware `deep` suspend
is unavailable. `sleep.target` and `suspend.target` remain masked, and
`/var/lib/dc1/enable-auto-suspend` remains absent. Wi-Fi still reports resume
`-EIO`, then recovers. There is no packaged RTC alarm backstop.

## Display restoration

Display-domain power loss reset two parts of the active DMA path:

- LARB0/1 port `MMU_EN` bits changed from zero to one although the DT has no
  enabled IOMMU and OVL submits physical addresses. Kernel `110d34e0792a`
  links physical-DMA overlays to their SMI suppliers and restores MMU bypass
  with checked readback. Active OVL0 holds LARB0 and SMI common; OVL2L/LARB1
  remain suspended because they are unused in the production path.
- OVL request limits, urgent requests and buffer thresholds reverted to
  reset values. The output-clamp bit also cleared. Routing restoration alone
  in r62 still produced first-frame status `0x4203` and quarantine. Kernel
  `2e706d50b9c8` caches this policy only after a successful first-frame check,
  then restores it with checked readback before later pipeline starts.

The observed request limits changed from `0xf1ff5555` to `0x41ffbbbb`, urgent
requests from `0x5555` to `0x20305555`, low thresholds from zero to `0x30020`,
and high thresholds from `0x80000000` to `0x40000`. FIFO controls and
second-stage GMC settings did not change. The fixes preserve the translated
DMA path and all first-frame underflow/quarantine checks. They are kernel-only
updates: the source pin, running DT, dtbswap stub and initramfs are preserved.

## Current-build stage validation (2026-09-30)

The r63 kernel and matching modules were built natively with LLVM 20. Local
installation verified package/image parity and inactive-slot readback; the
#64 boot confirmed the candidate slot and installed package/modules identities
while retaining the successful fallback. These are local-development results,
not acceptance of an exact published release artifact set.

With the panel on at 60 Hz, USB power connected and local recovery available:

| Stage | Return time | First frame | TE after resume |
| --- | --- | --- | --- |
| `devices` | 11.16 s | `0x4003`, no underflow | 59.18 Hz |
| `platform`, cycle 1 | 11.24 s | `0x4003`, no underflow | 59.18 Hz |
| `platform`, cycle 2 | 11.19 s | `0x4003`, no underflow | 59.18 Hz |
| `platform`, cycle 3 | 11.27 s | `0x4003`, no underflow | 59.18 Hz |

All cycles preserved active LARB0 physical routing, all ten OVL request/buffer
policy registers and the output-clamp bit. No first-frame failure or quarantine
was logged. TE alone is insufficient: it also continued after the unfixed
pipeline quarantined itself. The restored registers and successful first-frame
integrity checks establish memory-path restoration separately from
panel-controller liveness.
A human redraw/relight check remains outstanding.

Each cycle logged the known mt7921s resume `-EIO`; NetworkManager was connected
after testing. `suspend_stats` read success=4/fail=0 and failed_resume=4. These
counters include debug test cycles, not real sleep acceptance. The selector was
restored to `none`, temporary PM diagnostics were restored, and the one-shot
test service/timer was removed. These stage tests did not exercise real sleep.

## Full cycle with physical wake (2026-10-01)

With r63/#64, USB power connected and the owner beside the tablet, a one-shot
test wrote `mem` to `/sys/power/state` with `pm_test=none`. No sleep target
was unmasked and no automatic-sleep marker was created. The owner reported
the tablet sleeping and then pressed the power key.

The kernel completed noirq suspend, remained in that path for 1229.66 seconds
(about 20 minutes), and logged `Triggering wakeup from IRQ 152`. This is the
MT6358 PMIC parent interrupt; power-key press/release IRQ counts both
increased by one, while the hall and USB interrupt counts stayed unchanged.
The call returned successfully without a reboot, and the device-resume phase
took 4.33 seconds.

OVL's first frame completed with status `0x4003`; no underflow or quarantine
was logged. TE returned at 59.18 Hz, active LARB0 retained physical routing,
and OVL request limits/urgent requests remained `0xf1ff5555`/`0x5555`.
The known mt7921s resume `-EIO` triggered firmware recovery; NetworkManager
was connected after return. The success counter advanced from four to five,
with no suspend failure and one additional Wi-Fi resume failure.

`CLOCK_MONOTONIC` continued through this s2idle path, so subtracting it from
`CLOCK_BOOTTIME` did not measure time asleep. The interval above uses the
kernel's noirq-complete and wake-IRQ timestamps. It establishes physical wake,
not battery-current savings. Temporary PM diagnostics were restored and the
transient test unit exited.

### Desktop input failure after the long cycle

The owner confirmed that the display returned but the login screen ignored
touch. A non-grabbing libinput capture then recorded 123 touch-downs, 5096
motions and 119 touch-ups without errors. The controller was running, its
reset GPIO was high, and the IRQ/I2C event path was active; no touchscreen
driver reset or rebind was needed.

At resume, journald reported a three-minute software-watchdog timeout and
logind aborted with `SIGABRT`, then restarted. GNOME lost access to all five
input devices and its attempts to reopen them failed with `DeviceIsTaken`.
Restarting GDM at the greeter, with no logged-in user desktop, restored input
device access. The owner then confirmed touch worked and a user desktop was
active. This recovery does not qualify uninterrupted desktop input across
sleep; restarting GDM in a logged-in session would discard that session.

The shipped config has `CONFIG_CPU_IDLE` and `CONFIG_NO_HZ` unset. With no
cpuidle device, `cpuidle_idle_call()` takes `default_idle_call()` before the
s2idle path that calls `tick_freeze()` and suspends timekeeping. This agrees
with the observed monotonic clock continuing during sleep. Systemd 262's
[service watchdog uses CLOCK_MONOTONIC](https://github.com/systemd/systemd/blob/v262/src/core/service.c),
so expiry across the long frozen interval is a likely cause of these service
failures. The direct-sysfs test also bypassed systemd's sleep orchestration.
Resolve the clock/watchdog interaction and verify a systemd-managed long
cycle before enabling automatic sleep; do not disable watchdog protection as
a substitute. No kernel input-driver change was made for this incident.

## Test and recovery constraints

For s2idle, automatic-return `pm_test` supports `freezer`, `devices` and
`platform`. The kernel rejects `processors` and `core` with `-EAGAIN` before
testing them. Device tests can break display resume even though they return
without a wake event; establish local recovery before using them.

Keep configfs gadget objects bound. Removing gadget functions can wedge tasks
in D state and prevent freezing. A freezer-only pass does not prove device
resume or a wake path.

The external S35390A RTC supplies timekeeping only. Its unusable board alarm
IRQ was removed in r48 after an IRQ storm; see the [RTC reference](power.md#rtc).
`CONFIG_RTC_DRV_MT6397` remains unset. A temporary MT6358 RTC module fired a
20-second alarm while Linux was awake on 2026-09-25, but was not packaged and
was lost at reboot. Neither observation proves wake from s2idle.

The PMIC power key woke the current build from real s2idle as recorded above.
Other unverified candidates include the PMIC RTC, USB gadget and hall switch.
The hardware watchdog is **not** a timed recovery path:
`mtk_wdt_suspend()` stops it and restarts it only after resume.

## Automatic sleep and remaining acceptance

The enabled `dc1-sleep-on-blank` service stays inactive without the opt-in
marker. It requests sleep once per screen-off cycle after DRM and both
frontlights have been off for 60 seconds on battery. It unmasks the package's
sleep targets immediately before its first request. Keep the marker absent
until the installed build has a verified full cycle and physical wake path.

Next resolve long-cycle timekeeping/software-watchdog failures, verify a
systemd-managed cycle with uninterrupted desktop input, then test the owner
opt-in screen-off cycle and measure battery current while asleep. Fix or
explicitly scope the remaining mt7921s resume failure; stage tests alone do
not justify enabling automatic sleep.
