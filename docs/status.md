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
| On-device UI | Partial | Flutter shell + Go backend render on the panel, hardware-accelerated via Panfrost — confirmed on device. First-boot **onboarding** now runs on hardware: the Wi-Fi step was captured on the panel listing real networks with signal strengths (2026-08-15, via `GET /screenshot`). The later steps (account, hostname, timezone, confirm) are **still unexercised on hardware** — the kernel has no `CONFIG_INPUT_UINPUT` and the seat exposes touch only, so there is no way to synthesise a tap yet. Try the whole flow in a browser at <https://denysvitali.github.io/dc-1-pmos/>. |
| Frontlight | Works | Dual RT4539 backlight drivers. |
| Wi-Fi | Works | MT7902 via mainline mt7921s. Confirmed on device 2026-08-15: firmware loads, `wlan0` appears, and a scan returns a dozen networks. Needs `CONFIG_FW_LOADER_COMPRESS_ZSTD` — linux-firmware ships the three MT7902 blobs `.zst`-compressed, and without it the loader reports `-2` for a file that is present, `hardware init failed`, and no `wlan0`. Carried by the pinned kernel since `ea54394`. |
| Bluetooth | Works | MT7902, same upstream firmware. |
| USB gadget | Works | Serial console, USB ethernet, SSH over USB. |
| Internal storage | Works | UFS. |
| Battery | Partial | Basic battery telemetry only. |
| Suspend/resume | Not yet | |
| Audio | Not yet | |
| Sensors | Not yet | |
| Cameras | Not yet | It is not yet confirmed the hardware has populated camera modules. |

Not listed means untested or unknown. Status updates land here as the port
progresses; upstreaming to postmarketOS is the goal, so this table also
tracks what is left before the device can move out of
`device/testing`.
