# Hardware support status — Daylight DC-1 (`jagar`)

Status of the mainline-based kernel port this repository packages. "Works"
means it has functioned on real hardware in earlier bring-up; it does **not**
mean the artifacts built by any given CI run were booted — releases carry
`hardware_verified=false`, and CI only proves the build compiles.

| Component | Status | Notes |
| --- | --- | --- |
| Display | Works | DSI panel; Wayland sessions (Sway, GNOME) run. |
| GPU | Works | Mali-G57 MC2 via Panfrost. |
| Touchscreen | Works | ILI2910, 10-point multitouch. |
| On-device UI | Works | Installer: touch UI (`dc1-ask`) drawn by PID 1, hardware-verified to boot and serve its menu. Desktop: GNOME Mobile on the panel, hardware-accelerated via Panfrost — no Flutter shell, no first-boot onboarding. |
| Frontlight | Works | Dual RT4539 backlight drivers. |
| Wi-Fi | Works | MT7902 via mainline mt7921s. Confirmed on device 2026-08-15: firmware loads, `wlan0` appears, and a scan returns a dozen networks. Needs `CONFIG_FW_LOADER_COMPRESS_ZSTD` — linux-firmware ships the three MT7902 blobs `.zst`-compressed, and without it the loader reports `-2` for a file that is present, `hardware init failed`, and no `wlan0`. Carried by the pinned kernel since `ea54394`. |
| Bluetooth | Works | MT7902, same upstream firmware. |
| USB gadget | Works | Serial console, USB ethernet, SSH over USB. |
| Internal storage | Works | UFS. |
| Battery | Partial | Charger state only — there is no state of charge. `mt6375-charger` (read-only) reports input presence and LK's configured limits, and the MT6366 `bat_adc` AUXADC channel gives pack voltage (3814 mV measured 2026-08-16). The BQ78Z100 fuel gauge does **not** answer: every `bq27xxx-battery` read of `7-0055` returns `-ENXIO` and `present=0`. The bus is not the problem — the RT9471 at `0x53` on the same i2c-7 replies, a full scan finds only `0x53`, `0x55` NAKs both read and write addressing across 60 retries, and the bus was measured at 49.2 kHz (the DT asks for 50 kHz). Stock Android read `capacity 100` from the same address, so this is state or supply on the gauge side, not transfer shape. Tracked as P7.1. |
| Suspend/resume | Not yet | |
| Audio | Not yet | |
| Sensors | Not yet | Accelerometer (mCube MC3416) and ambient-light/proximity (Memsic MN29xxx) are wired to the **SCP** (sensor co-processor), not an AP I²C bus, and are driven by the closed `scp_a.img` firmware. No gyro or magnetometer. A DT node + defconfig entry cannot expose them — this needs a mainline mt6789 SCP/sensorhub bring-up. The hall switch (magnetic lid) is the only directly-AP-wired sensor and is not in the DTS yet. |
| Cameras | Not yet | It is not yet confirmed the hardware has populated camera modules. |

Not listed means untested or unknown. Status updates land here as the port
progresses; upstreaming to postmarketOS is the goal, so this table also
tracks what is left before the device can move out of
`device/testing`.
