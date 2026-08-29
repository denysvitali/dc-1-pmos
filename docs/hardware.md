# Hardware architecture and specification

This page records the DC-1's fixed board facts and the safety machinery around
booting and updating it. For current support verdicts, see the
[README summary](../README.md#hardware-support-at-a-glance); measurement history
and subsystem-specific invariants live under [`docs/hw/`](hw/).

## How the port boots

The DC-1 boots through MediaTek LK with A/B slots and LK fastboot. There is no
general recovery channel without a running kernel. LK builds the runtime device
tree from its signed `lk_main_dtb` merged with signed `dtbo`; neither image is a
safe replacement target, and the DTB in `vendor_boot` never reaches Linux.
Instead, both this project's installer and installed-system boot images carry
[`boot/dtbswap`](../boot/dtbswap/README.md). The stub occupies the unauthenticated
`boot.img` kernel slot, receives LK's arm64 handoff, copies LK's runtime
`bootargs`, initramfs addresses, and memory size into this port's DTB, then jumps
to the real kernel. Its failure paths hand the original LK tree to Linux.

Because a boot that runs but cannot be reached can otherwise strand the device,
`dc1-boot-watchdog` reboots after 10 unreachable minutes and escalates to LK
fastboot only after consecutive unreachable boots. An initramfs deadman and
rescue-path lease backstop cover earlier phases. Offline users can opt out with
`sudo touch /etc/dc1/boot-watchdog.disabled`; see
[Debugging and recovery](debugging.md).

Updates use the same A/B safety boundary. `dc1-update.timer` runs `apk update`
and `apk upgrade`; when the installed kernel changes, `dc1-boot-sync` downloads
and verifies the matching dtbswap boot image, writes and reads back the inactive
slot, and arms it for one attempt while retaining the proven slot as fallback.
A successful boot marks the new slot proven, while the boot-time sync service
retries deployments that could not complete during the package transaction.
This full update and slot-fallback path was first exercised end to end on
hardware on 2026-08-23. See [Staying current](installation.md#staying-current).

## Device specification

Daylight's [press kit](https://support.daylightcomputer.com/daylight-dc-1-press-kit-1)
is the most complete marketing specification and supplies details such as the
button set, speaker power, microphone configuration, and dimensions. Component
identification comes from the [FCC filing 2BFTUDC1](https://fcc.report/FCC-ID/2BFTUDC1)
(granted 2024-09-11), whose internal-board, antenna, and battery photographs
show installed part markings. MediaTek's
[platform article](https://www.mediatek.com/tek-talk-blogs/daylight-computer-1-powered-by-mediatek-helio-g99)
and [case study](https://www.mediatek.com/products/internet-of-things/case-studies/daylight-computer)
corroborate the platform; [Liliputing](https://liliputing.com/daylight-computer-dc-1-is-a-799-tablet-with-a-live-paper-display-designed-to-be-easy-on-the-eyes-but-not-the-wallet/)
and [The Verge](https://www.theverge.com/2024/7/20/24201356/daylight-computer-dc-1-hands-on)
provide hands-on detail. The community
[awesome-daylight-computer](https://github.com/hermeticvm/awesome-daylight-computer)
list indexes further coverage. Where a published claim conflicts with a live
measurement on this unit, the measurement is called out below and takes
precedence.

| Item | Published or photographed specification | Measured against this port |
| --- | --- | --- |
| Identity / boards | Daylight DC-1, FCC ID `2BFTUDC1`; ODM InnoComm Mobile Technology used the internal platform name *Jagar*, hence this repository's codename. FCC photographs show main PCB `Jagar-MB-R004` and button FPC `Jagar-Top_Key_FPC-R004`; the certification sample date, 2023-11-28, is not a production date. Launched in 2024 at $729, later $799. | `/proc/device-tree/model` reads `Daylight Computer DC-1` on dtbswap boots. |
| SoC | MediaTek **MT8781V** (Helio G99), 2× Cortex-A76 up to 2.2 GHz plus 6× Cortex-A55 up to 2.0 GHz, TSMC 6 nm-class. The die contains modem, GNSS, and camera-ISP blocks, but the DC-1 has no SIM/cellular hardware or cameras and its FCC grant covers Wi-Fi/Bluetooth only. | DVFS measures 725–2200 MHz on the A76 cluster and 500–2000 MHz on the A55 cluster; see [thermal](hw/thermal.md). |
| GPU | Arm Mali-G57 MC2. | Driven by Panfrost on the mainline tree; see [display and GPU](hw/display.md). |
| Memory + storage | SK hynix **H9QT0G6CN6-X146**, a 254-FBGA uMCP containing 8 GB LPDDR4X and 128 GB UFS (the G99 platform supports LPDDR4X-4266). The photographed UFS package supersedes the press kit's “128 GB eMMC” shorthand. | The storage controller measures as UFS; see [storage](hw/storage.md). |
| Power silicon | PMIC **MT6366MW** (9 bucks, 33 LDOs, audio codec, fuel gauge, and protection); charger/USB-PD IC **MT6375P**. | MT6366 supplies the codec/FGADC (`mt6358-fg`) and PMIC keys. `tcpci_mt6375` drives the MT6375 TCPCI bank, live-probed with Richtek VID `0x29cf` and PID `0x6375`; see [power](hw/power.md) and [audio](hw/audio.md). |
| Battery pack | **U2687144PV** by Shenzhen Utility Energy Co., pack code `1ICP3/67/144-2`: Li-ion, 3.8 V nominal, 8000 mAh / 30.4 Wh rated, 4.35 V limited-charge voltage. | Capacity matches the approximately 8 Ah pack used by the port's charge-rate calculations; see [power](hw/power.md). Daylight's “days per charge” claim assumes the front light is off. |
| Charging port | USB Type-C with USB PD. Daylight does not publish accepted PDOs, maximum wattage, USB data speed, or alt modes. | TCPM advertises fixed sink PDOs at 5 V/3 A, 9 V/3 A, and 12 V/3 A and selects the 12 V contract when available. Charging now defaults to a 3.15 A target (about 40%/h measured), with a 2 A target (about 22%/h) available through sysfs; see [power](hw/power.md). |
| Display | 10.5-inch greyscale LivePaper reflective LCD (not E Ink or bistable), 1600×1200, 4:3, about 190 ppi. The product ships at 60 Hz; Daylight has acknowledged a 6–120 Hz panel capability without enabling it. Daylight also documents an IGZO TFT backplane and DC/CCR, PWM-free LED drive. The panel uses MIPI-DSI, a matte anti-glare cover, and no temporal dithering. Exact module maker and part number are unpublished; a custom Sharp attribution remains unconfirmed. | The port ships 1200×1600 portrait scanout at 60 Hz over DSI; the panel is rotated 180 degrees relative to the glass. See [display](hw/display.md). |
| Front light | Independent white “Daylight” and Pure Amber channels, DC-dimmed to zero for reflective-only use. | Two RT4539 controllers: white on i2c-5 and amber on i2c-2; see [display](hw/display.md). |
| Touch / pen | Capacitive multitouch plus a batteryless Wacom EMR digitizer with palm rejection. Public sources do not specify touch sample rate, pen pressure levels, or tilt. | ILI2910 10-point touch plus a Wacom controller on i2c9 `0x09`, driven by mainline `wacom_i2c`; see [input](hw/input.md). |
| Wireless / RF | MediaTek **MT7902BSN**, dual antenna (ANT1+ANT2, InnoComm TJG01/Jagar dual-PIFA). The certified shipping specification is dual-band Wi-Fi 6 plus Bluetooth 5.0. MediaTek describes Wi-Fi 6E/BT 5.2 platform capability, but the FCC grant covers 2.4 GHz (2402–2480 MHz Bluetooth / 2412–2462 MHz Wi-Fi) and 5 GHz (5180–5825 MHz) only, not 6 GHz; treat the higher claims as unexercised platform capability. The grant records maximum conducted output of 0.001 W for Bluetooth, 0.097 W for 2.4 GHz Wi-Fi, and 8–12 mW across the 5 GHz bands; antenna characterization extends to 7.125 GHz. | MT7902 over SDIO is driven by mainline `mt7921s` and `btmtksdio`; see [wireless](hw/wireless.md). |
| Audio | Two 1 W speakers on `SPK-L`/`SPK-R` connectors and two microphones at `MIC301`/`MIC302` on the top-key FPC. | Two RT9101-amplified speakers and two digital microphones on AIN0/AIN2; see [audio](hw/audio.md). |
| Buttons | Power, Volume Up, Volume Down, “Quick Action,” and “Back Button” (also labelled Walkie-Talkie in older material). | Power and Volume Up use PMIC keys; Volume Down uses the keypad matrix. The two spare matrix keys are remapped from DT `KEY_F12`/`KEY_F11` to `KEY_PROG1`/`KEY_PROG2`, exposed as `XF86Launch1`/`XF86Launch2`, with configurable screenshot and Activities defaults; see [the user-facing map](installation.md#the-side-buttons). |
| Sensors | Daylight publishes no sensor list; the mainboard has a connector labelled Light Sensor. | MC3416 accelerometer on AP i2c6, an unbound ambient-light/proximity part at i2c1 `0x49`, and an AP-wired hall switch. No gyro or magnetometer is fitted; see [sensors](hw/sensors.md). |
| Expansion / I/O | microSD slot; maximum card size is unpublished. FCC photographs show five rear accessory pads with `POGO_VUSB_5V` silkscreen, but no public full pinout. | The microSD slot is wired as MSDC0 and an SDXC card enumerates as `mmcblk0`; pogo pads are unused and there is no headset jack. See [storage](hw/storage.md). |
| Dimensions / weight | 253.5 mm × 184 mm × 9.75 mm; 550 g (1.2 lb). | — |
| Stock software | Sol:OS based on Android 13, with approximately fortnightly automatic updates. | This repository replaces Sol:OS with postmarketOS/Alpine. |
