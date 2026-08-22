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
# zero-padded to 4096, then the gzip'd kernel. Since the dtbswap switch,
# kernel_sha compares UNCOMPRESSED kernels, so the expected hash is the raw
# Image's, not the gzip's -- proving it reads the size from the header, the
# bytes from offset 4096, and gunzips them (the layout repack-boot.sh writes).
raw="$tmp/kernel.raw"
head -c 12345 /dev/zero | tr '\0' 'K' > "$raw"
want=$(sha256sum "$raw" | cut -d' ' -f1)
gzip -c "$raw" > "$tmp/kernel.gz"
python3 - "$tmp/synth.img" "$tmp/kernel.gz" <<'PY'
import struct, sys
kern = open(sys.argv[2], 'rb').read()
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(kern))
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + kern)
PY
got=$(kernel_sha "$tmp/synth.img") || fail "kernel_sha failed on a plain image"
[ "$got" = "$want" ] || fail "plain kernel_sha = $got, want $want"

# A dtbswap payload: gzip([stub | dtb | kernel]) with the payload table at
# 0x40 and the FDT magic at the dtb offset. kernel_sha must unwrap it and
# hash ONLY the inner kernel -- the raw Image again, same hash as above.
python3 - "$tmp/dtbswap.img" "$raw" <<'PY'
import struct, sys, gzip
kern = open(sys.argv[2], 'rb').read()
stub = bytearray(5904)
stub[56:60] = b'ARM\x64'
dtb = b'\xd0\x0d\xfe\xed' + b'D' * 996        # FDT magic + filler
doff = len(stub); koff = doff + len(dtb)
struct.pack_into('<4I', stub, 0x40, doff, len(dtb), koff, len(kern))
blob = bytes(stub) + dtb + kern
gz = gzip.compress(blob)
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(gz))
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + gz)
PY
got=$(kernel_sha "$tmp/dtbswap.img") || fail "kernel_sha failed on a dtbswap image"
[ "$got" = "$want" ] || fail "dtbswap kernel_sha = $got, want $want (inner kernel not unwrapped)"

# A plain kernel whose bytes HAPPEN to be valid at 0x40 must not be misread
# as a payload: the FDT-magic-at-doff check is the discriminator. Kernel of
# 'K's has u32s of 0x4b4b4b4b at 0x40 -- doff far beyond the blob, od reads
# nothing, and kernel_sha must fall back to whole-blob hashing (== $want).
# (Covered by the plain-image case above; this comment records the reasoning.)

# A bogus kernel_size must refuse, not hand back a garbage hash.
python3 - "$tmp/bogus.img" <<'PY'
import struct, sys
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, 0x7fffffff)
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + b'x' * 4096)
PY
! kernel_sha "$tmp/bogus.img" >/dev/null 2>&1 || fail "kernel_sha accepted an implausible kernel size"

# Content that is not gzip at all must refuse (old images were compared as
# gzip bytes; the uncompressed comparison must not silently hash garbage).
python3 - "$tmp/notgz.img" <<'PY'
import struct, sys
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, 100)
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + b'N' * 100)
PY
! kernel_sha "$tmp/notgz.img" >/dev/null 2>&1 || fail "kernel_sha accepted a non-gzip kernel slot"

echo "-- dtbswap refusal (deploy must never flash a stock-DT image)"

# Same synthetic images the kernel_sha section built. The dtbswap payload
# must pass; the plain image and the bogus-size one must fail -- a plain
# image would boot LK's signed stock tree, which deploy() must never flash.
export TMPDIR="$tmp"
is_dtbswap_img "$tmp/dtbswap.img" || fail "is_dtbswap_img refused a dtbswap payload"
is_dtbswap_img "$tmp/synth.img" 2>/dev/null && fail "is_dtbswap_img accepted a plain image" || :
is_dtbswap_img "$tmp/notgz.img" 2>/dev/null && fail "is_dtbswap_img accepted a non-gzip slot" || :

# deploy()-level guard exercised through the same function the installer
# uses structurally; the layout facts are asserted once, here and in
# test-netinstall.sh.

echo "boot-sync resolver + kernel extraction tests passed"
