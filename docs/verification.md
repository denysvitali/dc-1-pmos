# Verification ledger

Fine print behind `hardware_verified`: which subsystem claim was verified
on hardware, at which package version, on which date. The linked record
page is authoritative; this ledger summarizes. Versions are the
linux-postmarketos-mediatek-mt6789 (kernel) / device-daylight-jagar
(device) pkgrels of the build that was actually running when the
measurement was made. "Pending" items live in
[roadmap.md](roadmap.md).

| Claim | Verified at | Date | Record |
| --- | --- | --- | --- |
| dtbswap boots the mainline DT (model string, DRM, GNOME atomic) | pre-pin bring-up | 2026-08-19 | [status.md](status.md) |
| Reachability watchdog incl. fastboot escalation | boot-image deploy | 2026-08-19 | [status.md](status.md) |
| Autonomous OTA cycle (apk → slot write → first-try boot) | linux r31 era | 2026-08-23 | [status.md](status.md) |
| Display: DPMS off/on relight (`DSI_SW_CTL_EN` fix, TE + DCS ground truth) | linux r37 (`2466a7f6`) | 2026-08-24 | [hw/display.md](hw/display.md) |
| GPU: Panfrost native on mainline DT, devfreq cooling | kernel `981870b`/`0f6e730c92d6` builds | 2026-08-19 / 08-22 | [hw/display.md](hw/display.md) |
| Frontlight warmth crossfade slider | device r66 | 2026-08-24 | [hw/display.md](hw/display.md) |
| Touchscreen multitouch | earlier bring-up | pre-2026-08-17 | [hw/input.md](hw/input.md) |
| Pen: kernel events (proximity/touch/barrel/eraser/pressure) | linux r31 | 2026-08-23 | [hw/input.md](hw/input.md) |
| Pen: axis resolution, orientation, pressure scale, visible-area map | linux r32–r35 | 2026-08-23 | [hw/input.md](hw/input.md) |
| Pen: edge alignment after `prop.max_*` refit | linux r38 | **pending r38 boot** | [hw/input.md](hw/input.md) |
| Power key: blank/wake/menu event path | device r64-era gschema | 2026-08-23 | [hw/input.md](hw/input.md) |
| Wi-Fi: cold-boot associate on mainline DT | kernel `231fa88`+`0c26bee` build | 2026-08-19 | [hw/wireless.md](hw/wireless.md) |
| Bluetooth: controller up via repair path | kernel r24 / device r38 | 2026-08-17, re-measured 08-26 | [hw/wireless.md](hw/wireless.md) |
| Bluetooth: race won outright by initramfs staging (no repair) | device r65 boot image | **pending fresh boot** | [hw/wireless.md](hw/wireless.md) |
| Bluetooth: pairing + A2DP streaming | — | **pending session** | [hw/wireless.md](hw/wireless.md) |
| USB gadget: ECM completion + clean bind on real boot | device r34 | 2026-08-22 | [hw/usb.md](hw/usb.md) |
| USB gadget: SSH over ECM from a host | — | **pending host** | [hw/usb.md](hw/usb.md) |
| USB host: charging hub DR_SWAP, enumeration, charging | live UTMI session override equivalent to kernel `a1a5a465fb61` | 2026-08-28 | [hw/usb.md](hw/usb.md) |
| USB host: packaged-kernel hub enumeration in sink-host mode | linux r50 / device r85 | 2026-08-28 | [hw/usb.md](hw/usb.md) |
| USB host: downstream keyboard/mouse enumeration | — | **pending ordinary USB 2.0 charging hub; Lenovo 40B0 withholds port connect** | [hw/usb.md](hw/usb.md) |
| USB role: gadget return after host mode | linux r50 / device r85 | **pending PC session** | [hw/usb.md](hw/usb.md) |
| configfs: D-state wedge measurement, teardown removed | device r34 | 2026-08-17 | [hw/usb.md](hw/usb.md) |
| Internal storage: UFS | earlier bring-up | pre-2026-08-17 | [hw/storage.md](hw/storage.md) |
| microSD: SDXC enumeration (`CONFIG_REGULATOR_GPIO`) | linux r31 (`27918e9d5c92`) | 2026-08-23 | [hw/storage.md](hw/storage.md) |
| Fuel gauge: 2× r_fg correction, referee test | kernel r22 (`d8ed2cdfd537`) | 2026-08-21 | [hw/power.md](hw/power.md) |
| Pack gauge: suppress non-answering BQ power supply + thermal zone | linux r50 (`15fd2e78b746`) | 2026-08-28 | [hw/power.md](hw/power.md) |
| Charger: AICR policy flips pack to charging (live i2c A/B) | kernel r21 (`4fde6edeac00`) | 2026-08-21 | [hw/power.md](hw/power.md) |
| Charger: fast-charge default ~1.8 A | kernel r23 (`6a12a0831485`) | 2026-08-21 | [hw/power.md](hw/power.md) |
| USB-PD: 12 V PDO contract end-to-end | kernel r25 (`5e36dfcd3193`+`55509d09d028`) | 2026-08-22/23 | [hw/power.md](hw/power.md) |
| Charge rate at the 3.15 A ceiling (~40 %/h) | running r2x build | 2026-08-23 | [hw/power.md](hw/power.md) |
| Charging mode: ring mechanism (BOOT_REASON readout) | device r79 | 2026-08-25 | [hw/power.md](hw/power.md) |
| Charging mode: reason 1 on real charger insert | — | **pending calibration** | [hw/power.md](hw/power.md) |
| Suspend: one clean s2idle cycle | pre-pin build | 2026-08-19 | [hw/suspend.md](hw/suspend.md) |
| Suspend: freezer clean under `pm_test freezer` | kernel r24 (`CONFIG_PM_DEBUG`) | 2026-08-17 | [hw/suspend.md](hw/suspend.md) |
| Audio: speakers, L/R, balance | kernel ≤r20 fixes, device r48 | 2026-08-20 | [hw/audio.md](hw/audio.md) |
| Audio: DMIC capture | running r27 | 2026-08-22 | [hw/audio.md](hw/audio.md) |
| Audio: gain-race transaction fix held | device r60 | 2026-08-23 | [hw/audio.md](hw/audio.md) |
| Audio: UCM2 profile adopted ("Internal Speakers") | device r57, verified r76 | 2026-08-25 | [hw/audio.md](hw/audio.md) |
| Audio: idle-gain shadow fix (live = persisted 18,18/12,12) | linux r36 fix, verified on r37 boot | 2026-08-26 | [hw/audio.md](hw/audio.md) |
| Audio: physical `speaker-test` PCM0=DL1 probe | — | **pending permission** | [hw/audio.md](hw/audio.md) |
| Sensors: accelerometer + SensorProxy orientation | kernel r22 nodes | 2026-08-19, re-measured 08-22 | [hw/sensors.md](hw/sensors.md) |
| Sensors: AP i2c1/GPIO132–133 staging and write-free MN29 ACK probe | linux r42 (`a4b10323d042`) + device r81 tool | **pending hardware boot** | [hw/sensors.md](hw/sensors.md) |
| Sensors: physical tilt test (all four poses) | — | **never performed** | [hw/sensors.md](hw/sensors.md) |
| Thermal: 13 LVTS hot trips + NTC trips present on hardware | linux r28 (`a2c27ab3bff1`) | 2026-08-23 | [hw/thermal.md](hw/thermal.md) |
| Thermal: DVFS + cooling devices under load | running r27 | 2026-08-22 | [hw/thermal.md](hw/thermal.md) |
| Type-C/PD stack idle enumeration (`port0`, sink caps) | running r37 | 2026-08-26 | [hw/power.md](hw/power.md) |
| Charger sysfs owner levers present | running r37 | 2026-08-26 | [hw/power.md](hw/power.md) |
| usb0 gadget interface set survives boot (no host attached) | running r37/r76 | 2026-08-26 | [hw/usb.md](hw/usb.md) |
| `rtc-s35390a` log storm observed (~24 k lines/boot) | running r37 | 2026-08-26 | [hw/power.md](hw/power.md) |
| `rtc-s35390a` IRQ storm removed; timekeeping retained | linux r48 (`8f0bfe8f8a4c`) | 2026-08-28 | [hw/power.md](hw/power.md) |

**How to record a new result:** update the subsystem record under
`docs/hw/` with the measurement and its date, then add or update the row
here with the exact package versions of the running build (`apk list
--installed | grep -E 'linux-postmarketos|device-daylight'` — note
`uname`'s `#N` build counter does not track pkgrel). If the result
closes a roadmap item, tick it there too.
