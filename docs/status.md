# Hardware support status — Daylight DC-1 (`jagar`)

Status of the mainline-based kernel port this repository packages. "Works"
means it has functioned on real hardware in earlier bring-up; it does **not**
mean the artifacts built by any given CI run were booted — releases carry
`hardware_verified=false`, and CI only proves the build compiles.

| Component | Status | Notes |
| --- | --- | --- |
| Display | Works | DSI panel; Wayland sessions (Sway, GNOME) run. Blank/unblank works: a DPMS off stops the pipeline at the proven boundary and a DPMS on replays the handoff (`production power sequence complete` → `first DSI frame complete`) in ~0.6 s, verified on device 2026-08-16. The frontlight is not the panel's DRM backlight — the device boots LK's stock DT, whose panel node has no backlight phandle — so `dc1-screen-backlight` mirrors the connector's DPMS state onto both RT4539 `bl_power` files; without it a blanked panel stays evenly lit and reads as a wedged display. |
| GPU | Works | Mali-G57 MC2 via Panfrost. |
| Touchscreen | Works | ILI2910, 10-point multitouch. |
| On-device UI | Works | Installer: touch UI (`dc1-ask`) drawn by PID 1, hardware-verified to boot and serve its menu. Desktop: GNOME Mobile on the panel, hardware-accelerated via Panfrost — no Flutter shell, no first-boot onboarding. |
| Frontlight | Works | Dual RT4539 backlight drivers. |
| Power key | Works | Opens GNOME's power menu (restart / power off). It does **not** blank: gnome-shell-mobile grabs the key as a mutter keybinding — so logind's `HandlePowerKey=ignore` never applies — and its `powerManager.js` maps `power-button-action='nothing'` onto `'blank'`, so `'interactive'` is the only value that avoids a screen-off. Blanking itself is recoverable (press again), but the shell re-blanks a woken screen after a hardcoded 10 s whenever the screen shield is up, which is why `lock-enabled` is shipped false. |
| Wi-Fi | Works | MT7902 via mainline mt7921s. Confirmed on device 2026-08-15: firmware loads, `wlan0` appears, and a scan returns a dozen networks. Needs `CONFIG_FW_LOADER_COMPRESS_ZSTD` — linux-firmware ships the three MT7902 blobs `.zst`-compressed, and without it the loader reports `-2` for a file that is present, `hardware init failed`, and no `wlan0`. Carried by the pinned kernel since `ea54394`. |
| Bluetooth | Works | MT7902, same upstream firmware. |
| USB gadget | Works | Serial console, USB ethernet, SSH over USB. |
| Internal storage | Works | UFS. |
| Battery | Partial | Real current, charge and state of charge, from the MT6366 PMIC's FGADC coulomb counter (`mt6358-fg`) — it measures pack current through the sense element and integrates it in hardware. Verified on device 2026-08-16: capacity held at 32% across idle → 8 cores busy → idle while `current_now` tracked -126 → -245 → -128 mA, and charge integration came within 1% of the measured current over 60 s. Caveats: the state of charge is seeded from open-circuit voltage at boot (so it is re-seeded on every reboot) and measured against *design* capacity, since nothing here learns a real full-charge capacity. The pack's BQ78Z100 — which does all of that properly and persistently — still does not answer: every `bq27xxx-battery` read of `7-0055` returns `-ENXIO`. The bus is not the problem: the RT9471 at `0x53` on the same i2c-7 replies, a full scan finds only `0x53`, `0x55` NAKs both read and write addressing across 60 retries, and the bus measures 49.2 kHz against the 50 kHz the DT asks for. The vendor 5.10 tree was compared line by line — same bq27xxx glue, same pad tuning (RSEL_111 1k pull-up, applied and read back in hardware), byte-identical pinctrl rsel tables, equivalent controller quirks and AC timing — so nothing in software distinguishes us from the kernel that read `capacity 100` from that address. `mt6358-fg` stands aside automatically if the pack gauge ever reports `present=1`. Tracked as P7.1, now a hardware item: the pack connector's SMBus pair, or the gauge's own I²C block. |
| Suspend/resume | Not yet | s2idle aborts: `Freezing user space processes failed after 20.001 seconds (2 tasks refusing to freeze)`, twice per attempt, and returns with the panel dark. The device package therefore masks `suspend`/`sleep`/`hibernate`/`hybrid-sleep`/`suspend-then-hibernate.target`, which makes logind answer `CanSuspend=no` so GNOME's power menu cannot offer it. Unmask them when this works. |
| Audio | Not yet | |
| Sensors | Not yet | Accelerometer (mCube MC3416) and ambient-light/proximity (Memsic MN29xxx) are wired to the **SCP** (sensor co-processor), not an AP I²C bus, and are driven by the closed `scp_a.img` firmware. No gyro or magnetometer. A DT node + defconfig entry cannot expose them — this needs a mainline mt6789 SCP/sensorhub bring-up. The hall switch (magnetic lid) is the only directly-AP-wired sensor and is not in the DTS yet. |
| Cameras | Not yet | It is not yet confirmed the hardware has populated camera modules. |

Not listed means untested or unknown. Status updates land here as the port
progresses; upstreaming to postmarketOS is the goal, so this table also
tracks what is left before the device can move out of
`device/testing`.
