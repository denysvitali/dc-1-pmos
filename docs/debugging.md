# Debugging the DC-1 installer

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
Saved as `lk-log.bin` plus a printable-text view `lk-log.txt`.

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
