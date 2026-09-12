# mkboot

Go tooling to inspect, round-trip, and pack Android boot v3/v4 images for the
Daylight DC-1. Release images are built through
[`installer/build.sh`](../../installer/README.md#building), which supplies the
required [DT swap payload](../dtbswap/README.md). `mkboot pack` alone does not
enforce that payload or validate a ramdisk's compression format.

## Build and inspect

From this directory:

```sh
go build -o mkboot .
go vet ./...
go test ./...
./mkboot info /path/to/installer-boot.img
./mkboot verify /path/to/installer-boot.img
```

`verify` reparses and repacks the image, checking byte identity of the boot
image sections. It reports trailing partition data separately; a successful
round-trip is not cryptographic signature validation or proof of booting.
Run it on both generated boot images after changing the packer.

## Commands

| Command | Purpose |
| --- | --- |
| `mkboot info IMAGE` | Print the Android boot header and section details |
| `mkboot verify IMAGE` | Reparse and repack the boot image sections byte-for-byte |
| `mkboot pack -kernel PAYLOAD -o IMAGE` | Pack a v3/v4 image; use the full DC-1 contract below |
| `mkboot lkwrap -in FILE -out FILE` | Low-level MTK header utility; not part of installation or release assembly |

## DC-1 image contract

- Android **header v4**, header size 1584, page size 4096.
- A gzip-compressed **`[stub | DTB | kernel Image]`** payload for both boot images.
- A **legacy-frame LZ4** initramfs; a kernel without the ramdisk cannot reach
  the installed root filesystem through this boot path.
- A nonzero **4096-byte AVB0** boot-signature page. Its exact hash and
  [provenance](../README.md#boot-signaturebin--provenance) are recorded in the
  repository. The page is retained unchanged; it does not sign new payloads.
- OS-version field `0x1800017b`, matching the proven image shape.
- Maximum image size **64 MiB**, imposed by both boot partitions and fastboot's
  download limit. The packer rejects oversized images and warns above 90%.

LK builds the effective kernel command line itself. Do not use the boot-header
`-cmdline` field as a diagnostic marker or rely on it to set kernel behavior.
The historical `-legacy-cmdline-offset` option remains in the tool for old
experiments; it is not used by the production build.

The `lkwrap` utility does not make a replacement LK image acceptable to the
boot chain. **Never flash `lk`, `preloader`, `dtbo`, `vendor_boot`, or UFS boot
LUNs** as part of this port's installation. See the
[recovery limits](../../docs/installation.md#recovery-notes).

## Low-level packing example

Run from the repository root with the matching raw kernel `Image`, board DTB,
and prebuilt legacy-LZ4 initramfs. This illustrates the components; prefer the
installer builder to assemble release images.

```sh
mkdir -p out
make -C boot/dtbswap
boot/dtbswap/pack.sh boot/dtbswap/dtbswap.bin jagar.dtb Image out/payload.gz
go build -o boot/mkboot/mkboot ./boot/mkboot/main.go
boot/mkboot/mkboot pack \
  -kernel out/payload.gz \
  -ramdisk initramfs.cpio.lz4 \
  -signature boot/boot-signature.bin \
  -os-version 0x1800017b \
  -o out/boot.img
boot/mkboot/mkboot verify out/boot.img
```

The optional `-arm64-image-size SIZE` override is for handoff experiments on
raw arm64 Images with the `ARMd` header. It is not a release-build setting.
