# dtbswap — get our device tree in front of the kernel

LK builds the kernel's device tree from **`lk_main_dtb`** (a signed image inside
the `lk` partition) merged with the signed **`dtbo`**. Both are authenticated
(`img_auth_required = 1`, `sbc_en = 1`), so neither can be replaced. Writing
`vendor_boot` does nothing — the DTB in it never reaches the kernel. `kexec` is
also out: it hangs on this SoC even with the stock tree (verified 2026-08-18).

`boot.img` is the one image LK does **not** authenticate. That makes this stub
the only route to boot a device tree we control.

## How it works

LK hands over using the arm64 Linux boot protocol: MMU and caches off,
`x0` = physical address of the tree it built. The stub sits where the kernel
would be, so it receives that handoff, then jumps to the real kernel with our
tree instead.

    boot.img kernel slot = gzip( [ stub | our dtb | real kernel Image ] )

LK gunzips the whole blob to one address and jumps to offset 0. Offsets are
patched into the stub's payload table at `0x40` by `pack.sh`.

## What is copied from LK's tree, and why

LK fills these in at run time; a statically built dtb cannot know them:

| property | reason |
| --- | --- |
| `/chosen/bootargs` | LK builds the whole command line itself and overwrites whatever the DTS says |
| `/chosen/linux,initrd-start` / `-end` | the ramdisk LK already placed in DRAM |
| `/memory` `reg` | LK patches the real DRAM size |

The stub cannot grow a tree with the MMU off, so it only ever overwrites
properties that already exist and are large enough. `pack.sh` prepares a padded
working copy of the dtb at build time (bootargs to 1024 bytes, initrd
placeholders) so the board DTS stays clean and upstreamable.

## Fail safe

Every failure path returns **LK's original fdt**, so a bad build boots exactly
like a stock one. That matters here: a slot that fails to boot costs a boot
cycle and leaves no log, because ramoops does not capture this kernel's output
and there is no UART header.

## Seeing what happens

`arch/arm64/kernel/jagar_fbcon.c` renders printk straight into the scanout LK
leaves running, and comes up at ~0.002 s. So a mainline-DT boot that fails is
**visible on the panel** — provided the framebuffer reservation stays out of
`no-map` (the board DTS says so explicitly). That is the only diagnostic channel
this device has; kexec could not use it because the first kernel had already
reprogrammed the display.

## Status

**Boots on hardware.** The appended kernel flags were confirmed reaching the
kernel on 2026-08-18 (`d6463dd`), and by `aa436ce` (2026-08-19) a mainline-DT
boot brought the display all the way up: DRM bound OVL/RDMA/DSI, card0 formed
with the DSI-1 connector, and gnome-shell ran with atomic modesetting. The
kernel relocation target (`KERNEL_RELOC_PA`, 0x44000000) is therefore
boot-proven. Not everything the stock tree described is in the mainline DTS
yet. Wi-Fi initially did not come up on a dtbswap boot; since 2026-08-19
the mt7921s driver works from the mainline DT (firmware staged by the
system initramfs) — see docs/hw/wireless.md.

## Build

    make
    ./pack.sh dtbswap.bin <our.dtb> <Image> out.gz
