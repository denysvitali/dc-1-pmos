# mkboot

Boot-image tooling for the Daylight DC-1 (`jagar`, MT8781 / MT6789).

Replaces hand-crafting images with `dd`/`mkbootimg` plus remembered quirks. The
device-specific facts are encoded here so they get checked instead of recalled.

```
go build -o mkboot .
```

## Subcommands

| | |
|---|---|
| `mkboot info <img>` | print an Android boot image header |
| `mkboot verify <img>` | reparse + repack and prove byte-identical |
| `mkboot pack -kernel K -o OUT` | build a boot image (header v3/v4) |
| `mkboot lkwrap -in F -out G` | wrap a payload in an MTK `lk` partition header |

## Why `verify` matters

The only reason to trust the packer is that it reproduces real vendor images
exactly. Both known-good samples round-trip byte-for-byte:

```
$ mkboot verify boot_a-stock.img
round-trip OK: boot image is 20946944 bytes, byte-for-byte identical
trailing         46161920 bytes, 1167 non-zero
                 starts with AVB0 vbmeta (not reproduced; AVB is not enforced here)
                 AVB footer present in final page
```

Run it after changing anything in the packer.

## Device facts encoded here

**Boot header is v4**, `header_size` 1584, page size 4096. Stock `boot_a`:
kernel 19,558,146, ramdisk 1,380,092, `signature_size` 4096, cmdline **empty**
(LK builds the complete command line itself and overwrites the DTB's
`/chosen/bootargs` at handoff — the boot-image header field is ignored).

The 4096-byte v4 boot-signature page must be present and non-zero; this repo
ships it as `boot/boot-signature.bin` (see `boot/README.md` for provenance).
`-os-version 0x1800017b` sets the matching header field. The signature flag
requires exactly 4096 bytes and is emitted only for header v4.

**The kernel must be gzip'd.** Stock ships a gzip'd kernel (`1f 8b 08`); a
freshly built arm64 `Image` is raw and carries the arm64 header ending in
`ARMd`. EFI-stub builds additionally begin with `MZ`/PE metadata. Use
`-gzip-kernel`. For scale, our mainline `Image` compresses to a few MB.

**64 MiB is a hard ceiling with no headroom.** `boot_a`/`boot_b` are `0x4000000`
and fastboot's `max-download-size` is *also* exactly `0x4000000`, so an oversized
image can be neither stored nor sent. `pack` errors above the limit and warns
past 90%.

**AVB is not reproduced, deliberately.** A raw partition dump is: boot image,
then an `AVB0` vbmeta blob, then zeros, then a 64-byte footer in the last page.
It is not needed — the bootloader reports unlocked / `secure: no`, and a
Magisk-patched image whose hashes no longer matched booted fine.

**MTK `lk` header** (`lkwrap`) reproduces stock byte-for-byte across `0x00–0x4F`,
including the extended header at `0x30` (magic `0x58891689`) that U-Boot's
`mkimage` does **not** emit — almost certainly the "header v4" upstream pmOS
calls *"too annoying to work with"*. Stock uses name `"lk"` and loadaddr
`0xFFFFFFFF`.

> ⚠ `lkwrap` exists for completeness, but **do not flash an untested image to the
> `lk` slot the preloader loads.** This device's BROM is auth-locked (DAA, mem
> read/write auth, `Cmd 0xC8 blocked`) with no exploit available for MT6789, and
> there is no `lk1` fallback partition — a bad `lk` is an unrecoverable brick.
> Chainload from a boot slot instead.

## The unverified cmdline quirk

An early bring-up note asserted that this LK reads the boot-header cmdline at
**offset 64** (the v0–v2 location) rather than **44** (v3/v4), silently eating
the first 20 bytes, and recommended 20 bytes of padding.

That claim is **unverified** — the experiment set up to test it recorded no
conclusion, and stock v4 images boot fine. So it is *not* applied by default;
`-legacy-cmdline-offset` writes the cmdline at both offsets if it turns out to
be real.

`info` reports whatever sits at `0x40` so you can see the effect directly. With
`-cmdline "console=tty0 loglevel=7"`:

```
bytes@0x40      "l=7"  (legacy v0-v2 cmdline offset)
```

i.e. a legacy reader would receive only `l=7`. Note stock's cmdline is empty,
which is why the vendor would never have hit this.

## Example

```sh
mkboot pack \
  -kernel Image \
  -gzip-kernel \
  -ramdisk initramfs.cpio.lz4 \
  -signature ../boot-signature.bin \
  -os-version 0x1800017b \
  -o boot.img
mkboot info boot.img
```

For LK handoff experiments only, `-arm64-image-size SIZE` overrides the Linux
arm64 `Image` header's `image_size` field (offset `0x10`) before optional gzip
compression. It requires an `ARMd` header at offset `0x38`; omitted means
unchanged.

A kernel with no ramdisk will not reach userspace — pass `-ramdisk`.
