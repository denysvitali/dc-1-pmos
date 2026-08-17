#!/bin/sh
# Offline tests for dc1-boot-sync's fail-closed boot-slot resolution and
# kernel extraction. The destructive path (download, dd, arm, reboot) is not
# exercised here; the parts worth proving offline are that resolve_boot refuses
# a moved or ambiguous GPT mapping rather than pointing dd at a boot-critical
# partition, and that kernel_sha reads the gzip'd kernel out of an Android v4
# boot image (kernel_size at offset 8, kernel at offset 4096).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-boot-sync"

fail() { echo "boot-sync test failed: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sys"

mkpart() { # name partname sectors
	mkdir -p "$tmp/sys/$1"
	printf 'MAJOR=8\nPARTNAME=%s\n' "$2" > "$tmp/sys/$1/uevent"
	printf '%s\n' "$3" > "$tmp/sys/$1/size"
}

# Source just the resolver, no side effects.
DC1_BOOT_SYNC_LIB=1 DC1_SYSBLOCK="$tmp/sys" . "$SRC" || fail "could not source"

# boot partitions are 64 MiB = 131072 sectors; the window is 8 MiB..1 GiB.
mkpart sdc26 boot_a 131072
mkpart sdc48 boot_b 131072
mkpart sdc57 userdata 228589568

out=$(resolve_boot a) || fail "resolve_boot a refused a valid boot_a"
[ "$out" = "/dev/sdc26" ] || fail "resolve_boot a = $out, want /dev/sdc26"
out=$(resolve_boot b) || fail "resolve_boot b refused a valid boot_b"
[ "$out" = "/dev/sdc48" ] || fail "resolve_boot b = $out, want /dev/sdc48"

# Refuse an ambiguous mapping.
mkpart sdd1 boot_a 131072
! resolve_boot a >/dev/null 2>&1 || fail "resolve_boot a accepted two boot_a partitions"

# Refuse a mapping whose size is outside the window (moved GPT).
rm -rf "$tmp/sys/sdd1"
printf '131072\n' > "$tmp/sys/sdc48/size"
printf '99999999\n' > "$tmp/sys/sdc26/size"
! resolve_boot a >/dev/null 2>&1 || fail "resolve_boot a accepted an oversized boot_a"
printf '100\n' > "$tmp/sys/sdc26/size"
! resolve_boot a >/dev/null 2>&1 || fail "resolve_boot a accepted an undersized boot_a"

echo "-- kernel extraction (Android v4 header)"

# A synthetic boot image: 1584-byte header (kernel_size u32 at offset 8),
# zero-padded to 4096, then the gzip'd kernel. kernel_sha must return exactly
# the kernel's SHA-256, proving it reads the size from the header and the bytes
# from offset 4096 -- the layout boot/repack-boot.sh writes.
kern="$tmp/kernel.gz"
head -c 12345 /dev/zero | tr '\0' 'K' > "$kern"
want=$(sha256sum "$kern" | cut -d' ' -f1)
python3 - "$tmp/synth.img" "$kern" <<'PY'
import struct, sys
kern = open(sys.argv[2], 'rb').read()
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(kern))
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + kern)
PY
got=$(kernel_sha "$tmp/synth.img") || fail "kernel_sha failed on a valid image"
[ "$got" = "$want" ] || fail "kernel_sha = $got, want $want"

# A bogus kernel_size must refuse, not hand back a garbage hash.
python3 - "$tmp/bogus.img" <<'PY'
import struct, sys
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, 0x7fffffff)
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + b'x' * 4096)
PY
! kernel_sha "$tmp/bogus.img" >/dev/null 2>&1 || fail "kernel_sha accepted an implausible kernel size"

echo "-- dtbo resolution + stub"

# dtbo partitions are 8 MiB = 16384 sectors; the window is 8 MiB..64 MiB.
mkpart sdc29 dtbo_a 16384
mkpart sdc54 dtbo_b 16384

out=$(resolve_dtbo a) || fail "resolve_dtbo a refused a valid dtbo_a"
[ "$out" = "/dev/sdc29" ] || fail "resolve_dtbo a = $out, want /dev/sdc29"
out=$(resolve_dtbo b) || fail "resolve_dtbo b refused a valid dtbo_b"
[ "$out" = "/dev/sdc54" ] || fail "resolve_dtbo b = $out, want /dev/sdc54"

# Fail closed on an ambiguous mapping, exactly like resolve_boot.
mkpart sdd2 dtbo_a 16384
! resolve_dtbo a >/dev/null 2>&1 || fail "resolve_dtbo a accepted two dtbo_a partitions"
rm -rf "$tmp/sys/sdd2"

# Fail closed outside the window. A 64 MiB node is a boot/vendor_boot slot,
# not a dtbo -- writing the stub there would destroy a boot image.
printf '131073\n' > "$tmp/sys/sdc29/size"
! resolve_dtbo a >/dev/null 2>&1 || fail "resolve_dtbo a accepted an oversized dtbo_a"
printf '100\n' > "$tmp/sys/sdc29/size"
! resolve_dtbo a >/dev/null 2>&1 || fail "resolve_dtbo a accepted an undersized dtbo_a"

# The stub must be a dt_table LK reads as "no overlays": magic d7b7ab1e and
# dt_entry_count 0. Parsed the same way LK does rather than compared byte-wise,
# so a hand-edit of the octal string cannot silently ship a bad header.
dtbo_stub > "$tmp/stub.img"
[ "$(wc -c < "$tmp/stub.img" | tr -d ' ')" = 32 ] || fail "dtbo_stub is not 32 bytes"
python3 - "$tmp/stub.img" <<'PY' || exit 1
import struct, sys
d = open(sys.argv[1], 'rb').read()
magic, total, hdr, entsz, entcnt, entoff, pagesz, ver = struct.unpack('>8I', d[:32])
assert magic == 0xd7b7ab1e, f"magic {magic:#x}"
assert entcnt == 0, f"dt_entry_count {entcnt}, want 0"
assert total == 32 and hdr == 32 and entoff == 32, (total, hdr, entoff)
assert entsz == 32 and pagesz == 2048 and ver == 0, (entsz, pagesz, ver)
PY

# neutralize_dtbo must refuse a target that is not already a dt_table, so a
# resolver that somehow returned the wrong node is never written to.
mkpart sdc29 dtbo_a 16384
head -c 4096 /dev/zero > "$tmp/notdtbo.img"
DC1_SYSBLOCK="$tmp/sys"
! (resolve_dtbo() { echo "$tmp/notdtbo.img"; }; neutralize_dtbo a) >/dev/null 2>&1 \
	|| fail "neutralize_dtbo overwrote a target with no dt_table magic"

# On a real dt_table it rewrites the header in place and verifies the readback.
cp "$tmp/stub.img" "$tmp/real.img"
head -c 4064 /dev/zero >> "$tmp/real.img"
printf 'STALE-ENTRY-TABLE' | dd of="$tmp/real.img" bs=1 seek=32 conv=notrunc 2>/dev/null
(resolve_dtbo() { echo "$tmp/real.img"; }; neutralize_dtbo a) >/dev/null 2>&1 \
	|| fail "neutralize_dtbo refused a valid dt_table"
cmp -n 32 "$tmp/real.img" "$tmp/stub.img" || fail "neutralize_dtbo did not write the stub header"
[ -z "$(dd if="$tmp/real.img" bs=1 skip=32 count=32 2>/dev/null | tr -d '\0')" ] \
	|| fail "neutralize_dtbo left the old entry table behind"

echo "boot-sync resolver + kernel extraction + dtbo tests passed"
