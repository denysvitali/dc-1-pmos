# Thermal and cooling

The mainline tree exposes 13 LVTS zones and two board NTC zones, with CPU and
GPU cooling. Battery-temperature charge-current control remains unavailable;
see [power](power.md).

## Policy

| Zone | Trips / behavior |
| --- | --- |
| Nine LVTS zones with passive cooling | Passive 85 °C / 2 °C hysteresis; hot 105 °C / 8 °C hysteresis; critical 113.5 °C |
| Other four LVTS zones | Hot 105 °C / 8 °C hysteresis; critical 113.5 °C; hardware threshold IRQ supplies evaluation where polling is disabled |
| `ap_ntc`, `ltepa_ntc` | Two-second polling; hot 85 °C / 5 °C hysteresis; critical 110 °C / 2 °C hysteresis |

Hot trips notify; they do not themselves throttle. Zones use `step_wise`.
Critical NTC readings have no debounce and can initiate immediate ordered
poweroff. All LVTS hot trips and NTC pairs were checked on hardware at kernel
r28 (2026-08-23); r50 (2026-08-28) confirmed 15 real zones after disabling
the non-answering BQ78Z100.

LVTS calibration uses fuse base `0x1a4`. Manual RCK takeover is unsupported
until separately validated. Occasional empty LVTS reads have recovered on the
next read; investigate persistent failures or missing zones/trips/cooling
rather than treating one empty sample as proof of failed thermal control.

## CPU and GPU scaling

CPU DVFS uses `mtk-cpufreq-hw`: MCUPM owns the voltage rails and supplies the
LUT/energy model; Linux writes performance-state indexes. Do not substitute
the classic mediatek-cpufreq voltage/OPP path. CPU0–5 span 500–2000 MHz;
CPU6–7 span 725–2200 MHz. CPU and GPU cooling remain authoritative.

A kernel `7cc767cd0cff` check (2026-09-12) found schedutil with a 1 µs rate
limit; separate two-second CPU0/CPU6 loads reached 2000/2200 MHz throughout
the samples. This proves clock ramping, not sustained thermal performance or
optimal compositor scheduling. Power Profiles used a placeholder driver;
no performance profile was exposed.

Panfrost uses `simple_ondemand`, with thermal devfreq cooling. The GPU's
36-OPP transition table exceeds PAGE_SIZE, so an unreadable `trans_stat` is
not proof of failed scaling. GPU floor control belongs to `dc1-gpu-freq`;
see [display](display.md) for defaults and latency measurement.

## Charging at the normal target

On 2026-10-20, linux r67 / device r105 with local r116 charging helpers
was measured at the unchanged 3.15 A target and a 12 V/1.5 A PD contract.
The temporary 500 mA test service had been removed. A ten-minute light-activity
run was followed by five minutes of CPU0 load bounded by `CPUQuota=50%`,
`Nice=19`, with 15 seconds of post-load collection. Brief verification
compiles/tests also ran on CPU0; this was not an all-core build.

| Run | Mean / range of calibrated pack current | Maximum board NTC | Maximum charger junction | Maximum LVTS |
| --- | --- | --- | --- | --- |
| Light activity, 600 s / 41 samples | 3.02 A / 2.99–3.04 A | 36.9 °C | 55 °C | 43.8 °C |
| Bounded CPU0 load + recovery, 315 s / 22 samples | 3.02 A / 2.99–3.04 A | 37.5 °C | 56 °C | 45.8 °C |

The main charger's single-shot ADC provided junction temperature and an
independent current measurement; these are chip measurements, not an external
meter. There were no ADC errors; intermittent unreadable LVTS samples were
kept as missing values. The load completed its time bound without reaching
the test's 42 °C board / 70 °C junction stop conditions. The temperature
guard controlled the test load; charging policy remained unchanged.

This establishes ~3 A charging under these bounded conditions. It does not
qualify all-core builds, longer/hotter operation, or pack-cell temperature:
the BQ gauge still does not answer. No thermal trip or secondary-charge
setting was raised. Reproduce collection with
[`tools/power/charge-monitor.py`](../../tools/power/README.md); raw captures
stay outside Git.
