# Thermal — measurement record

Deep-dive for the status-table row *Thermal* in
[docs/status.md](../status.md). Newest facts last.

## Current state

**Trips, cooling maps and CPU DVFS all exist now** — kernel
`0f6e730c92d6` (LVTS trips + cooling maps), `ffc87512c0e2` (cpufreq-hw
MT6789 variant) and defconfig `504c45c64ba0`, all 2026-08-20 and all in
the pinned pkgrel=27 build running on 2026-08-22: live, nine of the
thirteen LVTS zones carry passive 85000/hyst 2000 plus critical 113500
trips (`lvts-ts3-1/-ts3-2/-ts3-3/-ts4-0` critical-only), three cooling
devices are registered (`cpufreq-cpu0`, `cpufreq-cpu6`, and a GPU devfreq
cooler bound through the ts3-0 map), and DVFS is up
(`scaling_driver=mtk-cpufreq-hw`, schedutil; policy0 = cpu0-5 at
500-2000 MHz, policy6 = cpu6-7 at 725-2200 MHz; every zone runs
`step_wise` — `power_allocator` is offered in `available_policies` but
selected nowhere; an earlier revision claimed power-allocator was active,
which re-measurement contradicts). Dynamic re-check on the same pkgrel=27
boot (2026-08-22): eight spinning cores pin both clusters at their
ceilings — 2000/2200 MHz on every core, hottest LVTS zone climbing
41.7→57.5 °C over four seconds, no trip crossed — and releasing load
drops the big cluster to its 725 MHz floor within seconds. The GPU
devfreq sweeps between its 390 MHz floor and 1.1 GHz ceiling under nothing
more than compositor load (`simple_ondemand`; seven distinct OPPs sampled
live). The missing devfreq `trans_stat` is deliberate: with 36 OPPs the
transition table exceeds PAGE_SIZE and the kernel disables it (`devfreq
transition table exceeds PAGE_SIZE. Disabling`, dmesg) — absence of that
file is not a scaling failure.

The DVFS design is deliberately regulator-free: MCUPM firmware owns the
MT6366 vproc/vsram_proc rails and publishes the LUT/energy-model tables,
and the kernel writes perf-state indexes only — the classic
mediatek-cpufreq OPP/voltage route must not be attempted (no upstream
mt6789 entry exists, and the vendor voltage tables live inside MCUPM
firmware).

## Trips landed 2026-08-22 (kernel `a2c27ab3bff1`, linux pkgrel=28)

Every LVTS zone gains a 105000/hyst 8000 `hot` trip inserted before its
existing critical in `mt6789.dtsi` (hot is notification-only —
netlink/uevent; the dtsi change also applies to the emerald board that
shares it), and the two board NTC zones gain their first-ever actuation
capability: polling-delay/-passive raised 0→2000 ms plus `hot`
85000/hyst 5000 and `critical` 110000/hyst 2000 each
(`generic-adc-thermal` has no IRQ path, so at polling 0 they could never
evaluate any trip). Values follow the vendor policy extracted read-only
from this device's authenticated partitions: stock DT carries no CPU
trips at all (stock throttling is userspace-driven), one GPU passive
stage with a devfreq map, and criticals at exactly 113500 everywhere —
all preserved untouched. Validated by preprocessing + compiling the board
DTS (exit 0; five pre-existing warnings, none thermal). Two honest
risks: the NTC critical has no debounce — a single garbage ADC sample
converting to ≥110 °C starts an immediate ordered poweroff
(`CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0`) — and the four
polling-0 LVTS zones rely solely on the LVTS hardware threshold IRQ.

**All 13 LVTS hot trips plus the NTC pairs verified present on hardware
2026-08-23** (the earlier 4/13 reading was checker error, not a kernel
gap), on the same boot that verified the audio race fix and microSD.

## Kept history

- **Pre-r28 baseline recorded 2026-08-22** for side-by-side comparison:
  16 zones (13 LVTS + `ap_ntc`/`ltepa_ntc` + self-disabled `bq78z100-0`,
  which failed reads at boot and was disabled by the core); nine LVTS
  zones passive 85000/h2000 + critical 113500/h2000, four critical-only,
  and **both NTC zones with zero trips — the exact pre-28 signature**,
  confirming the running build predates the trip diff regardless of
  uname's misleading `#28` build counter; all zones `step_wise`; all
  three cooling devices at cur_state 0; hottest idle zone 38.9 °C. NTC
  zones return live values but refresh sparsely at stable ambient
  (`ltepa_ntc` static across 14 s) — post-boot, expect
  occasional-identical consecutive reads even with 2 s polling.
- LVTS reading verified 2026-08-19 (fuse calibration base `0x1a4` versus
  the vendor DT's misaligned `0x1b4`; no manual RCK needed, and the
  driver still refuses manual-RCK paths with `-EOPNOTSUPP` until that
  takeover is separately accepted).
- The NTC zones used to fail registration with `-EODEV` until kernel
  `981870b` moved the shadowing dtsi `thermal-zones` block from `/soc` to
  the root node.
- The board NTC thermal zones and the hall switch were the only two
  bound devices that genuinely disappeared on the switch from stock DT
  to the mainline DT (audited 2026-08-17 against every bound driver);
  both were re-added to the mainline DTS before the switch — NTC zones
  here, hall switch in [sensors.md](sensors.md).
- Occasional empty LVTS reads remain uninvestigated (reproduced
  2026-08-22: one empty poll of lvts-ts2-3 that recovered on the next
  read).
- `bq78z100-0` still disables itself (`Unable to get temperature`) and
  registers a phantom power_supply — see [power.md](power.md).
- There is **no in-kernel battery-temperature throttling of charge
  current** — only the chip-side JEITA-ish behavior plus the 110/113.5 °C
  critical shutdowns (see [power.md](power.md)).
