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
