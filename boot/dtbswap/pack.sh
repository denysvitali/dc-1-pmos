#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# pack.sh STUB DTB KERNEL OUT
#
# Lay out [stub | dtb | kernel], patch the stub's payload table, and gzip the
# result so LK's decompressor accepts it as a kernel. The output goes in the
# kernel slot of an Android boot image; see boot/repack-boot.sh.
#
# The stub can only overwrite properties that already exist in our dtb and are
# big enough to hold LK's values -- it cannot grow the tree with the MMU off.
# That is checked HERE, at build time, so the stub's fail-safe path stays a
# real safety net rather than the normal outcome.
set -eu

STUB=${1:?stub}; DTB=${2:?dtb}; KERNEL=${3:?kernel Image}; OUT=${4:?out}
command -v fdtget >/dev/null || { echo "pack: need fdtget (dtc)" >&2; exit 1; }

die() { echo "pack: $*" >&2; exit 1; }

# The stub can only overwrite properties that already exist and are large
# enough -- it cannot grow the tree with the MMU off. Rather than push
# placeholder padding into the board DTS (which should stay upstreamable), we
# prepare a padded working copy here, at build time, where fdtput can resize
# freely. The DTS stays clean; the packaging carries the constraint.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cp "$DTB" "$WORK/dtb"

# bootargs: LK's command line measures ~500 bytes on this device; 1024 is
# generous and costs nothing. The stub NUL-pads whatever slack is left.
fdtput -t s "$WORK/dtb" /chosen bootargs "$(printf '%1023s' '')" ||
	die "cannot pad /chosen/bootargs"

# initrd addresses: 4-byte cells, matching what LK writes on this device.
# copy_exact refuses a size mismatch rather than mis-place a big-endian value.
fdtput -t x "$WORK/dtb" /chosen linux,initrd-start 0 || die "cannot add linux,initrd-start"
fdtput -t x "$WORK/dtb" /chosen linux,initrd-end   0 || die "cannot add linux,initrd-end"

# /memory must already exist -- the stub only overwrites its reg, and a dtb
# with no memory node is a build mistake, not something to paper over.
fdtget "$WORK/dtb" /memory reg >/dev/null 2>&1 ||
	fdtget "$WORK/dtb" /memory@40000000 reg >/dev/null 2>&1 ||
	die "$DTB has no /memory reg"

DTB="$WORK/dtb"

align4() { echo $(( ($1 + 3) & ~3 )); }
SS=$(wc -c < "$STUB"); DS=$(wc -c < "$DTB"); KS=$(wc -c < "$KERNEL")
DOFF=$(align4 "$SS"); KOFF=$(align4 $((DOFF + DS)))

tmp=$WORK
cp "$STUB" "$tmp/img"
# Pad to each offset, then append.
dd if=/dev/zero bs=1 count=$((DOFF - SS)) >> "$tmp/img" 2>/dev/null
cat "$DTB" >> "$tmp/img"
dd if=/dev/zero bs=1 count=$((KOFF - DOFF - DS)) >> "$tmp/img" 2>/dev/null
cat "$KERNEL" >> "$tmp/img"

# Patch the payload table at 0x40 (4 x LE u32), and image_size at 0x10 so the
# kernel-image header still describes the whole blob.
python3 - "$tmp/img" "$DOFF" "$DS" "$KOFF" "$KS" <<'PY'
import struct, sys
p, doff, dlen, koff, klen = sys.argv[1], *map(int, sys.argv[2:6])
d = bytearray(open(p, 'rb').read())
assert d[56:60] == b'ARM\x64', "stub is not an arm64 Image"
struct.pack_into('<4I', d, 0x40, doff, dlen, koff, klen)
struct.pack_into('<Q', d, 0x10, len(d))          # image_size
open(p, 'wb').write(d)
PY

gzip -9 -n -c "$tmp/img" > "$OUT"
echo "pack: stub=$SS dtb=$DS@$DOFF kernel=$KS@$KOFF raw=$(wc -c < "$tmp/img") gz=$(wc -c < "$OUT")"
