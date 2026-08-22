#!/bin/sh
# Offline tests for installer/src/netinstall.sh pure functions: SHA256SUMS
# parsing (fail closed on anything ambiguous) and HTTP Date parsing for the
# clock bootstrap.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

export DC1_PARTLIB="$HERE/../src/partlib.sh"
export DC1_WRITELIB="$HERE/../src/writelib.sh"
say() { :; }
fail() { echo "fail: $*" >&2; exit 99; }
DC1_LIB=1
. "$HERE/../src/netinstall.sh"

echo "== sums_digest =="

SHA_A=1111111111111111111111111111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222222222222222222222222222

cat > "$TMP/SUMS" <<EOF
$SHA_A  jagar-rootfs.ext4.zst
$SHA_B *jagar-boot.img
EOF

got=$(sums_digest "$TMP/SUMS" jagar-rootfs.ext4.zst) && [ "$got" = "$SHA_A" ] \
	&& ok "plain entry parsed" || bad "plain entry: got '$got'"
got=$(sums_digest "$TMP/SUMS" jagar-boot.img) && [ "$got" = "$SHA_B" ] \
	&& ok "binary-marker entry parsed" || bad "binary-marker entry: got '$got'"
sums_digest "$TMP/SUMS" not-there >/dev/null 2>&1 \
	&& bad "missing entry accepted" || ok "missing entry rejected"

cat > "$TMP/SUMS" <<EOF
$SHA_A  dup.img
$SHA_B  dup.img
EOF
sums_digest "$TMP/SUMS" dup.img >/dev/null 2>&1 \
	&& bad "duplicate entry accepted" || ok "duplicate entry rejected"

cat > "$TMP/SUMS" <<EOF
deadbeef  short.img
XYZ1111111111111111111111111111111111111111111111111111111111111111  bad.img
EOF
sums_digest "$TMP/SUMS" short.img >/dev/null 2>&1 \
	&& bad "short digest accepted" || ok "short digest rejected"
sums_digest "$TMP/SUMS" bad.img >/dev/null 2>&1 \
	&& bad "non-hex digest accepted" || ok "non-hex digest rejected"

echo "== http_date_to_datespec =="

got=$(http_date_to_datespec "Thu, 14 Aug 2026 05:31:58 GMT") \
	&& [ "$got" = "2026-08-14 05:31:58" ] \
	&& ok "RFC1123 date parsed" || bad "RFC1123 date: got '$got'"
got=$(http_date_to_datespec "Mon, 1 Jan 2029 00:00:00 GMT") \
	&& [ "$got" = "2029-01-01 00:00:00" ] \
	&& ok "single-digit day padded" || bad "single-digit day: got '$got'"
http_date_to_datespec "not a date at all" >/dev/null 2>&1 \
	&& bad "garbage date accepted" || ok "garbage date rejected"
http_date_to_datespec "Thu, 14 Aug 20261 05:31:58 GMT" >/dev/null 2>&1 \
	&& bad "5-digit year accepted" || ok "5-digit year rejected"
http_date_to_datespec "Thu, 14 Foo 2026 05:31:58 GMT" >/dev/null 2>&1 \
	&& bad "bad month accepted" || ok "bad month rejected"

echo "== assert_dtbswap =="

TMPDIR=$TMP
export TMPDIR

# Synthetic Android v4 image with a PLAIN gzip'd kernel: what a pre-dtbswap
# or regressed release would look like. Must refuse -- a plain image boots
# LK's signed stock tree, the dependency this check exists to prevent.
mkbootimg() { # OUT KERNEL_SLOT_BYTES
	python3 - "$1" "$2" <<'PY'
import struct, sys
img, kern = sys.argv[1], open(sys.argv[2], 'rb').read()
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(kern))
open(img, 'wb').write(hdr + b'\0' * (4096 - 1584) + kern)
PY
}
head -c 12345 /dev/zero | tr '\0' 'K' | gzip -c > "$TMP/plain.gz"
mkbootimg "$TMP/plain.img" "$TMP/plain.gz"
! (assert_dtbswap "$TMP/plain.img") 2>/dev/null \
	&& ok "plain (stock-DT) image refused" || bad "plain image accepted"

# A dtbswap payload: gzip([stub | dtb | kernel]), stub arm64 magic at 56,
# payload table at 0x40, FDT magic at the dtb offset. Must accept.
head -c 12345 /dev/zero | tr '\0' 'K' > "$TMP/raw"
want_sha=$(sha256sum "$TMP/raw" | cut -d' ' -f1)
python3 - "$TMP/dtbswap.img" "$TMP/raw" <<'PY'
import struct, sys, gzip
kern = open(sys.argv[2], 'rb').read()
stub = bytearray(5904)
stub[56:60] = b'ARM\x64'
dtb = b'\xd0\x0d\xfe\xed' + b'D' * 996
doff = len(stub); koff = doff + len(dtb)
struct.pack_into('<4I', stub, 0x40, doff, len(dtb), koff, len(kern))
gz = gzip.compress(bytes(stub) + dtb + kern)
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(gz))
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + gz)
PY
assert_dtbswap "$TMP/dtbswap.img" \
	&& ok "dtbswap payload accepted" || bad "dtbswap payload refused"

# Bogus kernel size in the header: refuse, never guess.
python3 - "$TMP/bogus.img" <<'PY'
import struct, sys
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, 0x7fffffff)
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + b'x' * 4096)
PY
! (assert_dtbswap "$TMP/bogus.img") 2>/dev/null \
	&& ok "implausible kernel size refused" || bad "implausible kernel size accepted"

# Kernel slot that does not decompress: refuse.
python3 - "$TMP/notgz.img" <<'PY'
import struct, sys
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, 100)
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + b'N' * 100)
PY
! (assert_dtbswap "$TMP/notgz.img") 2>/dev/null \
	&& ok "non-gzip kernel slot refused" || bad "non-gzip kernel slot accepted"

# A payload table whose kernel does not end exactly at the blob end: refuse
# (koff+klen == len is what makes the table self-consistent).
python3 - "$TMP/badtab.img" <<'PY'
import struct, sys, gzip
kern = open('/dev/null', 'rb').read()
stub = bytearray(5904)
stub[56:60] = b'ARM\x64'
dtb = b'\xd0\x0d\xfe\xed' + b'D' * 996
doff = len(stub); koff = doff + len(dtb)
struct.pack_into('<4I', stub, 0x40, doff, len(dtb), koff, 1)  # klen lies
gz = gzip.compress(bytes(stub) + dtb + kern)
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(gz))
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + gz)
PY
! (assert_dtbswap "$TMP/badtab.img") 2>/dev/null \
	&& ok "inconsistent payload table refused" || bad "inconsistent payload table accepted"

echo
echo "test-netinstall: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
