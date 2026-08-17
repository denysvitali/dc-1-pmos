#!/bin/sh
# Offline tests for the empty-dtbo stub.
#
# LK merges dtbo_<slot> onto the DTB it takes from vendor_boot_<slot>. Our
# mainline DTB therefore cannot ship next to the stock overlay, and both the
# host flasher and the on-device deployer replace that slot's dtbo with a
# dt_table carrying zero entries. The header is written as a printf octal
# literal in each, so the invariant worth proving offline is that the two agree
# and that what they emit really is a zero-entry dt_table -- a wrong byte here
# is a device that boots to a blank screen with only fastboot to recover.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL="$HERE/../host/dc1-install.sh"
SYNC="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-boot-sync"

fail() { echo "dtbo-stub test failed: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Host side: dc1-install.sh writes the image `fastboot flash` sends.
DC1_INSTALL_LIB=1 . "$INSTALL" || fail "could not source dc1-install.sh"
write_dtbo_stub "$tmp/host.img"

# Device side: dc1-boot-sync emits the same bytes on stdout.
mkdir -p "$tmp/sys"
DC1_BOOT_SYNC_LIB=1 DC1_SYSBLOCK="$tmp/sys" . "$SYNC" || \
	fail "could not source dc1-boot-sync"
dtbo_stub > "$tmp/dev.img"

# The two literals must not drift apart.
cmp "$tmp/host.img" "$tmp/dev.img" || fail "host and device stubs differ"

# Parse it the way LK does rather than comparing to a golden blob. The entry
# count is the point of this test: a zero-entry table is not "no overlay" to
# this LK, it is `dtbo_entry_idx >= num_of_dtbo` -> load entry 0 of an empty
# table -> "load_dtbo fail" / "DT overlay fail", which did not boot on
# hardware. Exactly one entry, and it must be a real FDT with no fragments.
python3 - "$tmp/host.img" <<'PY' || fail "stub is not a one-entry no-op dt_table"
import struct, sys
d = open(sys.argv[1], 'rb').read()
magic, total, hdr, entsz, entcnt, entoff, pagesz, ver = struct.unpack('>8I', d[:32])
assert magic == 0xd7b7ab1e, f"magic {magic:#x}, want 0xd7b7ab1e"
assert entcnt == 1, f"dt_entry_count {entcnt}, want exactly 1 (0 is an LK error path)"
assert hdr == 32 and entoff == 32, f"header_size {hdr} dt_entries_offset {entoff}"
assert entsz == 32, f"dt_entry_size {entsz}"
assert pagesz == 2048, f"page_size {pagesz}"
assert ver == 0, f"version {ver}"
assert total == len(d), f"total_size {total} != image length {len(d)}"

size, off = struct.unpack('>2I', d[entoff:entoff + 8])
assert off + size <= len(d), f"entry runs past the image: off {off} size {size}"
fdt = d[off:off + size]
fmagic, fsize = struct.unpack('>2I', fdt[:8])
assert fmagic == 0xd00dfeed, f"entry is not an FDT: magic {fmagic:#x}"
assert fsize == size, f"FDT totalsize {fsize} != entry size {size}"
# No fragments and no fixups: applying it must be a no-op on any base tree.
for bad in (b'fragment', b'__overlay__', b'__fixups__', b'target'):
    assert bad not in fdt, f"overlay is not inert: contains {bad!r}"
PY

echo "dtbo stub tests passed"
