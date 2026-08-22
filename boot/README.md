# boot/ — Android boot-image v4 tooling for the DC-1

Two tools own the LK boot-image invariants (header v4, gzip kernel,
legacy-frame LZ4 ramdisk, non-zero 4096-byte AVB0 signature page):

- `mkboot/` — Go tool: `info`, `verify` (byte-identical round-trip against
  real vendor images), `pack`, `lkwrap`. See `mkboot/README.md`.
- `repack-boot.sh` — minimal POSIX-sh + python3 packer used by the build
  pipeline. Same invariants, fewer knobs.

Both produce the same image shape; `mkboot verify` is the cross-check.

## boot-signature.bin — provenance

`boot-signature.bin` is the 4096-byte v4 `boot_signature` page. It is
**vendor-derived AVB metadata** (an `AVB0` vbmeta blob emitted by
`avbtool 1.2.0`), extracted from the stock DC-1 `boot_a` partition. The same
page is already present, byte-identical, on every shipped device; it contains
no credentials or per-device data.

Why it is checked in verbatim instead of generated: this device's vbmeta is
flashed with `--disable-verity --disable-verification`, so LK requires the
signature *structure* to be present (an all-zero page makes the image silently
unbootable) but does not verify it against the payload — the identical blob
boots images with completely different kernels and ramdisks. Only this exact
vendor page is hardware-proven; whether LK would accept an arbitrary synthetic
`AVB0` structure has never been tested, and testing it costs a boot-recovery
cycle. If AVB verification is ever re-enabled, images must instead be signed
properly with `avbtool`.

SHA-256: `403d35c3dfd74f04d0c3e20b17f4031b3cbedb7de656b44ceb70b90580dd8009`
