#!/bin/sh
# repack-boot.sh -- build an Android boot image v4 for the Daylight DC-1
# ("jagar") from a kernel Image and an initramfs cpio.
#
#   ./repack-boot.sh <Image or Image.gz> <initramfs.cpio.lz4> <out.img> [cmdline]
#
# This script owns the LK boot-image invariants for this device. Every one of
# them was measured on hardware, and every one of them fails as a silently
# non-booting image rather than as an error, which is why they are all checked
# here where the failure is cheap:
#
#   * header v4, header_size 1584, page size 4096 (v3+ fixes it at 4096; there
#     is no page_size field to read).
#   * kernel is a GZIPPED Image, not a raw one.
#   * ramdisk is LEGACY-frame LZ4 (magic 02 21 4c 18), NOT the modern frame
#     (04 22 4d 18). The lz4 CLI default is the modern frame; use `lz4 -l`.
#   * os_version is 0x1800017B. LK is not known to check it, but "not known to"
#     is not "verified not to", so it is copied verbatim rather than left 0.
#   * the v4 header has one field v3 does not: signature_size, a uint32 at
#     offset 1580 (right after the 1536-byte cmdline), which is why sizeof is
#     1584 and not 1580. It must be 4096, matching the trailing page.
#   * cmdline is EMPTY in known-good images; LK builds the complete command
#     line itself and overwrites the DTB /chosen/bootargs at handoff. An
#     optional 4th argument writes the
#     header's 1536-byte cmdline field, but MEASUREMENT SAYS THIS LK IGNORES
#     THAT FIELD ENTIRELY: an image carrying marker arguments booted with a
#     /proc/cmdline containing none of them. Do not rely on it.
#
#   * THE TRAILING PAGE IS THE v4 boot_signature AND IT MUST NOT BE ZEROS.
#     Every image this bootloader has ever accepted carries a 4096-byte blob
#     there starting with "AVB0" and containing "avbtool 1.2.0". An image with
#     that page zeroed flashes happily and then simply does not boot, and the
#     failure is indistinguishable from a bad kernel.
#
#     The blob is BYTE-IDENTICAL across 12 known-booting images with completely
#     different kernels and ramdisks, so it is not a hash over the content:
#     vbmeta on this device is flashed with --disable-verity
#     --disable-verification, so LK requires the structure to be present but
#     does not check it against the payload. It is therefore checked in as
#     boot/boot-signature.bin (vendor-derived AVB metadata already present on
#     every device; see boot/README.md) and copied verbatim. If verification is
#     ever re-enabled this stops being valid and images will need to be signed
#     properly with avbtool.
set -eu

IMAGE=${1:?usage: repack-boot.sh <Image> <initramfs.cpio.lz4> <out.img> [cmdline]}
RAMDISK=${2:?}
OUT=${3:?}
CMDLINE=${4:-}

HERE=$(cd "$(dirname "$0")" && pwd)
SIGFILE=${SIGFILE:-$HERE/boot-signature.bin}
[ -f "$SIGFILE" ] || { echo "missing $SIGFILE -- images built without it do not boot" >&2; exit 1; }

command -v gzip >/dev/null || { echo "need gzip" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Accept an already-gzipped kernel verbatim. Re-gzipping one that came out of
# an existing boot image would not reproduce it byte-for-byte (gzip -9 -n is
# not the only setting that produced known-good images), which makes it
# impossible to prove a repack is faithful by diffing it against the image it
# came from. That proof is the whole point of doing a ramdisk-only edit.
if [ "$(od -An -N2 -tx1 "$IMAGE" | tr -d ' \n')" = "1f8b" ]; then
	cp "$IMAGE" "$TMP/kernel.gz"
else
	gzip -9 -n < "$IMAGE" > "$TMP/kernel.gz"
fi

python3 - "$TMP/kernel.gz" "$RAMDISK" "$OUT" "$CMDLINE" "$SIGFILE" <<'PYEOF'
import struct, sys

kpath, rpath, out, cmdline, sigpath = sys.argv[1:6]
kern = open(kpath, 'rb').read()
rd   = open(rpath, 'rb').read()
sig  = open(sigpath, 'rb').read()

P = 4096

# Each of these has actually gone wrong at least once, and each fails as a
# silent non-booting image rather than as an error, so they are checked here
# where the failure is cheap.
if rd[:4] != bytes([0x02, 0x21, 0x4c, 0x18]):
    sys.exit("ramdisk is not legacy-frame LZ4 (magic %s); use lz4 -l" % rd[:4].hex())
if kern[:2] != b'\x1f\x8b':
    sys.exit("kernel is not gzip")
if len(sig) != P:
    sys.exit("boot signature must be exactly %d bytes, got %d" % (P, len(sig)))
if sig[:4] != b'AVB0':
    sys.exit("boot signature does not start with AVB0 -- image would not boot")
if len(cmdline) >= 1536:
    sys.exit("cmdline too long for the header field (max 1535 + NUL)")

def pad(b):
    r = len(b) % P
    return b + (b'\0' * (P - r) if r else b'')

HDR = 1584
OS_VERSION = 0x1800017B

h = bytearray(HDR)
struct.pack_into('<8sIIII', h, 0, b'ANDROID!', len(kern), len(rd), OS_VERSION, HDR)
struct.pack_into('<I', h, 40, 4)          # header_version
if cmdline:                               # offsets 44..1579, normally zeros
    h[44:44 + len(cmdline)] = cmdline.encode()
struct.pack_into('<I', h, 1580, P)        # v4 signature_size

img = pad(bytes(h)) + pad(kern) + pad(rd) + sig

# boot_a/boot_b are 0x4000000 bytes and fastboot's max-download-size is also
# exactly 0x4000000: an oversized image can be neither stored nor sent.
LIMIT = 0x4000000
if len(img) > LIMIT:
    sys.exit("image is %d bytes, larger than the %d-byte boot partition / "
             "fastboot download limit" % (len(img), LIMIT))

open(out, 'wb').write(img)
print("%s: %d bytes (kernel %d, ramdisk %d, signed)%s"
      % (out, len(img), len(kern), len(rd),
         ("\n  cmdline: " + cmdline + "  [NOTE: this LK ignores the header cmdline]")
         if cmdline else ""))
PYEOF
