# Battery, charging, and charging mode — measurement record

Deep-dive for the status-table rows *Battery* and *Charging mode* in
[docs/status.md](../status.md). User-facing behavior is summarized in
[../power.md](../power.md); this page is the measurement record. Newest
facts last.

## Fuel gauge (mt6358-fg)

Real current, charge and state of charge, from the MT6366 PMIC's FGADC
coulomb counter (`mt6358-fg`) — it measures pack current through the
sense element and integrates it in hardware. Verified on device
2026-08-16: capacity held at 32% across idle → 8 cores busy → idle while
`current_now` tracked -126 → -245 → -128 mA, and charge integration came
within 1% of the measured current over 60 s (later found circular — see
the 2× correction below — both sides shared the missing factor).
Caveats: the state of charge is seeded from open-circuit voltage at boot
(so it is re-seeded on every reboot) and measured against *design*
capacity, since nothing here learns a real full-charge capacity.

**The fuel gauge was found to under-report by almost exactly 2×
(2026-08-21, ten-agent investigation + differential referee test):** the
homegrown `mt6358_fg` transcribed MediaTek's FGADC LSBs (381.47
µA/current count, 190.735 µAs/charge count) without the vendor's
per-board correction ×`DEFAULT_R_FG/r_fg_value` — and this board's
factory configuration is a **5 mΩ shunt with a 1.01 charge trim**, proven
from two artifacts on the unit itself: the factory gauge node in
`vendor_boot_a` (`R_FG_VALUE=<5>`, `CAR_TUNE_VALUE=<101>`) and the stock
kernel's own boot log preserved in `expdb` (`r_fg=50 car_tune=1010
DEFAULT_RFG=100`). Stepping the charger's ICHG target 500→900→500 mA gave
dI(chip IBAT)/dI(FG) = **2.02**, and doubling reconciles every earlier
anomaly — idle is really ~267 mA, eight spinning cores ~534 mA, and the
discharge/charge numbers quoted above were all half-truths (the −250 mA
discharge was ~−500 mA; the +233 mA plateau ~+466 mA). Kernel
`d8ed2cdfd537` (pkgrel=22) applies the vendor correction as module
parameters (`mt6358_fg.r_fg_milliohms=5`, `car_tune_permille=1010` —
module params because the signed `lk`/`dtbo` cannot carry DT tuning),
halves the pack-resistance estimate that had absorbed the same factor,
and exposes raw latch counts at `.../power_supply/mt6358-fg/fgc_raw`.
Residuals kept honest: the shunt was never ohmmetered (a constant-ratio
board bypass would look identical remotely; read the marking at next
power-off), and the ~13% gap between chip IBAT and the nominal ICHG
target is unexplained.

## Pack gauge (BQ78Z100) — not answering (P7.1)

The pack's BQ78Z100 — which does learned capacity, persistent SoC and
proper protection — still does not answer: every `bq27xxx-battery` read
of `7-0055` returns `-ENXIO`. The bus is not the problem: the RT9471 at
`0x53` on the same i2c-7 replies, a full scan finds only `0x53`, `0x55`
NAKs both read and write addressing across 60 retries, and the bus
measures 49.2 kHz against the 50 kHz the DT asks for. The vendor 5.10
tree was compared line by line — same bq27xxx glue, same pad tuning
(RSEL_111 1k pull-up, applied and read back in hardware), byte-identical
pinctrl rsel tables, equivalent controller quirks and AC timing — so
nothing in software distinguishes us from the kernel that read `capacity
100` from that address. `mt6358-fg` stands aside automatically if the
pack gauge ever reports `present=1`. Now a hardware item: the pack
connector's SMBus pair, or the gauge's own I²C block. Consequences while
it stays dead: SoC re-seeds from voltage on every boot, no learned
full-charge capacity, no battery-temperature-informed charge current
(only chip-side JEITA-ish behavior plus the 110/113.5 °C critical
shutdowns — see [thermal.md](thermal.md)), and the deliberately
conservative 2 A charge default.

Cosmetic but real: `bq78z100-0` registers a phantom empty power_supply
that spams `-ENXIO` property warnings and pollutes PSU enumeration — any
UI listing batteries sees a dead entry (still present on the 2026-08-26
audit boot). Suppression is a tracked nice-to-have in
[../roadmap.md](../roadmap.md).

## Charger and USB-PD (MT6375)

**Charging was found not to work on 2026-08-21** — plugged in at 11%, the
coulomb counter lost ~10.3 mAh over 150 s (−248 mA net) because the
MT6375's input-current limit sat at the bootloader's static 500 mA and
nothing negotiates a higher one: there is no Type-C/PD or BC1.2 driver on
this platform (no `typec`, no extcon), so the charger never learns what
the source can do, the whole input budget feeds VSYS under desktop load,
and the pack subsidises the rest. The driver's `status="Charging"` only
ever meant *charge-enable bit set + VBUS good*, which is why this hid
behind a green-looking sysfs. Verified live over `/dev/i2c-5`: raising
CHG_AICR 500 → 2000 mA flipped the pack from −250 mA to +233 mA
immediately, reproduced across an A/B cycle of the same register, and
pushing to 3000/3175 mA gained nothing more — the ~600 mA input ceiling
observed is the adapter, not the limit. Kernel `4fde6edeac00`
(pkgrel=21) renames the read-only telemetry driver to `mt6375-charger`
and gives it one job beyond telemetry: raise CHG_AICR from the
bootloader's 500 mA to 1.5 A once VBUS appears (one-shot poll; the 4.5 V
MIVR regulation folds back if a weak source sags), plus a writable
`input_current_limit` property for userspace override. Charge enable,
watchdog, interrupts, and constant-charge current/voltage stay untouched
— those are cell-level settings whose normal enforcer (the BQ78Z100)
does not answer here.

**Fast charge then became the default (kernel `6a12a0831485`,
pkgrel=23):** stepping the ICHG target 500→1500→2000→2500 mA on hardware
measured the pack taking 1.46 → 1.8 A while the input pinned at ~1.85 A
with VIN sagging 5.0→4.78 V and the junction at only 34 °C — the wall
adapter, not the device, is the ceiling. The VBUS one-shot policy now
raises the fast-charge target to 2 A alongside the 1.5 A input limit, and
`constant_charge_current` joined `input_current_limit` as writable sysfs,
so the observed ~1.8 A (~22%/h, 0→80% in under 4 h) needs no manual
register writes; a weaker source simply yields less through the MIVR
foldback.

**USB-C PD then came up (kernel `5e36dfcd3193`, pkgrel=24):** the
MT6375's TCPCI bank at i2c-5 `0x4e` (Richtek VID `0x29cf`, PID `0x6375`)
turns out to be a plain TCPCI controller that the bootloader had already
left presenting Rd — which is why PD adapters were applying vSafe5V all
along with nobody home to talk PD to. A new `tcpci_mt6375` driver runs
the generic TCPCI/TCPM stack over it: vendor PHY/timing patch from the
BSP driver, a software-node connector (the signed bootloader DT describes
neither the bank nor an interrupt line) declaring sink-only fixed PDOs of
5 V/3A, 9 V/3A and 12 V/3A — everything above stays out because the
charger's OVP buckets top out at 14.5 V — and alert polling at 15 ms
instead of an IRQ. Settled contracts flow through TCPM's per-port power
supply into the charger: OVP bucket above the contract voltage, MIVR
800 mV under it, AICR at the contracted current. First boot of pkgrel=24
verified everything *except* PD: boot chain + slot fallback machinery
clean, charge policy auto-applied at probe, calibrated gauge took the
pack from ~15% to 99% overnight — but `/sys/class/typec` never appeared,
because `CONFIG_USB` had never been set (only `USB_GADGET`), and
`TYPEC_TCPM depends on USB`, so syncconfig silently dropped TCPM, TCPCI,
and the MT6375 driver down the dependency chain. pkgrel=25 sets
`CONFIG_USB=y` (kernel `55509d09d028`; musb becomes dual-role as a side
effect) and is the first build where the Type-C stack actually ships.

**2026-08-22 evening audit (nothing attached):** the stack is alive
end-to-end on the running build — `/sys/class/typec/port0` exists beneath
the bound `mt6375-tcpc` device with `power_role=sink`, `port_type=sink`,
`select_usb_power_delivery=pd0` (PD 3.0), and our declared sink caps read
back as fixed PDOs 5 V/3 A, 9 V/3 A, 12 V/3 A; the charger sits at its
idle policy values (AICR 500 mA) awaiting the VBUS one-shot. Re-measured
idle 2026-08-26: `port0` present, `mt6375-charger` online=0 (on battery),
`mt6358-fg` Discharging, `tcpm-source-psy-mt6375-tcpc` registered.

**Contract formation verified live (2026-08-22/23 night):** with a PD
adapter attached the TCPM settled a contract — pack branch measured
+1.798 A @ 3.998 V with the policy applied (AICR 1500 mA, CCC target
2000 mA) — and the adapter's own display read **11.8 V / 0.82 A**, which
matches the negotiated **12 V PDO** confirmed from the source side
(`tcpm-source-psy-mt6375-tcpc` reports `voltage_max=12000000`,
`current_max=3000000`, active usb_type `C PD`; 11.8 V is ordinary
droop). The ~9.7 W observed input is not a fault — at this contract the
charge rate is capped by the 2 A `constant_charge_current` target
(~22%/h on the 8 Ah pack), not by the adapter or the contract.

**Measured 2026-08-23:** `constant_charge_current` 2000000→3150000 took
the pack branch from ~1.82 A @ 4.06 V to a stable **2.93–2.95 A @ 4.18 V**
within one sample interval (~12.3 W into the pack; capacity ticked 39→41%
in about three minutes ≈ 40%/h), input staying inside the 1.5 A AICR at
11.8 V and the hottest thermal zone at 46 °C under audit load. The
default remained at 2 A pending broader validation at that time; this
writable sysfs is the owner lever.

**Default policy updated after that hardware session:** since 2026-08-26,
the VBUS one-shot uses the measured **3150000 µA** target (~0.4C). The
2 A value remains available as the conservative owner choice, while users
can also write lower values for weaker packs or warmer conditions.

Writable owner levers (confirmed present 2026-08-26):
`/sys/class/power_supply/mt6375-charger/{constant_charge_current,
constant_charge_voltage, input_current_limit, input_voltage_limit}`.

## Charging mode (packaged 2026-08-25, device pkgrel>=79 — not yet
hardware-verified)

Plugging USB power into a cleanly-powered-off device boots a minimal
headless `dc1-charging.target` instead of the full desktop: panel,
network and desktop stay off while the battery charges autonomously —
the MT6375 runs CC/CV to the pack's 4350 mV CV point in hardware, the
kernel's VBUS one-shot raises AICR to 1.5 A and the fast-charge target
to 3.15 A once VBUS appears, and PD contracts are negotiated in-kernel — so
zero userspace is required for safe charging. Exit paths: unplug
(`dc1-charging-monitor.service` runs `/usr/libexec/dc1-charging-monitor`,
which polls VBUS with ~6 s debounce and then powers off cleanly), a brief
power-key press (warm reboot into the normal desktop), or a PMIC
long-press hard reset (which also lands in the normal desktop). Opt out
with `touch /var/lib/dc1/no-charging-mode`; journal tag `dc1-charging`.

**Primary signal — the firmware boot cause.** MediaTek's preloader/LK
writes a fresh console log every boot into reserved DRAM at physical
`0x7ffbf000` (256 KiB, kept mapped by our DT as `log-store@7ffbf000`,
root-readable via `/dev/mem` because `CONFIG_STRICT_DEVMEM` is off),
carrying a line `BOOT_REASON: <n>` with the MTK enum 0 = power key,
1 = USB charger insert, 2 = RTC alarm, 3 = watchdog, 4/5 = warm-reboot
bypass, 8 = kpanic. `dc1-charging-generator` parses the LAST such line,
voting only when the ring-tail sanity marker `jump to linux kernel
64Bit` shows this ring actually reached the kernel handoff — stale or
partial rings don't vote. Reason 1 plus VBUS enters charging mode
authoritatively (no flag required); reasons 3/4/5 NEVER enter it even
with a fresh flag — watchdog/warm-reboot bypasses must land in the normal
desktop even when docked, and that asymmetry is exactly what makes the
power-key exit work. Reasons 0/2/8, unknown codes, or an unreadable ring
fall through to the deliberate fallback: the clean-poweroff heuristic —
`dc1-poweroff-flag.service` runs `/usr/libexec/dc1-poweroff-flag` via
ExecStop to record `/var/lib/dc1/poweroff-clean` (an epoch timestamp)
whenever the system shuts down without reboot markers
(`/run/systemd/reboot`/`kexec` absent; reboots never leave the flag) —
fresh for up to DC1_MAX_AGE, default 7 days (stale beyond that means
"parked", not "docked"), which also degrades gracefully if a charger's
ring value ever differs from enum expectations. The flag is consumed on
every boot and generators never mutate this state (they re-run on
daemon-reload).

Two gates apply regardless of tier: `/var/lib/dc1/no-charging-mode`
absent, `/var/lib/dc1/first-boot-apps-done` present — a system that has
never finished provisioning always boots to the desktop, protecting the
fresh-install-with-flash-cable-still-attached case that would otherwise
present reason 1 and wake as silent dark glass — plus VBUS present
(`/sys/class/power_supply/mt6375-charger/online` = 1; every charger
driver is built-in, so sysfs exists before generators run).

Inside the target the monitor stands down `dc1-boot-watchdog` by touching
`/run/dc1-boot-watchdog.pat` (an existence-based pat — without it, 600 s
of unreachability would reboot-loop a dumb charger into fastboot
escalation), holds `bl_power=4` on all frontlight channels as insurance,
and runs `/usr/sbin/dc1-pwrkey`, which reads KEY_POWER evdev events
directly because logind ignores the power key globally on this device
(`HandlePowerKey=ignore` via
`/etc/systemd/logind.conf.d/10-dc1-power.conf`) and `/etc` drop-ins
outrank `/run`, so no volatile logind override could take. Kept units:
PID 1 with its `RuntimeWatchdogSec=30s` feed (mandatory — LK arms a ~31 s
SoC watchdog), journald, udevd, logind, `dc1-usb-gadget` +
`dc1-debug-shell` + `unudhcpd@usb0` (the USB recovery channel at
172.16.42.x stays reachable), `dc1-link-apk-keys`, and
`dc1-rtcsync.timer`; excluded are gdm/GNOME, NetworkManager,
wpa_supplicant, sshd, Bluetooth, ModemManager, and the audio/display/
frontlight/backlight/GPU/first-boot/boot-sync/update services.

Electrical facts worth keeping: there is **no in-kernel
battery-temperature throttling of charge current** (see
[thermal.md](thermal.md)); the device has **no charging LED**; and the
panel is physically dark without `dc1-display-gate`, so charging mode
adds nothing to make the screen dark. A port that suspends its VBUS for
longer than the ~6 s unplug debounce reads as unplugged; the resulting
slow off/on cycle is harmless and by design.

Verification state: the ring mechanism itself is verified live on-device
— one boot printed `BOOT_REASON: 4` with the warm-reboot-bypass marker,
and five historical cold power-key boots recovered from `expdb` logs all
show `BOOT_REASON: 0`. Still owed is one hardware calibration session:
power off, plug USB, confirm the ring really shows the charger code
(optionally pinning the MT6358 CHRIN bit via the `000c:` line of the
PMIC regmap under debugfs); until then the feature stays
`hardware_verified=false`. Remaining candidates beyond that are
second-opinion boot-cause sources (MT6358 PONSTS/CHRIN power-on-status
registers) or plumbing the reason through the dtbswap stub's trace-word
channel (`TRACE_PA 0xff0c1000`) — the latter explicitly discouraged,
because stub changes are the highest-risk class in this repository (the
fail-safe returns stock DT behavior, and three past bugs in that class
surfaced only on hardware). The calibration runbook is in
[../roadmap.md](../roadmap.md).

## RTC

The `rtc-s35390a` at i2c-8 registers as `rtc1` with **no `wakealarm`
attribute** (the driver implements no alarm), and the MT6358 PMIC RTC
never registered — there is no `rtc0` at all, so a timed wake cannot be
armed (matters for suspend — see [suspend.md](suspend.md)).

**New observation 2026-08-26 (r37 boot, ~15 h uptime):** the kernel ring
carries ~24,000 repetitions of `rtc-s35390a 8-0030: alarm IRQ with INT2
flag clear; disarmed INT2` (~0.6 lines/s sustained). Cause unknown;
functionally it looks benign, but it rotates the dmesg ring fast enough
that early-boot signatures (wacom probe, Bluetooth firmware race) are
gone by the next morning — when a fresh-boot signature check matters,
run it early or raise the ring size. Worth root-causing at the next
kernel touch (candidate: the driver's INT2 alarm polarity handling
against this board's wiring).
