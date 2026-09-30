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
power loss. This does **not** establish a real sleep/wake cycle or visually
correct glass on this build.

Only `[s2idle]` is exposed in `/sys/power/mem_sleep`; hardware `deep` suspend
is unavailable. `sleep.target` and `suspend.target` remain masked, and
`/var/lib/dc1/enable-auto-suspend` remains absent. Wi-Fi still reports resume
`-EIO`, then recovers. There is no packaged RTC alarm backstop.

An earlier full s2idle cycle returned to Linux on 2026-08-19, before the
current kernel pin. Its wake cause and panel image were not independently
verified; it is not acceptance of the current build.

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
test service/timer was removed. No real `mem` or timed-wake test was attempted.

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

The PMIC power key is configured as a wake source but has no current-build
full-cycle wake result. Other candidates include the PMIC RTC, USB gadget and
hall switch. The hardware watchdog is **not** a timed recovery path:
`mtk_wdt_suspend()` stops it and restarts it only after resume.

## Automatic sleep and remaining acceptance

The enabled `dc1-sleep-on-blank` service stays inactive without the opt-in
marker. It requests sleep once per screen-off cycle after DRM and both
frontlights have been off for 60 seconds on battery. It unmasks the package's
sleep targets immediately before its first request. Keep the marker absent
until the installed build has a verified full cycle and physical wake path.

Next establish a wake source with local recovery, test a real s2idle cycle,
verify screen redraw/relight and Wi-Fi recovery, and measure battery current
while asleep. Only then test the owner opt-in screen-off cycle. Fix or
explicitly scope the remaining mt7921s resume failure; stage tests alone do
not justify enabling automatic sleep.
