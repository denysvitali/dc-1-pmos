# Wi-Fi and Bluetooth — measurement record

Deep-dive for the status-table rows *Wi-Fi* and *Bluetooth* in
[README.md](../../README.md#hardware-support-at-a-glance). Newest facts last.

## Wi-Fi

MT7902 via mainline mt7921s, **on the mainline device tree**, cold-boot
verified 2026-08-19: `mmc1` enumerates the chip at SDR104 at t=2.7 s,
firmware loads from the system initramfs, `wlan0` associates at t=14 s
with the provisioned credentials, and Tailscale comes up. Three fixes got
it there after the dtbswap switch dropped the signed dtbo that used to
enable it: the host node itself (kernel `231fa88`), the MSDC1 pad rails
VCN18/VMC that vendor `vioa/viob-supply` powered and mainline mtk-sd does
not (kernel `0c26bee` — with them off, pads muxed and card powered still
read all-low), and the boot-time firmware race (pmos `0f63c60`, blobs
staged in the initramfs the built-in driver reads at ~2.8 s).

Needs `CONFIG_FW_LOADER_COMPRESS_ZSTD` — linux-firmware ships the three
MT7902 blobs `.zst`-compressed, and without it the loader reports `-2`
for a file that is present, `hardware init failed`, and no `wlan0`.
Carried by the pinned kernel since `ea54394`.

Firmware discipline (repository rule): MT7902 firmware and
`regulatory.db` must come from upstream `linux-firmware` and
`wireless-regdb`, fetched at build time and checked by exact size and
SHA-256. Stock Android blobs can pass the old firmware handshake and
still fail mainline mt76 UNI commands — a same-named stock blob must
never ship.

Known wart: mt7921s fails its resume callback with `-EIO` after suspend,
then mac80211 re-authenticates by itself ~2.5 s later — see
[suspend.md](suspend.md).

## Bluetooth

MT7902, same upstream firmware — but it did **not** work on any real
boot, and an earlier "Works" here was wrong. `btmtksdio` is built in
(`=y`), so it probes as soon as the SDIO function is enumerated,
measured at t=1.75 s: before the root filesystem carrying `/lib/firmware`
exists. `mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin` comes back `-2`, btmtk
gives up with `Failed to setup 79xx firmware (-2)`, and `hci0` stays
registered but never completes setup. Nothing looks broken —
`/sys/class/bluetooth/hci0` and the rfkill switch are both present —
while `bluetoothctl` answers `No default controller available`. The
Wi-Fi half of the same chip survives the identical race only because
mt7921s retries the load itself; btmtksdio makes one attempt. Confirmed
by hand on 2026-08-17: one unbind/bind of `mmc1:0001:2` completed setup
in 2.75 s and brought the controller up as `Daylight DC-1`. `dc1-bluetooth`
(device pkgrel=34) does exactly that, ordered before bluetoothd.

**Cold-boot verified 2026-08-17** at kernel pkgrel=24 / device pkgrel=38:
the unit entered active 13 s into a boot that reached `graphical.target`
at 17.9 s, and `bluetoothctl show` reports the controller up as
`Daylight DC-1` with no manual intervention.

**Re-measured 2026-08-22 evening:** same auto-recovery this boot (`Failed
to setup 79xx firmware (-2)` at t=3 s, setup completed ≈8 s later via the
service's unbind/bind), rfkill clear, A2DP Source/Sink + AVRCP UUIDs
registered, and WirePlumber's bluez5 monitor loaded with
SBC/LDAC/aptX/AAC codec plugins — the entire local half of an A2DP chain
exists. `/var/lib/bluetooth` is empty (zero pairings ever) and
Pairable/Discoverable default off, so the remaining work is exactly one
session: enable pairable, pair a peer, stream.

**Fix shipped 2026-08-23 (installer + device r65):** the race now has a
winning side on new installs — `installer/build.sh` fetches
`BT_RAM_CODE_MT7902_1_1_hdr.bin` from upstream linux-firmware at build
time (exact size + SHA-256 checked, same discipline as the Wi-Fi blobs)
and stages it into the system initramfs at `/lib/firmware/mediatek/`,
mirroring the proven Wi-Fi pattern, so the single t=1.75 s load attempt
finds the blob on the initramfs root instead of failing. `dc1-bluetooth`
and its initd stay installed as the repair path but now exit 0
immediately unless dmesg carries the `Failed to setup 79xx firmware`
signature, so they never rebind a healthy controller; already-installed
devices (which converge by apk, not reflash) keep being recovered by that
service.

**State re-measured 2026-08-26 (running r37 boot, ~15 h uptime):**
`bluetoothctl show` reports the controller up — `Daylight DC-1`, public
address, Powered yes, A2DP/AVRCP UUIDs present, Pairable/Discoverable off.
The boot-time dmesg signature could not be re-checked on this boot: the
kernel ring had rotated (the then-active `rtc-s35390a` log storm, fixed
and hardware-verified in kernel r48; see [power.md](power.md), consumed
it). Whether this boot used the repair
unbind/bind or won the race outright is therefore unrecorded — the
fresh-boot check stays in [../roadmap.md](../roadmap.md), followed by the
pairing/streaming session that closes the row.

Pending: one boot from a rebuilt installer/boot image confirming setup
completes with no unbind/bind, then pair and stream A2DP.
