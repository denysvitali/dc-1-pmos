# Recovering a DC-1 that bootloops in the preloader

This is a last-resort page. It covers one specific failure — a DC-1 (`jagar`)
that restarts in a loop before LK ever offers `fastboot` — and one specific
repair: putting the `misc` partition back into a state LK can act on, over USB,
using MediaTek's download-agent protocol.

> **Read this first.**
>
> - The repair below needs the **signed download agent and its auth blob for
>   your device**. Those are proprietary vendor files. **This repository does
>   not contain them, will never publish them, and needs none of them to
>   build anything.** See [What you need](#what-you-need).
> - Even with a working download agent, the rules from
>   [installation.md](installation.md#recovery-notes) still hold: **never**
>   write `preloader`, `lk`, `dtbo`, or the UFS boot LUNs. A download agent
>   makes this recovery possible; damaging the chain that accepts it takes the
>   recovery away for good.
> - This page writes exactly one partition: `misc`. Nothing else.
> - Anything you read off the device — partition dumps included — is device
>   data. Keep it local; do not commit it here.

## Does this page apply to you?

Symptoms of the failure it repairs:

- The device restarts every few seconds. The panel stays dark, or flashes and
  goes dark again.
- It never reaches LK's `fastboot`: `fastboot devices` stays empty for as long
  as you care to wait.
- On the host, `sudo dmesg -w` (or `lsusb` in a loop) shows a MediaTek USB
  device appear and vanish on the same cycle as the resets — `0e8d:2000` or
  `0e8d:2001` (preloader), or `0e8d:0003` (BROM).

If you can reach `fastboot`, **you do not need this page.** Reflash `boot_a`
with a known-good image and reboot; a boot image that fails to boot is not
fatal, the watchdog puts you back in LK.

## Why `misc`

`misc` is small, it is not part of the boot chain, and it is the one partition
whose contents this device's LK *acts on* before it hands off. Two independent
structures live in it, and either one, in the wrong state, produces a device
that resets instead of booting.

**Byte 0 — the bootloader control block's command string.** LK's boot mode
selection compares that string against `boot-recovery` and `boot-fastboot`, and
**both of them resolve to RECOVERY**. This device has no recovery partition. A
stale command left in that field therefore sends every boot at a target that
does not exist, and it is tested *before* the register nibble that normally
means "go to fastboot" — so the usual ways back are not consulted at all. The
ordering is written down, with the disassembly it came from, in the header
comment of
`pmaports/device/testing/device-daylight-jagar/dc1-reboot-fastboot.c`. That is
also why our own tooling *clears* this field rather than writing it.

**Byte 2048 — the 32-byte A/B slot metadata.** LK and the preloader pick the
slot from this block: a 4-byte intent suffix, the magic `BCAB`, version 1,
`nb_slot` 2, a packed metadata byte per slot (priority in the low nibble, tries
in bits 4–6, `successful` in bit 7), and a CRC-32 over the first 28 bytes. A
block that fails validation, or one that leaves **zero bootable slots** (a slot
is bootable when `priority > 0` and either `successful == 1` or `tries > 0`),
gives the bootloader nothing to boot. The layout and the survivability rule are
the ones enforced by
`pmaports/device/testing/device-daylight-jagar/dc1-slotctl.c`, verified against
real blocks read from this device.

A `misc` in either state is what this page repairs. It is not the only way to
make a device loop — if your `misc` inspects clean in step 4, this is not your
fault path, and the right move is to stop rather than to start writing other
partitions.

## What you need

- A Linux host with `python3`, `git`, `gcc`, `xxd`, and a USB port.
- [mtkclient](https://github.com/bkerler/mtkclient).
- **The signed download agent and auth file for your device.** In a vendor
  flash package these are the files named along the lines of
  `DA_BR_<device>.bin` (the download agent) and `authsv5_<device>.auth` (the
  authentication blob the BROM asks for), usually next to the scatter/flash XML
  that references them. They are device-family-specific and signed; a generic
  agent is refused.

  This is the exception that the "no recovery channel without a running kernel"
  note in [installation.md](installation.md#recovery-notes) is about. That note
  is about an *arbitrary* download agent, which the DC-1's authenticated
  preloader will not run. A properly signed agent, with the auth blob to match,
  is accepted. Without both files, nothing on this page will work, and there is
  no substitute for them in this repository.

## 1. Set up mtkclient

```sh
git clone https://github.com/bkerler/mtkclient
cd mtkclient
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

sudo cp Setup/Linux/*.rules /etc/udev/rules.d/
sudo udevadm control -R && sudo udevadm trigger
```

If your distribution runs ModemManager, stop it for the duration — it opens the
MediaTek serial port before mtkclient can:

```sh
sudo systemctl stop ModemManager
```

Every command below is run from the mtkclient checkout with that virtualenv
active. To keep the lines short, export the two file paths once:

```sh
DA=/path/to/DA_BR_jagar.bin
AUTH=/path/to/authsv5_jagar.auth
```

## 2. Catch the device

A bootlooping device re-enumerates its USB port on every cycle, which is the
window mtkclient needs. **Start the command with the cable unplugged**, then
plug it in and let the tool grab the port on the next reset:

```sh
python mtk.py printgpt --loader "$DA" --auth "$AUTH"
```

The expected result is a partition table: `misc`, `boot_a`, `boot_b`,
`vendor_boot_a`, `userdata`, and the rest. If that prints, the agent is running
and everything below will work. If the tool sits in "Waiting for device",
unplug, re-run it, and plug in again — the catch is timing-sensitive and often
takes a few attempts.

(`--auth` is consumed in BROM mode, where download-agent authentication is
enforced. Passing it when the device answers in preloader mode is harmless, so
pass it every time.)

## 3. Back up `misc` before touching it

```sh
python mtk.py r misc misc.bin --loader "$DA" --auth "$AUTH"
```

Keep `misc.bin`. Read `misc` and nothing else — do not dump or write the
bootloader partitions, no matter how convenient it looks to have a copy.

## 4. Inspect it before changing it

```sh
xxd -l 32 misc.bin           # the command string
xxd -s 2048 -l 32 misc.bin   # the A/B control block
```

The first hexdump is the field discussed above: `boot-recovery` or
`boot-fastboot` in there is the fault, and anything non-zero is at least
suspicious. The second is the slot block; decode it with the device's own
validator, built straight from this repository on your host:

```sh
D=pmaports/device/testing/device-daylight-jagar
gcc -O2 -I"$D" -o /tmp/dc1-slotctl "$D/dc1-slotctl.c" "$D/dc1-misc.c"

/tmp/dc1-slotctl validate-hex "$(xxd -s 2048 -l 32 -p misc.bin)"
```

`validate-hex` reads nothing and writes nothing; it either prints the decoded
state or the exact reason the block is rejected (bad magic, bad version, wrong
slot count, CRC mismatch). A healthy block looks like this:

```
suffix=a active=a version=1 nb_slot=2 crc=0x45970c1b
  slot a: pri=15 tries=0 ok=1 BOOTABLE   slot b: pri=14 tries=0 ok=1 BOOTABLE
```

If the command field is empty **and** the block above validates with at least
one `BOOTABLE` slot, `misc` is not your problem. Stop here and read
[If it still loops](#if-it-still-loops).

## 5. Build a repaired image

This patches a *copy* of your dump: it zeroes the whole 2048-byte bootloader
message (command, status, recovery and stage fields — all of them stale by
definition on a device that cannot boot) and writes a fresh, correctly
CRC-ed slot block in which both slots are marked proven, with slot A preferred.

Save as `fix-misc.py`:

```python
#!/usr/bin/env python3
"""Repair a DC-1 `misc` dump: clear the BCB command, rebuild the A/B block.

usage: fix-misc.py <misc.bin> <misc-fixed.bin> [a|b]
"""
import binascii, struct, sys

BCB_OFF, BCB_LEN = 2048, 32


def pack_slot(priority, tries, successful):
    return priority | (tries << 4) | (successful << 7)


def build_control(prefer):
    b = bytearray(32)
    b[0:4] = b"_a\0\0" if prefer == "a" else b"_b\0\0"
    b[4:8] = b"BCAB"                       # magic, u32 0x42414342 LE
    b[8] = 1                               # version
    b[9] = 2                               # nb_slot, low 3 bits
    b[12] = pack_slot(15 if prefer == "a" else 14, 0, 1)   # slot a
    b[14] = pack_slot(14 if prefer == "a" else 15, 0, 1)   # slot b
    b[28:32] = struct.pack("<I", binascii.crc32(bytes(b[:28])) & 0xffffffff)
    return bytes(b)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    prefer = (sys.argv[3] if len(sys.argv) > 3 else "a").lower()
    if prefer not in ("a", "b"):
        sys.exit("slot must be a or b")

    data = bytearray(open(src, "rb").read())
    if len(data) < BCB_OFF + BCB_LEN:
        sys.exit(f"{src} is only {len(data)} bytes; that is not a misc dump")

    old_cmd = bytes(data[0:32]).split(b"\0")[0].decode("ascii", "replace")
    print(f"old command field: {old_cmd!r}")
    print(f"old control block: {bytes(data[BCB_OFF:BCB_OFF + BCB_LEN]).hex()}")

    data[0:BCB_OFF] = b"\0" * BCB_OFF                      # bootloader_message
    data[BCB_OFF:BCB_OFF + BCB_LEN] = build_control(prefer)  # bootloader_control

    print(f"new control block: {bytes(data[BCB_OFF:BCB_OFF + BCB_LEN]).hex()}")
    open(dst, "wb").write(bytes(data))
    print(f"wrote {dst} ({len(data)} bytes)")


main()
```

Run it, then check the result with the same validator before it goes anywhere
near the device:

```sh
python3 fix-misc.py misc.bin misc-fixed.bin a
/tmp/dc1-slotctl validate-hex "$(xxd -s 2048 -l 32 -p misc-fixed.bin)"
```

Expect `slot a: pri=15 … BOOTABLE   slot b: pri=14 … BOOTABLE`. Both slots stay
bootable on purpose: preferring A still leaves B as a fallback.

Pass `b` instead of `a` if you want the other slot preferred — for example if
you flashed this repository's images to `boot_a` and want the stock slot to run
first. Do not "repair" by preferring a slot whose boot image you know is
missing.

## 6. Write it back

```sh
python mtk.py w misc misc-fixed.bin --loader "$DA" --auth "$AUTH"
python mtk.py reset
```

`w` writes a whole partition image, which is exactly why step 5 patches a copy
of the full dump instead of poking 32 bytes at an offset — a short file would
truncate the partition.

Then unplug the cable, hold the power button for ~10 s to make sure nothing is
half-alive, and power the device on. A device whose only problem was `misc`
comes up into its normal boot, or into LK's `fastboot` if the selected slot has
no usable image — either of which is a device you can work with again.

## If it still loops

Read `misc` back first and confirm the write actually took (repeat steps 3–4;
the command field should be empty and the block should validate). If it did,
and the device still loops, then `misc` was not the cause.

**Do not start writing other partitions to find out what was.** The reason this
recovery exists at all is that the preloader and LK are intact and still accept
a signed agent; every write to `preloader`, `lk`, `dtbo` or a UFS boot LUN
risks that, and a failure there is not recoverable by any procedure in this
repository.

What is safe, and worth doing before asking for help:

- `python mtk.py printgpt …` — confirm the partition table still looks sane.
- `python mtk.py r boot_a boot_a.img …` — read back what is actually in the
  slot you flashed, and check it is the image you think it is.

Note that a bad *boot image* does not produce this failure: if LK gets far
enough to load `boot_a`, a kernel that dies leaves you in LK's `fastboot` after
the watchdog reset. A loop that never reaches `fastboot` is a bootloader-stage
problem, and `misc` is the only part of that stage this repository will tell
you to write.
