# Debugging the DC-1 (installer and installed system)

Two debugging contexts exist, with different toolsets:

- **Installation mode** (the installer initramfs) — the `dc1-debug`
  toolkit described in the first half of this page.
- **The installed system** — the channels, evidence sources, and
  ground-truth measurement rules described in the second half. Read that
  half before trusting any "it booted/it's alive" conclusion on this
  hardware.

The installer initramfs carries a debugging toolkit (`dc1-debug`, part of the
`dc1tools` multi-call binary). Its primary interface is the touchscreen: a
**Debug tools (info / checksums / logs)** entry on the installer's main
menu. The same functions are plain subcommands for the USB shells, which
remain the fallback when the panel is dark.

> **Warning.** The debug tools are strictly read-only on partitions and on
> memory. They never flash anything, never select an A/B slot, and never
> write to `lk`, `dtbo`, `preloader`, `vendor_boot`, or the UFS boot LUNs.
> Their only writes are regular files under `/tmp/debug`, which is a tmpfs:
> everything collected is lost on reboot unless you copy it off the device.

## What the on-screen menu offers

**Device info** — one report with:

- the installer version/commit this image was built from (a git short SHA,
  `-dirty` on an unclean build tree; `unknown` if the build had no git);
- kernel release;
- the active A/B slot (`androidboot.slot_suffix` from the kernel command
  line) and boot reason;
- the partition table as seen by Linux (name, device, size);
- memory and uptime.

The kernel command line is filtered through a whitelist before it is shown:
the device serial number is deliberately never displayed, because debug
screens are exactly what gets photographed for bug reports.

**Partition checksums** — md5 and sha256 of `boot_a`, `boot_b`, `lk`,
`dtbo`, `misc`, and `expdb`, streamed in one read pass per partition.
Partitions above 256 MiB are skipped with a note rather than read, so a
mistyped name cannot turn into an hour-long read of `userdata`. The report
is also saved to `/tmp/debug/partition-hashes.txt`.

**Collect logs** — gathers every log source below into `/tmp/debug` and
shows a per-source summary. Individual sources may fail independently; the
summary says which succeeded.

**LK boot log** — reads the LittleKernel current-boot ring immediately and
pages its last ~60 printable lines on the panel (LK records slot selection
and fallback decisions at the end of the ring). It also saves the full ring
to `/tmp/debug/lk-log.txt` in the same format Collect logs uses, so what you
just read can be fetched over USB without a second trip.

Equivalent shell commands (over the USB network or the debug shell):

```sh
dc1-debug info
dc1-debug hash            # or: dc1-debug hash boot_a misc
dc1-debug logs            # or: dc1-debug logs lk
dc1-debug version
```

## Log sources, and where each one lives

**dmesg** — a snapshot of the kernel log, saved to `/tmp/debug/dmesg.txt`.
Taken non-destructively (the kernel ring is not consumed).

**LK bootloader log** — the LittleKernel current-boot log ring: 256 KiB of
physical RAM at `0x7ffbf000`, read through `/dev/mem` (possible because
`CONFIG_STRICT_DEVMEM` is off and the device tree keeps the region mapped).
Saved as `lk-log.bin` plus a printable-text view `lk-log.txt`; the **LK boot
log** menu entry shows the tail of that text on the panel directly.

This ring is reset before LK falls back to the other slot, so it normally
contains the log of the boot that **succeeded**. To see why a slot *failed*,
use the next source.

**expdb** — the partition where LK persists a failed slot's log. The layout
is undocumented, so the tool saves the first 16 MiB raw (`expdb.bin`) plus a
printable-text view (`expdb.txt`); the interesting lines are usually near the
end of the text view.

**pstore** — the kernel's pstore/ramoops records, if any, copied to
`/tmp/debug/pstore/`. Kernel support is built in with geometry from the LK
command line, and the toolkit mounts pstore itself on first use.

> **Warning.** pstore capture is **unverified on this hardware**. An empty
> pstore result is the expected outcome today and is not by itself evidence
> of a fault.

## Getting the files off the device

The device listens on its USB network at `172.16.42.1`. The image carries
dropbear (SSH) but **no scp and no sftp-server**, so pull files over the
shell:

```sh
# one file:
ssh root@172.16.42.1 cat /tmp/debug/partition-hashes.txt > partition-hashes.txt

# everything, concatenated with separators (the image has no tar/scp):
ssh root@172.16.42.1 'for f in /tmp/debug/*; do echo "===== $f"; cat "$f"; done' \
  > dc1-debug-bundle.txt
```

Without SSH, the raw shell on TCP port 4444 works too (`nc 172.16.42.1
4444`), including for a `cat file > /dev/tty` style copy.

## Sharing a bug report responsibly

Collected files may contain identifiers and internal state:

- The on-screen info view omits the serial number by design; raw files do
  not necessarily.
- Review `dmesg.txt` and `expdb.txt` before posting them publicly.
- Never share anything under `/tmp/wifi` (Wi-Fi credentials and association
  logs), and never share `authorized_keys`, key material, or password
  hashes.

## The installed system

### Channels in, ranked by usefulness

1. **SSH on port 22** — verified over Wi-Fi, password as set at install. The
   USB address is configured at `172.16.42.1`, but the host-side ECM/SSH test
   is still pending.
2. **USB serial** — `/dev/ttyGS0` streams the kernel log live (one-way);
   `/dev/ttyGS1` is an interactive root shell. Requires the USB cable.
3. **Raw root shell on TCP 4444** — `nc 172.16.42.1 4444`, USB cable
   only (the listener binds the usb0 address and is never exposed over
   Wi-Fi).

What each channel is and how to close them is in
[security.md](security.md).

### Evidence sources, and their traps

**Kernel logs do not prove the panel is lit.** Short DCS writes complete
host-side without a panel ACK, so the display pipeline can report a
flawless power-on (`production power sequence complete`, `first DSI
frame complete`) while the glass is uniformly white. The only
trustworthy panel-liveness signals are:

- the **TE line on GPIO83**: `gpiomon -c gpiochip0 83` — ~200 edges/2 s
  when the panel TCON runs, 0 when it does not; and
- a **DCS read of `0x0a`**: `0x9c` = booster|sleep-out|normal|display-on.

And a DCS read that times out latches the DSI handoff state machine into
its failed phase, refusing every re-enable until reboot — only probe a
state you are willing to lose. Full record: [hw/display.md](hw/display.md).

**LK's current-boot log** is readable from the installed system because
`CONFIG_STRICT_DEVMEM` is off and the DT keeps the region mapped:

```sh
dd if=/dev/mem bs=4096 skip=$((0x7ffbf000/4096)) count=64 | strings
```

This 256 KiB ring is reset before LK falls back, so it normally holds
the log of the slot that **succeeded**; a failed slot's persisted log is
in `expdb` (raw first ~16 MiB, read the tail of the printable view).
The ring also carries the `BOOT_REASON:` line the charging-mode
generator votes on — read it for yourself when debugging boot-mode
questions (journal tag `dc1-charging`). Prefer these logs over inferring
failure from silence; pstore is **not** a reliable channel for this port.

**Watch what rotates the kernel ring.** Loud per-second log sources evict
early-boot signatures (driver probes, firmware races) by the next
morning: builds before r48 logged `rtc-s35390a 8-0030: alarm IRQ with
INT2 flag clear; disarmed INT2` about twice per second (~24,000 lines per
long boot, observed 2026-08-26) until kernel `8f0bfe8f8a4c` stopped
registering the unusable alarm IRQ (verified on the 2026-08-28 r48 boot,
and still quiet on r54, 2026-08-29). When a fresh-boot signature matters,
check it immediately after boot, or read the persistent journal
(`journalctl -b -k`; note journals are root-owned — the default user is
not in `systemd-journal`).

**configfs:** never walk `/sys/kernel/config/usb_gadget/` recursively —
any `rmdir` of a gadget function object wedges in uninterruptible D
state for the rest of the boot, and recursive listings have hung behind
such wedges. Inspect shallow single-level listings only. Record:
[hw/usb.md](hw/usb.md).

### The reachability watchdog (what reboots your device)

`dc1-boot-watchdog` (self-deployed by the boot image) reboots the device
after 10 unreachable minutes — unreachable meaning: no inbound shell
connection, and no probe answer from the USB host (`172.16.42.2`) or the
Wi-Fi gateway. Consecutive unreachable boots escalate into LK fastboot
via the `WDT_NONRST_REG2` nibble. Backstops: an initramfs deadman
(15 min) and a rescue-path lease for pre-switch_root failures. The
headless charging target stands it down with an existence-based pat
file. Opt out: `sudo touch /etc/dc1/boot-watchdog.disabled`.

## Device flags and units reference

Opt-out flags (create with `touch`; all under `/var/lib/dc1/` unless
noted):

| Flag | Effect when present | Consumed by |
| --- | --- | --- |
| `/var/lib/dc1/no-auto-update` | `dc1-update.timer` skips its `apk update`/`apk upgrade` and parity report | `dc1-update` |
| `/var/lib/dc1/no-charging-mode` | Charging mode never engages; a plugged-in poweroff boot reaches the desktop | `dc1-charging-generator` |
| `/etc/dc1/boot-watchdog.disabled` | The reachability watchdog stays down | `dc1-boot-watchdog` |

State files (not opt-outs; do not create by hand):

| Path | Meaning | Written by |
| --- | --- | --- |
| `/var/lib/dc1/first-boot-apps-done` | First-boot app set finished; a gate for charging mode (an unprovisioned system always boots to the desktop) | `dc1-first-boot` |
| `/var/lib/dc1/poweroff-clean` | Epoch timestamp of the last clean shutdown (expires after 7 days); the fallback charging-mode signal | `dc1-poweroff-flag.service` (ExecStop) |
| `/run/dc1-boot-watchdog.pat` | Existence-based watchdog pat (charging mode keeps it present) | `dc1-charging-monitor` |

Units worth knowing (all from the device package unless noted):

| Unit | Job |
| --- | --- |
| `dc1-update.timer` | Post-boot + weekly `apk upgrade`, convergence parity report |
| `dc1-boot-sync` | Writes the inactive A/B slot with a new kernel/boot image, read-back verified (the OTA path) |
| `dc1-boot-watchdog` | Reachability watchdog (see above) |
| `dc1-usb-gadget` | Owns the UDC; completes the ACM+ECM gadget tree in place |
| `dc1-debug-shell` | ttyGS0 kmsg stream, ttyGS1 root shell, TCP 4444 root shell (usb0-only) |
| `dc1-audio` | Applies the known-good ALSA mixer state at boot, in the `sound.target` transaction |
| `dc1-bluetooth` | Dmesg-gated unbind/bind repair for the BT firmware race |
| `dc1-charging.target` + `dc1-charging-generator`/`-monitor` | Headless charging mode ([installation.md](installation.md#charging-mode)) |
| `dc1-orientation` | User-level accelerometer→compositor orientation bridge |
| `dc1-screen-backlight` | Mirrors DRM connector DPMS state onto both frontlight `bl_power` files |
| `dc1-display-gate` | Panel power-on sequencing gate at boot |
| `dc1-pwrkey` | Evdev power-key reader for charging mode (logind ignores the key) |
| `dc1-rtcsync.timer` | Periodic RTC sync |
| `dc1-fix-wireplumber-alsa` | Re-applies the WirePlumber 0.5.15 nil-concat guard (post-install/upgrade/trigger) |
| `dc1-link-apk-keys` | Restores Alpine key links for the signed repository |
