# Hardware support status — Daylight DC-1 (`jagar`)

Status of the mainline-based kernel port this repository packages. "Works"
means it has functioned on real hardware in earlier bring-up; it does **not**
mean the artifacts built by any given CI run were booted — releases carry
`hardware_verified=false`, and CI only proves the build compiles.

This page is the **index**: the verdict table and the board reference.
The measurement history, root-cause narratives, and per-subsystem
invariants live one level down and are linked from every row:

- [hw/display.md](hw/display.md) · [hw/input.md](hw/input.md) ·
  [hw/audio.md](hw/audio.md) · [hw/wireless.md](hw/wireless.md) ·
  [hw/usb.md](hw/usb.md) · [hw/power.md](hw/power.md) (battery, charging,
  charging mode) · [hw/suspend.md](hw/suspend.md) ·
  [hw/thermal.md](hw/thermal.md) · [hw/sensors.md](hw/sensors.md) ·
  [hw/storage.md](hw/storage.md) · [gnome.md](gnome.md) (desktop stack).
- What is still open, with runbooks, is [roadmap.md](roadmap.md); the
  per-subsystem verification ledger is [verification.md](verification.md).

## How the port boots (load-bearing facts)

The device boots through MediaTek LK with A/B slots and exposes fastboot
from LK. There is no general recovery channel without a running kernel.
The kernel DT does **not** come from `vendor_boot`: LK constructs the
runtime tree from its *signed* `lk_main_dtb` inside `lk` merged with
signed `dtbo` (neither replaceable — an unsigned `dtbo` fails
authentication and kills the slot before the kernel starts; both slots of
the development device were lost that way once). Since 2026-08-19 the
device boots the **mainline device tree** via the `boot/dtbswap` stub:
`boot.img` is unauthenticated, so a stub in its kernel slot receives LK's
handoff and jumps to the real kernel with our DTB, copying LK's
runtime-patched `bootargs`, initrd addresses and `/memory` from the
merged tree; fail-safes return LK's original FDT. Hardware-verified
2026-08-19: `/proc/device-tree/model` reads `Daylight Computer DC-1`,
DRM binds OVL/RDMA/DSI, GNOME runs with atomic modesetting. See
[boot/dtbswap/README.md](../boot/dtbswap/README.md).

Losing the dtbo cuts both ways: the signed dtbo also *enabled* hardware.
The MT7902's SDIO host existed only through it (fixed by transcribing
the node into the board DTS, powering the MSDC1 pad rails, and staging
the firmware in the initramfs — kernel `231fa88`, `0c26bee`, pmos
`0f63c60`). The same pattern — "the dtbo enabled it, the board DTS must
now describe it" — is the first thing to check for anything that stops
working on the mainline tree. Of the devices that were bound on the
stock tree, only the hall switch and the two board NTC zones were genuine
losses; both were re-added to the mainline DTS before the switch
(kernel `3d3de59a5`, `981870b`).

**Reachability watchdog (hardware-verified 2026-08-19).** A boot the
network cannot reach used to be unrecoverable without a key combo. The
boot image self-deploys `dc1-boot-watchdog` into the installed system:
after 10 unreachable minutes it reboots, escalating to LK fastboot via
the `WDT_NONRST_REG2` nibble if consecutive boots stay unreachable; an
initramfs deadman (15 min) and a rescue-path lease backstop earlier
phases. Opt out with `touch /etc/dc1/boot-watchdog.disabled`. Details in
[debugging.md](debugging.md).

**OTA/slot machinery.** The full autonomous update cycle — CI green on a
pin, rolling release republished, `apk fix`, `dc1-boot-sync` writing the
inactive slot with read-back verification, first-try boot, slot marked
ok — ran end-to-end on hardware for the first time on 2026-08-23.

## Device specification (stock DC-1 hardware)

The most complete *marketing* spec sheet is Daylight's own
[press kit](https://support.daylightcomputer.com/daylight-dc-1-press-kit-1) —
the only such source that publishes the button set, per-speaker power,
microphone configuration and dimensions. The component-level detail below comes
from the [FCC filing 2BFTUDC1](https://fcc.report/FCC-ID/2BFTUDC1) (granted
2024-09-11), whose internal-board, antenna and battery photographs identify
installed parts by marking; MediaTek's
[blog](https://www.mediatek.com/tek-talk-blogs/daylight-computer-1-powered-by-mediatek-helio-g99)
and [case study](https://www.mediatek.com/products/internet-of-things/case-studies/daylight-computer)
corroborate the platform, and reviews from
[Liliputing](https://liliputing.com/daylight-computer-dc-1-is-a-799-tablet-with-a-live-paper-display-designed-to-be-easy-on-the-eyes-but-not-the-wallet/)
and [The Verge](https://www.theverge.com/2024/7/20/24201356/daylight-computer-dc-1-hands-on)
add hands-on detail (the community
[awesome-daylight-computer](https://github.com/hermeticvm/awesome-daylight-computer)
list indexes further coverage). Where a published claim contradicts something
measured on this unit, the measurement wins and the cell says so.

| Item | Specification (per sources above) | Against this port |
| --- | --- | --- |
| Identity / boards | Daylight DC-1, FCC ID `2BFTUDC1`; ODM InnoComm Mobile Technology, whose internal project name for the platform is *Jagar* — hence this repo's codename; main PCB `Jagar-MB-R004` and button FPC `Jagar-Top_Key_FPC-R004` per FCC photos (certification sample dated 2023-11-28, which is not a production date); launched 2024 at $729, later $799 | `/proc/device-tree/model` reads `Daylight Computer DC-1` on dtbswap boots |
| SoC | MediaTek **MT8781V** (Helio G99), octa-core: 2× Cortex-A76 up to 2.2 GHz + 6× Cortex-A55 up to 2.0 GHz, TSMC 6 nm-class. The G99 die also contains a Cat-13 modem, GNSS and camera ISP — silicon capabilities only: the DC-1 has neither SIM/cellular nor cameras, and its FCC grant covers Wi-Fi/BT exclusively | Matches measured DVFS: policy6 (A76 cluster, cpu6-7) 725–2200 MHz, policy0 (A55, cpu0-5) 500–2000 MHz — see Thermal |
| GPU | Arm Mali-G57 MC2 | Panfrost, native on the mainline DT — see GPU row |
| Memory + storage | SK hynix **H9QT0G6CN6-X146**, a single 254-FBGA uMCP holding both memories: 8 GB LPDDR4X (G99 platform max LPDDR4X-4266) + 128 GB UFS. This settles the press kit's "128 GB eMMC" line as marketing shorthand — the photographed package is UFS | Matches the unit: storage controller measures as UFS (see Internal storage row) |
| Power silicon | PMIC **MT6366MW** (9 bucks + 33 LDOs, integrated audio codec, fuel-gauge and protection); charger/USB-PD IC **MT6375P** | Both already drive this port: MT6366 supplies the codec/FGADC (`mt6358-fg`) and PMIC keys, and the charger driver is `tcpci_mt6375` over the MT6375 TCPCI bank (Richtek VID `0x29cf`/PID `0x6375` probed live) — see Battery/Audio rows |
| Battery pack | Pack model **U2687144PV** (Shenzhen Utility Energy Co., pack code `1ICP3/67/144-2`): Li-ion, 3.8 V nominal, rated 8000 mAh / 30.4 Wh, limited charge voltage 4.35 V | Capacity matches the ~8 Ah pack assumed by charge-rate math in the Battery row; "days per charge" is Daylight's claim with backlight off |
| Charging port | USB Type-C with USB PD. Neither the accepted PDOs, maximum wattage, USB data speed, nor alt-modes are published by Daylight — do not quote figures like "USB 3.1" or a watt class without hardware evidence | Port's TCPM sink declares fixed PDOs 5 V/3 A, 9 V/3 A, 12 V/3 A; ~27 W input observed under contract — see Battery row |
| Display | 10.5″ greyscale "LivePaper™" reflective LCD (not E Ink, not bistable), 1600 × 1200 (portrait 1200 × 1600), 4:3, ≈190 ppi (2000 diagonal px / 10.5″ = 190.48); 60 Hz product refresh (Daylight has acknowledged a 6–120 Hz panel capability without enabling it); IGZO TFT backplane and DC/CCR (PWM-free) LED driving confirmed by Daylight's engineering write-up; MIPI-DSI interface; matte anti-glare cover; no temporal dithering. Exact LCD module maker/P/N unpublished (more than one panel revision may exist) — community attribution to a custom Sharp IGZO panel is plausible but unconfirmed | Port runs the panel at 60 Hz over DSI; scanout is 180° from the glass — see Display row |
| Backlight | Two independently exposed channels: white "Daylight" light plus Pure Amber light, DC dimming (no PWM), dimmable to zero (pure reflective mode) | RT4539 pair: white on i2c-5, amber on i2c-2 — see Frontlight row |
| Touch / pen | Capacitive multitouch plus Wacom EMR passive digitizer (batteryless stylus, no Bluetooth pairing, palm rejection). Touch sampling rate, pressure levels and tilt spec are not publicly documented — do not attach guessed numbers (e.g. "4096 levels") | ILI2910 touch; digitizer on i2c9 `0x09` behind the mainboard's `Wacom`-marked connector, mainline `wacom_i2c` driver — see Pen digitizer row |
| Wireless / RF | Radio: MediaTek **MT7902BSN**, dual-antenna (ANT1+ANT2, InnoComm TJG01/"Jagar" dual-PIFA). Shipping/certified spec: Wi-Fi 6 dual-band + Bluetooth 5.0. MediaTek's case study credits the platform with Wi-Fi 6E/BT 5.2, but the FCC grant authorizes 2.4 GHz (2402–2480 BT / 2412–2462 Wi-Fi) and 5 GHz (5180–5825) only — no 6 GHz — so treat 6E/5.2 as unexercised platform capability. Grant's max conducted output: BT 0.001 W; 2.4 GHz Wi-Fi 0.097 W; 5 GHz 8–12 mW by band. Antennas were characterized to 7.125 GHz (ANT2 avg efficiency 58.7 % / 3.6 dBi at 2.4 GHz) | MT7902 over SDIO driven by mainline mt7921s / btmtksdio — see Wi-Fi and Bluetooth rows |
| Audio | Stereo speakers, 1 W each, on mainboard connectors labelled `SPK-L`/`SPK-R`; stereo microphone — two mic positions `MIC301`/`MIC302` on the top key FPC | Two RT9101 amp-fed speakers; two digital DMICs on AIN0/AIN2 (the "stereo mic") — see Audio row |
| Buttons | Five physical controls: Power, Volume Up, Volume Down, plus custom keys "Walkie-Talkie" and "Quick Action" | Power + Vol-up via PMIC keys, Vol-down via KPD matrix; the two custom keys are matrix positions (0,1)/(1,1) mapped `KEY_F11`/`KEY_F12` verbatim from stock — mapping needs on-device confirmation |
| Sensors | Daylight publishes nothing; the mainboard carries a connector explicitly labelled Light Sensor | From this unit: MC3416 accelerometer (AP i2c6), ambient-light/proximity part at i2c1 `0x49` (MEMSic `mn29xxx` family, undeclared), AP-wired hall switch; no gyro or magnetometer — see Sensors row |
| Expansion / I/O | microSD slot (mainboard location marked `SD Card`; max card size unspecified by Daylight); rear accessory contacts — five pogo pads visible in FCC photos, silkscreened `POGO_VUSB_5V`; full pinout unpublished | microSD wired as MSDC0 in the board DTS and hardware-verified 2026-08-23 (an SDXC card enumerates as `mmcblk0`); pogo unused by this port; no headset jack (measured) — see Storage row |
| Dimensions / weight | 253.5 mm × 184 mm × 9.75 mm; 550 g (1.2 lb) | — |
| Stock software | Sol:OS (Android 13); auto-updates ~every two weeks | This repository replaces Sol:OS with postmarketOS/Alpine |

## Status table

✅ works on hardware &nbsp;·&nbsp; 🟡 partly working, with a known limitation
&nbsp;·&nbsp; 🚧 being worked on, not usable yet &nbsp;·&nbsp; ⬜ untouched.
Every row links to its measurement record.

| Component | Status | Notes — full record |
| --- | --- | --- |
| Display | ✅ Works | 1200×1600 @ 60 Hz over DSI; blank/wake reliable since the MIPI-TX `DSI_SW_CTL_EN` sense fix (linux r37, verified 2026-08-24 with TE + DCS ground truth). Ground truth for display work is TE on GPIO83 and a DCS read of `0x0a`, never kernel logs. — [hw/display.md](hw/display.md) |
| GPU | ✅ Works | Mali-G57 MC2 via Panfrost, native on the mainline DT; devfreq cooling bound through LVTS ts3-0. — [hw/display.md](hw/display.md) |
| Touchscreen | ✅ Works | ILI2910, 10-point multitouch. — [hw/input.md](hw/input.md) |
| Pen digitizer | ✅ Works | Wacom EMR via mainline `wacom_i2c`; kernel events, pressure, barrel verified; eraser fixed for mid-proximity flips (linux r41, hands-on flip check pending); one hands-on ink-under-nib check across the glass awaits an r41 boot. — [hw/input.md](hw/input.md) |
| On-device UI | 🟡 Works, with shims | GNOME Mobile, hardware-accelerated; held together by the verified-minimal shim set (codified for fresh installs) plus version-skew fixes. Installer delivery of the shim set not yet exercised end-to-end. — [gnome.md](gnome.md) |
| Frontlight | ✅ Works | Dual RT4539 (white + amber), PWM-free; warmth quick-settings slider in the device package. — [hw/display.md](hw/display.md) |
| Power key | ✅ Works | Phone-like blank/wake toggle + ≥2 s power menu; first feel/timing exercise pending. — [hw/input.md](hw/input.md) |
| Wi-Fi | ✅ Works | MT7902 via mt7921s on the mainline DT; firmware staged in the system initramfs. — [hw/wireless.md](hw/wireless.md) |
| Bluetooth | 🚧 In progress | Controller comes up (repair path for the firmware race; initramfs staging shipped for new installs); pairing/streaming session and a fresh-boot race check pending. — [hw/wireless.md](hw/wireless.md) |
| USB gadget | 🚧 In progress | Serial console + ECM gadget up and verified on real boots; SSH over ECM from a host end-to-end pending. — [hw/usb.md](hw/usb.md) |
| configfs teardown | ✅ Resolved | Nothing removes gadget objects (any `rmdir` of a function wedges in D state — measured); the tree persists for the boot. — [hw/usb.md](hw/usb.md) |
| Internal storage | ✅ Works | UFS. — [hw/storage.md](hw/storage.md) |
| microSD | ✅ Works | MSDC0; `CONFIG_REGULATOR_GPIO` root cause fixed and hardware-verified 2026-08-23. — [hw/storage.md](hw/storage.md) |
| Battery | 🟡 Partial | Calibrated coulomb counter (2× r_fg fix); PD 12 V PDO verified end-to-end; default charge 2 A (~22 %/h), owner lever to 3.15 A (~40 %/h); SoC re-seeds from voltage each boot; pack gauge (BQ78Z100) does not answer (P7.1). — [hw/power.md](hw/power.md) |
| Charging mode | 🚧 Packaged, unverified | Headless `dc1-charging.target` (device pkgrel ≥ 79); ring mechanism verified live, `BOOT_REASON: 1` calibration session owed. — [hw/power.md](hw/power.md) |
| Suspend/resume | 🟡 Partial | One clean s2idle cycle on record; freezer fixed; sleep targets masked by design; escalation plan open. — [hw/suspend.md](hw/suspend.md) |
| Audio | ✅ Works | Stereo speakers + stereo DMIC capture verified; UCM2 profile adopted; idle-gain shadow fix verified on hardware 2026-08-26; one-time physical `speaker-test` probe pending. — [hw/audio.md](hw/audio.md) |
| Sensors | 🟡 Partial | Accelerometer + hall switch live on the mainline DT; physical tilt test never performed; ALS/proximity part has no mainline driver. — [hw/sensors.md](hw/sensors.md) |
| Thermal | 🟡 Partial | All 13 LVTS hot trips + NTC trips verified on hardware 2026-08-23; DVFS + three cooling devices live; occasional empty LVTS reads uninvestigated. — [hw/thermal.md](hw/thermal.md) |

Not listed means untested or unknown. Status updates land in the
per-subsystem records as the port progresses; upstreaming to postmarketOS
is the goal — what separates this port from that is tracked in
[roadmap.md](roadmap.md).
