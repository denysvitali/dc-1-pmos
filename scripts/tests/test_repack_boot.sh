#!/bin/sh
# Exercise the boot-image packer with tiny deterministic inputs. This stays
# offline and unprivileged so the fast verification job can guard the image
# shape before the much more expensive release build runs.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
packer="$here/../../boot/repack-boot.sh"
signature="$here/../../boot/boot-signature.bin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0 HUP INT TERM

fail() { echo "repack-boot test failed: $*" >&2; exit 1; }

# repack-boot.sh accepts a raw Image and deterministically gzip-compresses it.
printf 'dc1 deterministic kernel fixture\n' >"$tmp/Image"
gzip -9 -n <"$tmp/Image" >"$tmp/expected-kernel.gz"

# A valid legacy LZ4 frame containing one 12-byte, literals-only block:
# magic, little-endian compressed block size 13, token 0xc0, then the bytes.
# Constructing it directly avoids adding lz4 to the verification job.
printf '\002\041\114\030\015\000\000\000\300dc1-ramdisk\n' \
	>"$tmp/initramfs.cpio.lz4"

sh "$packer" "$tmp/Image" "$tmp/initramfs.cpio.lz4" "$tmp/boot-1.img" \
	>"$tmp/positive-1.log" 2>&1 || {
	cat "$tmp/positive-1.log" >&2
	fail "packer refused deterministic fixtures"
}
sh "$packer" "$tmp/Image" "$tmp/initramfs.cpio.lz4" "$tmp/boot-2.img" \
	>"$tmp/positive-2.log" 2>&1 || {
	cat "$tmp/positive-2.log" >&2
	fail "packer refused the same fixtures on a second run"
}
cmp "$tmp/boot-1.img" "$tmp/boot-2.img" >/dev/null 2>&1 ||
	fail "identical inputs did not produce byte-identical boot images"

python3 - "$tmp/boot-1.img" "$tmp/Image" "$tmp/expected-kernel.gz" \
	"$tmp/initramfs.cpio.lz4" "$signature" <<'PYEOF'
import gzip
import hashlib
import struct
import sys

image_path, raw_kernel_path, gzip_kernel_path, ramdisk_path, signature_path = sys.argv[1:]
image = open(image_path, "rb").read()
raw_kernel = open(raw_kernel_path, "rb").read()
gzip_kernel = open(gzip_kernel_path, "rb").read()
ramdisk = open(ramdisk_path, "rb").read()
signature = open(signature_path, "rb").read()


def require(condition, message):
    if not condition:
        raise SystemExit("repack-boot test failed: " + message)


def aligned(size):
    return (size + 4095) & ~4095


magic, kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from(
    "<8sIIII", image, 0
)
header_version = struct.unpack_from("<I", image, 40)[0]
signature_size = struct.unpack_from("<I", image, 1580)[0]

require(magic == b"ANDROID!", "missing ANDROID! magic")
require(header_version == 4, "header version is not 4")
require(header_size == 1584, "header_size is not 1584")
require(os_version == 0x1800017B, "os_version drifted from the hardware-proven value")
require(signature_size == 4096, "signature_size is not 4096")
require(image[44:1580] == bytes(1536), "normally-empty cmdline field is not zeroed")
require(image[1584:4096] == bytes(4096 - 1584), "header padding is not zeroed")

kernel_offset = 4096
ramdisk_offset = kernel_offset + aligned(kernel_size)
signature_offset = ramdisk_offset + aligned(ramdisk_size)
require(kernel_size == len(gzip_kernel), "kernel_size does not describe the gzip payload")
require(image[kernel_offset:kernel_offset + kernel_size] == gzip_kernel,
        "gzip kernel is not placed immediately after the header page")
require(gzip.decompress(image[kernel_offset:kernel_offset + kernel_size]) == raw_kernel,
        "placed gzip payload does not contain the input kernel")
require(image[kernel_offset + kernel_size:ramdisk_offset] == bytes(aligned(kernel_size) - kernel_size),
        "kernel padding is not zeroed")
require(ramdisk_size == len(ramdisk), "ramdisk_size does not describe the input ramdisk")
require(image[ramdisk_offset:ramdisk_offset + ramdisk_size] == ramdisk,
        "ramdisk is not placed exactly after the padded kernel")
require(image[ramdisk_offset + ramdisk_size:signature_offset] ==
        bytes(aligned(ramdisk_size) - ramdisk_size), "ramdisk padding is not zeroed")
require(len(image) == signature_offset + 4096, "signature is not the exact image tail")
require(image[-4096:] == signature, "image tail differs from boot-signature.bin")
require(hashlib.sha256(image[-4096:]).hexdigest() ==
        "403d35c3dfd74f04d0c3e20b17f4031b3cbedb7de656b44ceb70b90580dd8009",
        "image signature tail hash drifted from recorded provenance")
require(len(image) <= 0x4000000, "image exceeds the 64 MiB boot partition")
PYEOF

# Fail closed on each malformed input the packer promises to reject.
printf '\004\042\115\030not-legacy\n' >"$tmp/bad-ramdisk.lz4"
if sh "$packer" "$tmp/Image" "$tmp/bad-ramdisk.lz4" \
	"$tmp/bad-ramdisk.img" >"$tmp/bad-ramdisk.log" 2>&1; then
	fail "packer accepted a ramdisk without legacy-LZ4 magic"
fi
grep -q 'ramdisk is not legacy-frame LZ4' "$tmp/bad-ramdisk.log" || {
	cat "$tmp/bad-ramdisk.log" >&2
	fail "bad ramdisk failed for an unexpected reason"
}

printf 'AVB0short' >"$tmp/short-signature.bin"
if SIGFILE="$tmp/short-signature.bin" sh "$packer" "$tmp/Image" \
	"$tmp/initramfs.cpio.lz4" "$tmp/short-signature.img" \
	>"$tmp/short-signature.log" 2>&1; then
	fail "packer accepted a boot signature shorter than 4096 bytes"
fi
grep -q 'boot signature must be exactly 4096 bytes' "$tmp/short-signature.log" || {
	cat "$tmp/short-signature.log" >&2
	fail "short signature failed for an unexpected reason"
}

{
	printf 'NOPE'
	dd if="$signature" bs=1 skip=4 2>/dev/null
} >"$tmp/non-avb-signature.bin"
if SIGFILE="$tmp/non-avb-signature.bin" sh "$packer" "$tmp/Image" \
	"$tmp/initramfs.cpio.lz4" "$tmp/non-avb-signature.img" \
	>"$tmp/non-avb-signature.log" 2>&1; then
	fail "packer accepted a 4096-byte signature without AVB0 magic"
fi
grep -q 'boot signature does not start with AVB0' "$tmp/non-avb-signature.log" || {
	cat "$tmp/non-avb-signature.log" >&2
	fail "non-AVB signature failed for an unexpected reason"
}

overlong_cmdline=$(awk 'BEGIN { for (i = 0; i < 1536; i++) printf "x" }')
if sh "$packer" "$tmp/Image" "$tmp/initramfs.cpio.lz4" \
	"$tmp/overlong-cmdline.img" "$overlong_cmdline" \
	>"$tmp/overlong-cmdline.log" 2>&1; then
	fail "packer accepted a 1536-byte cmdline with no room for NUL"
fi
grep -q 'cmdline too long for the header field' "$tmp/overlong-cmdline.log" || {
	cat "$tmp/overlong-cmdline.log" >&2
	fail "overlong cmdline failed for an unexpected reason"
}

echo "repack-boot tests passed"
