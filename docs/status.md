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
| Battery | Partial | Real current, charge and state of charge, from the MT6366 PMIC's FGADC coulomb counter (`mt6358-fg`) — it measures pack current through the sense element and integrates it in hardware. Verified on device 2026-08-16: capacity held at 32% across idle → 8 cores busy → idle while `current_now` tracked -126 → -245 → -128 mA, and charge integration came within 1% of the measured current over 60 s. Caveats: the state of charge is seeded from open-circuit voltage at boot (so it is re-seeded on every reboot) and measured against *design* capacity, since nothing here learns a real full-charge capacity. The pack's BQ78Z100 — which does all of that properly and persistently — still does not answer: every `bq27xxx-battery` read of `7-0055` returns `-ENXIO`. The bus is not the problem: the RT9471 at `0x53` on the same i2c-7 replies, a full scan finds only `0x53`, `0x55` NAKs both read and write addressing across 60 retries, and the bus measures 49.2 kHz against the 50 kHz the DT asks for. The vendor 5.10 tree was compared line by line — same bq27xxx glue, same pad tuning (RSEL_111 1k pull-up, applied and read back in hardware), byte-identical pinctrl rsel tables, equivalent controller quirks and AC timing — so nothing in software distinguishes us from the kernel that read `capacity 100` from that address. `mt6358-fg` stands aside automatically if the pack gauge ever reports `present=1`. Tracked as P7.1, now a hardware item: the pack connector's SMBus pair, or the gauge's own I²C block. |
| Suspend/resume | Not yet | |
| Audio | Not yet | |
| Sensors | Not yet | Accelerometer (mCube MC3416) and ambient-light/proximity (Memsic MN29xxx) are wired to the **SCP** (sensor co-processor), not an AP I²C bus, and are driven by the closed `scp_a.img` firmware. No gyro or magnetometer. A DT node + defconfig entry cannot expose them — this needs a mainline mt6789 SCP/sensorhub bring-up. The hall switch (magnetic lid) is the only directly-AP-wired sensor and is not in the DTS yet. |
| Cameras | Not yet | It is not yet confirmed the hardware has populated camera modules. |

Not listed means untested or unknown. Status updates land here as the port
progresses; upstreaming to postmarketOS is the goal, so this table also
tracks what is left before the device can move out of
`device/testing`.
