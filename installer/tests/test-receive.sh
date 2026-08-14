#!/bin/sh
# Offline tests for installer/src/receive.sh library functions: header
# parsing and, most importantly, the fail-closed userdata partition
# resolution -- exercised against a fake sysfs tree.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

# 32 GiB in 512-byte sectors is the minimum; userdata is ~109 GiB.
BIG=228589568         # ~109 GiB
SMALL=131072          # 64 MiB -- the size class of boot/dtbo/misc

mkpart() {
	# mkpart NAME DEVNAME SECTORS
	mkdir -p "$TMP/sys/$2"
	printf 'DEVNAME=%s\nPARTNAME=%s\n' "$2" "$1" > "$TMP/sys/$2/uevent"
	echo "$3" > "$TMP/sys/$2/size"
}

export DC1_SYSBLOCK="$TMP/sys"
export DC1_STATUS_FILE="$TMP/status"
export DC1_PARTLIB="$HERE/../src/partlib.sh"
export DC1_WRITELIB="$HERE/../src/writelib.sh"
DC1_LIB=1
. "$HERE/../src/receive.sh"

echo "== resolve_userdata =="

rm -rf "$TMP/sys"
mkpart boot_a sdc26 "$SMALL"
mkpart boot_b sdc48 "$SMALL"
mkpart userdata sdc57 "$BIG"
SYSBLOCK="$DC1_SYSBLOCK"
dev=$(resolve_userdata) && [ "$dev" = "/dev/sdc57" ] \
	&& ok "resolves userdata by PARTNAME" || bad "resolve returned '$dev'"

rm -rf "$TMP/sys"
mkpart boot_a sdc26 "$SMALL"
resolve_userdata >/dev/null 2>&1 && bad "resolved with no userdata" \
	|| ok "fails with no userdata partition"

rm -rf "$TMP/sys"
mkpart userdata sdc57 "$BIG"
mkpart userdata sdd3 "$BIG"
resolve_userdata >/dev/null 2>&1 && bad "resolved ambiguous userdata" \
	|| ok "fails when userdata is ambiguous"

rm -rf "$TMP/sys"
mkpart userdata sdc57 "$SMALL"
resolve_userdata >/dev/null 2>&1 && bad "resolved undersized userdata" \
	|| ok "fails when userdata is suspiciously small (mapping moved)"

rm -rf "$TMP/sys"
mkdir -p "$TMP/sys/sdc57"
printf 'DEVNAME=sdc57\nPARTNAME=userdata_old\n' > "$TMP/sys/sdc57/uevent"
echo "$BIG" > "$TMP/sys/sdc57/size"
resolve_userdata >/dev/null 2>&1 && bad "matched PARTNAME prefix" \
	|| ok "requires exact PARTNAME match"

echo "== read_header =="

good_header() {
	printf 'DC1-INSTALL-V1\nsize=%s\nsha256=%s\nanswers=%s\n\n' \
		"104857600" \
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
		"QQo="
}

if good_header | { read_header && [ "$hdr_size" = 104857600 ] && \
	[ "$hdr_answers" = "QQo=" ]; }; then
	ok "parses a valid header"
else
	bad "valid header rejected"
fi

if printf 'NOT-THE-MAGIC\n\n' | read_header 2>/dev/null; then
	bad "bad magic accepted"
else
	ok "bad magic rejected"
fi

if printf 'DC1-INSTALL-V1\nsize=abc\nsha256=%s\nanswers=QQo=\n\n' \
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
	| read_header 2>/dev/null; then
	bad "non-numeric size accepted"
else
	ok "non-numeric size rejected"
fi

if printf 'DC1-INSTALL-V1\nsize=104857600\nsha256=beef\nanswers=QQo=\n\n' \
	| read_header 2>/dev/null; then
	bad "short sha256 accepted"
else
	ok "short sha256 rejected"
fi

if printf 'DC1-INSTALL-V1\nsize=1024\nsha256=%s\nanswers=QQo=\n\n' \
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
	| read_header 2>/dev/null; then
	bad "tiny size accepted"
else
	ok "tiny (non-image) size rejected"
fi

if printf 'DC1-INSTALL-V1\nsize=104857600\nsha256=%s\nanswers=QQo=\nrm -rf /=1\n\n' \
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
	| read_header 2>/dev/null; then
	bad "unknown header line accepted"
else
	ok "unknown header line rejected"
fi

echo
echo "test-receive: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
