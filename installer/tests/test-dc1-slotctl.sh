#!/bin/sh
# Exercise dc1-slotctl offline: compile the real C tool (not a mock) and drive
# it against a known-good bootloader_control block and a fake misc device.
#
# The block is the one the Go bootctl package already pins as a decoder test
# (internal/bootctl/bootctl_test.go realBlock): suffix "_a", magic BCAB,
# version 1, nb_slot 2, slot a pri15/ok1, slot b pri14/ok1, crc32 over the
# first 28 bytes. slotctl must accept it, reject bad-magic and bad-crc
# variants, and enforce the active-slot and proven-fallback guards on mutation.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
devdir="$here/../../pmaports/device/testing/device-daylight-jagar"
slotctl_src="$devdir/dc1-slotctl.c"
misc_src="$devdir/dc1-misc.c"

[ -f "$slotctl_src" ] || { echo "SKIP: $slotctl_src missing"; exit 0; }
[ -f "$misc_src" ] || { echo "SKIP: $misc_src missing"; exit 0; }
command -v gcc >/dev/null 2>&1 || { echo "SKIP: no gcc"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

fail() { echo "dc1-slotctl test failed: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gcc -Wall -Wextra -O2 -o "$tmp/dc1-slotctl" "$slotctl_src" "$misc_src" \
	|| fail "compile"

tool="$tmp/dc1-slotctl"

# The pinned real block (a=pri15/ok1, b=pri14/ok1), as 64 hex chars.
GOOD=5f61000042434142010200008f008e000000000000000000000000001b0c9745

# validate-hex: positive control and two refusals.
"$tool" validate-hex "$GOOD" >/dev/null \
	|| fail "validate-hex rejected the known-good block"
"$tool" validate-hex "$GOOD" | grep -q 'active=a' \
	|| fail "validate-hex did not report active=a"
! "$tool" validate-hex 5f610000deadbeef010200008f008e0000000000000000000000000000000000 \
	>/dev/null 2>&1 || fail "validate-hex accepted a bad-magic block"
! "$tool" validate-hex 5f61000042434142010200008f008e0000000000000000000000000000000000 \
	>/dev/null 2>&1 || fail "validate-hex accepted a bad-crc block"

# Build a fake misc device with the real block at byte 2048.
python3 - "$tmp/fake-misc" <<'PY'
import sys
b = bytes.fromhex("5f61000042434142010200008f008e000000000000000000000000001b0c9745")
open(sys.argv[1], "wb").write(bytearray(2048) + b)
PY
M="--misc $tmp/fake-misc"

# status: active slot is a (priority 15 > 14).
"$tool" status $M | grep -q 'active=a' || fail "status did not report active=a"

# arm the INACTIVE slot b: succeeds, b becomes pri15/tries1/ok0.
"$tool" arm b --tries 1 $M >/dev/null || fail "arm b (inactive) was refused"
"$tool" status $M | grep -q 'active=b' || fail "after arm b, active did not become b"

# arm the now-active slot b: refused.
! "$tool" arm b $M >/dev/null 2>&1 || fail "arm b (active) was not refused"

# mark-successful the wrong (inactive) slot a: refused.
! "$tool" mark-successful a $M >/dev/null 2>&1 \
	|| fail "mark-successful a (inactive) was not refused"

# mark-successful the running slot b: succeeds, tries clears to 0.
"$tool" mark-successful b $M >/dev/null || fail "mark-successful b was refused"
"$tool" status $M | grep -q 'slot b: pri=15 tries=0 ok=1' \
	|| fail "mark-successful b did not settle slot b to pri15/ok1"

# prefer the now-inactive slot a: priority-only, no successful_boot cleared.
"$tool" prefer a $M >/dev/null || fail "prefer a (inactive) was refused"
"$tool" status $M | grep -q 'slot a: pri=15' || fail "prefer a did not raise a to pri15"
"$tool" status $M | grep -q 'slot a: pri=15 tries=0 ok=1' \
	|| fail "prefer a cleared successful_boot (it must not)"

# dry-run writes nothing.
before=$(dd if="$tmp/fake-misc" bs=1 skip=2048 count=32 2>/dev/null | sha256sum | cut -d' ' -f1)
"$tool" prefer b -n $M >/dev/null || fail "dry-run prefer b failed"
after=$(dd if="$tmp/fake-misc" bs=1 skip=2048 count=32 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$before" = "$after" ] || fail "dry-run wrote the block"

echo "dc1-slotctl tests passed"
