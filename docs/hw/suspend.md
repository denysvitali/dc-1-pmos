# Suspend/resume — measurement record

Deep-dive for the status-table row *Suspend/resume* in
[docs/status.md](../status.md). User-facing consequences are in
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

**Correction 2026-08-22: the previously claimed RTC wake backstop does
not exist.** The `rtc-s35390a` at i2c-8 registers as `rtc1` with no
`wakealarm` attribute (the driver implements no alarm), and the MT6358
PMIC RTC never registered — there is no `rtc0` at all, so a timed wake
cannot be armed (see [power.md](power.md)). Candidate wake paths to
establish before real-mem testing: the PMIC RTC (`rtc-mt6397` family
support for mt6358), the USB gadget, or the hall switch.

Other enabled wakeup sources today: the hall switch, the touch controller
(`5-0034`), the USB gadget, and the MT7902 SDIO function. The sleep
targets stay masked until a full cycle is observed.

## Escalation plan (tracked in ../roadmap.md)

1. Escalate `pm_test` level by level (`devices` → `platform` →
   `processors` → `core`) on hardware, fixing whatever each level
   surfaces, before any real `echo mem`.
2. Establish a wakeup source (PMIC RTC driver or verified gadget/hall
   wake).
3. Absorb or fix the mt7921s resume `-EIO` (upstream mt7921s SDIO resume
   behavior).
4. Only then unmask the sleep targets behind an owner opt-in.
