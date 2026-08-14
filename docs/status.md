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
| On-device UI | Works | Flutter shell + Go backend, hardware-rendered via Panfrost; onboarding on unprovisioned first boot. |
| Frontlight | Works | Dual RT4539 backlight drivers. |
| Wi-Fi | Works | MT7902 via mainline mt76; firmware from upstream linux-firmware. |
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
