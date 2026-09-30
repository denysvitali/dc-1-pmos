# Suspend/resume — measurement record

Deep-dive for the status-table row *Suspend/resume* in
[README.md](../../README.md#hardware-support-at-a-glance). User-facing consequences are in
[../power.md](../power.md); this page is the record. Newest facts last.

## Where it stands

**A full s2idle cycle completed on 2026-08-19** (mainline DT): `echo mem`
entered s2idle, the device woke (a USB-gadget wakeup likely fired first),
and `PM: suspend exit` returned rc=0 with the freezer clean. One wart:
mt7921s failed its resume callback with -EIO, then mac80211
re-authenticated by itself ~2.5 s later and Wi-Fi came back with the same
address — annoying, self-healing, unfixed. Panel state after resume not
yet observed by a human. The sleep targets stay **masked** — unmasking
trades remote reachability for battery and is an owner decision, now an
informed one.

## Freezer and USB safety

Never tear down configfs gadget functions: removal can wedge tasks in D state
and prevent freezing. Keep the gadget bound and let the kernel handle role
changes. The freezer-only `pm_test` path has passed; this does not prove device
resume or full suspend.

## What remains

The current kernel exposes only `[s2idle]` in `/sys/power/mem_sleep`;
hardware `deep` suspend is unavailable. For s2idle, the supported automatic-return
`pm_test` stages are `freezer`, `devices`, and `platform`. The kernel rejects
`processors` and `core` with `-EAGAIN` before testing anything. Device stages
can leave the display unusable even though the test returns automatically;
establish local recovery access before running them. A proven wake source is
needed before real `mem` testing.

**Updated 2026-08-28: the previously claimed RTC wake backstop does not
exist.** The `rtc-s35390a` at i2c-8 is `rtc0`; its newly added alarm path
provokes about 492 IRQ/s from a line that never reports an INT2 event, so
kernel r48 deliberately removes that unusable board IRQ while retaining
timekeeping. The MT6358 PMIC RTC still does not register, so a timed wake
cannot be armed (see [power.md](power.md)). Candidate wake paths to
establish before real-mem testing: the PMIC power key, the PMIC RTC
(`rtc-mt6397` family support for mt6358), the USB gadget, or the hall
switch. The power-key child declares `wakeup-source`, and
`mtk-pmic-keys` enables its PMIC IRQ for suspend; that is a configured
path, not a live wake result.

Enabled wakeup sources on the r54 boot (2026-08-29): the hall switch, the
USB gadget (`musb-hdrc`), the MT7902 SDIO function (`mmc1`), the eMMC
controller (`mmc0`), and MT6375 TCPM (`tcpm-source-psy-mt6375-tcpc` — the
only one with accumulated events, matching `/sys/power/wakeup_count`).
There is no touch-controller (`5-0034`) wakeup entry; an earlier list here
included one in error. `suspend_stats` still reads success=0/fail=0 on
this boot. Those counters describe this boot: success=0 means no successful
cycle here, not that the pre-pin cycle never happened. The sleep targets stay
masked until a full cycle and wake path are observed on the current build.

The device package now stages a 60-second screen-off suspend helper behind
`/var/lib/dc1/enable-auto-suspend`. Its service is enabled but skipped
without that marker. It checks DRM DPMS, both frontlights and unplugged
charger state before requesting sleep, and waits for a screen-on observation
before it can try again. The opt-in helper unmasks the former package-owned
`sleep.target` and `suspend.target` masks immediately before its first
request. Do not create the marker from a remote-only session: the packaged
kernel has no RTC `wakealarm`, and the listed hall, USB and SDIO wakeup
sources are not yet a proven recovery path. The power key is configured
separately by `mtk-pmic-keys` and does not get its own `/sys/class/wakeup`
entry; it still needs a full-cycle wake measurement on this build.

## Remote test on 2026-09-25 (kernel r60)

The installed kernel has `CONFIG_RTC_DRV_MT6397` unset. A temporary
`rtc-mt6397` module built against its pinned source and exact kernel
release bound the MT6358 RTC as `rtc1`. Its clock initially read 2083;
after setting it from trusted system UTC, a 20-second alarm fired while
Linux was awake: the PMIC RTC IRQ count increased by one and `wakealarm`
cleared. This proves the awake alarm path, **not** wake from s2idle. The
module is not packaged and is lost at reboot; this kernel also has module
unloading disabled. The driver maps its raw RTC range through a core
offset, but rollover still needs validation.

`pm_test=freezer` returned after 5.24 seconds. `devices` and `platform`
each returned after about 9.6 seconds. Both device-resume passes logged
the known mt7921s `-EIO`, and Wi-Fi recovered. Just after the `platform`
pass, however, OVL reported a layer-0 SMI underflow (`status=0x4203`,
underflow bit `0x200`) on its first frame. The frame-done and operational
flow bits were present, and RDMA did not report FIFO underflow. The
driver returned `-EIO` and permanently quarantined the CRTC; a later
panel display-off/sleep command also failed. The cause of the transient
OVL starvation is unproven. The screen was already off, so a visual
relight check was unavailable. A subsequent `processors` request returned
`-EAGAIN` without completing its test stage; no `core` or full s2idle
test was attempted. The test selector was restored to `none`, the RTC
alarm was disarmed, and the auto-suspend marker remains absent.

The running system's 30-second hardware watchdog is not a timed sleep
recovery path: `mtk_wdt_suspend()` stops an active watchdog and restarts
it only on resume. Fix and verify display resume, then package and prove
a timed wake path before remotely enabling automatic suspend.

## Current-build stage tests on 2026-09-30

The running kernel and `/boot/vmlinuz` identify as
`#61-postmarketos-mediatek-mt6789`; installed APK metadata says r60, and the
saved r60 APK contains that same #61 banner. The panel was on at 60 Hz,
USB power was connected, and local physical recovery access was confirmed.
Only automatic-return test stages were exercised:

| Stage | Return time | Display result |
| --- | --- | --- |
| `freezer` | 5.19 s | GPIO83 TE remained 59.18 Hz |
| `devices` | 11.12 s | First frame completed with OVL status `0x4003`; TE returned to 59.18 Hz |
| `platform` | 12.23 s | First frame reported OVL status `0x4203`; CRTC permanently quarantined |

Both device stages logged mt7921s resume `-EIO`; Wi-Fi recovered and
NetworkManager reported connected after each. The platform fault reproduces
the September 25 layer-0 SMI underflow (`0x200`). Its frame-completion bit and
operational flow were present. TE still measured 59.18 Hz after quarantine:
this establishes panel-controller liveness, not successful delivery of new
frames or a visually correct image. DRM DPMS also remained `On`.

The extra late/noirq path in `platform` includes SMI forced runtime suspend
and resume, plus display power-domain callbacks. Compared with the successful
first frame after `devices`, this makes memory-path restoration a candidate
for investigation; it does not identify the cause. The local CRTC teardown
change that skips unobtainable frame-edge waits was active during these tests
and did not prevent the resume fault.

After the three tests, `suspend_stats` reported success=3/fail=0 but
failed_resume=2. These counters include test cycles and do not establish
successful real sleep or display resume. `pm_test` was restored to `none`,
temporary PM diagnostics were restored, and the sleep targets remain masked
with the auto-suspend marker absent. Only the external RTC is registered;
there is still no `wakealarm`. No real s2idle or timed-wake test was attempted.

## Escalation plan (tracked in ../roadmap.md)

1. With local recovery access, exercise the supported s2idle test stages
   (`freezer` → `devices` → `platform`), fixing faults before real `echo mem`.
2. Verify power-key wake, or establish another source (PMIC RTC driver or
   verified gadget/hall wake).
3. Resolve the OVL first-frame underflow and display quarantine seen after
   `pm_test=platform`; verify panel TE or DCS liveness after resume.
4. Absorb or fix the mt7921s resume `-EIO` (upstream mt7921s SDIO resume
   behavior).
5. Only then unmask the sleep targets behind an owner opt-in.
6. With local physical access and an alternate recovery plan, enable the
   marker and observe a full 60-second screen-off cycle. Confirm that the
   power key or another intended input wakes the device, the panel relights,
   Wi-Fi reconnects, and the battery current falls during sleep. Remove the
   marker if any check fails.
