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

echo
echo "test-netinstall: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
