# Storage and expansion — measurement record

Deep-dive for the status-table rows *Internal storage* and
*Expansion / microSD* in [docs/status.md](../status.md).

## Internal storage

UFS (SK hynix H9QT0G6CN6-X146 uMCP: 8 GB LPDDR4X + 128 GB UFS — the
press kit's "128 GB eMMC" line is marketing shorthand; the photographed
package is UFS). ✅ Works; no open items.

## microSD

microSD wired as MSDC0 in the board DTS (card-detect + GPIO157 vqmmc
regulator, pins from measured stock values). Insertion invisibility
root-caused 2026-08-23: the DT's `regulator-gpio` `sdcard-io` rail
(GPIO157 select, 1.8/3.0 V states, vsim2-fed) had no driver because
`CONFIG_REGULATOR_GPIO` was unset in `jagar_defconfig`, so the device
never registered, msdc0 probe deferred forever after acquiring the CD
GPIO, and no mmc host appeared. Fix enabled and pinned (kernel
`27918e9d5c92`, linux pkgrel=31) and **verified on hardware 2026-08-23**:
`sdcard-io` registers, msdc0 comes up as `mmc0`, and an inserted 119 GiB
SDXC card enumerates as `mmcblk0` with its partition table. Closed.

Related MSDC fix kept for the pattern: the Wi-Fi half of the board
(MSDC1/MT7902) needed its pad rails VCN18/VMC declared because mainline
mtk-sd never enables the vendor `vioa/viob` supplies — kernel `0c26bee`;
see [wireless.md](wireless.md).

## Rear accessory contacts

Five pogo pads visible in FCC photos, silkscreened `POGO_VUSB_5V`; full
pinout unpublished. Unused by this port. No headset jack (measured).
