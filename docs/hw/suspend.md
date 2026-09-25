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

## The freezer saga (root-caused and fixed)

s2idle used to abort with `Freezing user space processes failed after
20.001 seconds (2 tasks refusing to freeze)`, twice per attempt,
returning with the panel dark. Root-caused on 2026-08-16: the
unfreezable tasks are not a suspend bug at all but `usb-signaller` stuck
in `unlinkat(…, AT_REMOVEDIR)` on configfs (see
[usb.md](usb.md)), plus whatever later touched configfs and inherited its
D state — an uninterruptible task can never be frozen. Masking
`usb-signaller` removes that particular offender, but the 2026-08-17
teardown measurement shows the wedge is not specific to it: **any**
`rmdir` of a gadget function object goes to D state, so the freezer would
have kept failing for whoever ran one. Removing teardown entirely takes
the blocker out for good.

**The freezer is now fixed and measured.** `CONFIG_PM_DEBUG=y` (kernel
pkgrel=22) brings `/sys/power/pm_test`, which stops the suspend sequence
after freezing without touching devices — so the freezer can be exercised
with the panel lit and no dark-screen recovery risk. Run on hardware
2026-08-17 at kernel pkgrel=24 (`echo freezer > /sys/power/pm_test; echo
freeze > /sys/power/state`): `Freezing user space processes completed
(elapsed 0.003 seconds)`, `Freezing remaining freezable tasks completed
(elapsed 0.002 seconds)`, held 5 s, `Restarting tasks: Done`,
`PM: suspend exit`, return code 0. Against the previous failure — 20.001
s timeout, twice per attempt — that is the configfs teardown removal
doing exactly what it was predicted to do.

## What remains

The rest of the sequence: `pm_test` escalates through `devices`,
`platform`, `processors`, `core`, and only `core` is close to a real
`mem`. Those levels do suspend devices, so the panel goes dark. Every
`pm_test` level stops the sequence at its test point and resumes
automatically, so no wakeup source is needed until a real `echo mem` is
attempted.

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

## Escalation plan (tracked in ../roadmap.md)

1. Escalate `pm_test` level by level (`devices` → `platform` →
   `processors` → `core`) on hardware, fixing whatever each level
   surfaces, before any real `echo mem`.
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
