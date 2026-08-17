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

# Host side: dc1-install.sh writes a 4096-byte file for `fastboot flash`.
DC1_INSTALL_LIB=1 . "$INSTALL" || fail "could not source dc1-install.sh"
write_dtbo_stub "$tmp/host.img"
[ "$(wc -c < "$tmp/host.img" | tr -d ' ')" = 4096 ] || \
	fail "write_dtbo_stub is not 4096 bytes"

# Device side: dc1-boot-sync emits the bare 32-byte header on stdout.
mkdir -p "$tmp/sys"
DC1_BOOT_SYNC_LIB=1 DC1_SYSBLOCK="$tmp/sys" . "$SYNC" || \
	fail "could not source dc1-boot-sync"
dtbo_stub > "$tmp/dev.img"
[ "$(wc -c < "$tmp/dev.img" | tr -d ' ')" = 32 ] || fail "dtbo_stub is not 32 bytes"

# The two literals must not drift apart.
cmp -n 32 "$tmp/host.img" "$tmp/dev.img" || \
	fail "host and device stubs disagree in the first 32 bytes"

# Everything past the header must be zero: it lands on the old entry table.
[ -z "$(dd if="$tmp/host.img" bs=1 skip=32 2>/dev/null | tr -d '\0')" ] || \
	fail "write_dtbo_stub padding is not zeroed"

# Parse it the way LK does rather than comparing to a golden blob.
python3 - "$tmp/host.img" <<'PY' || fail "stub is not a zero-entry dt_table"
import struct, sys
d = open(sys.argv[1], 'rb').read()
magic, total, hdr, entsz, entcnt, entoff, pagesz, ver = struct.unpack('>8I', d[:32])
assert magic == 0xd7b7ab1e, f"magic {magic:#x}, want 0xd7b7ab1e"
assert entcnt == 0, f"dt_entry_count {entcnt}, want 0 (LK must find no overlay)"
assert total == 32, f"total_size {total}, want 32"
assert hdr == 32 and entoff == 32, f"header_size {hdr} dt_entries_offset {entoff}"
assert entsz == 32, f"dt_entry_size {entsz}"
assert pagesz == 2048, f"page_size {pagesz}"
assert ver == 0, f"version {ver}"
PY

echo "dtbo stub tests passed"
