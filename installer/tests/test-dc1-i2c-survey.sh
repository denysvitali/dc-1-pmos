#!/bin/sh
# Offline checks for tools/i2c-survey/dc1-i2c-survey.sh: the dry-run command
# list must stay read-only. No root, no device access.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SURVEY="$HERE/../../tools/i2c-survey/dc1-i2c-survey.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

sh "$SURVEY" --dry-run battery >"$TMP/plain" || fail "dry run failed"
sh "$SURVEY" --dry-run --mn29-pointer-select charging >"$TMP/pointer" ||
	fail "dry run with pointer select failed"
grep '^\$ ' "$TMP/plain" >"$TMP/plain.cmds" || fail "no commands printed"
grep '^\$ ' "$TMP/pointer" >"$TMP/pointer.cmds" || fail "no commands printed"

# No setter tools, no SMBus quick-write probes, no line requests.
for cmds in "$TMP/plain.cmds" "$TMP/pointer.cmds"; do
	if grep -E 'i2cset|gpioget|gpioset|gpiomon|i2cdump|/sys/bus/i2c/.*(bind|new_device)' "$cmds"; then
		fail "mutating command in $cmds"
	fi
	grep 'i2cdetect' "$cmds" | grep -v -- ' -r ' && fail "i2cdetect without -r"
	grep -E 'i2cdetect.* -q' "$cmds" && fail "i2cdetect quick-write mode"
	# RT9471 IRQ flags (0x20-0x23, clear-on-read) and vendor space (0x40+).
	grep -E 'i2cget -y 7 0x53 0x([2-9a-f][0-9a-f])$' "$cmds" &&
		fail "RT9471 register outside 0x00-0x12"
	# The pack gauge only gets plain register reads.
	grep -E 'i2ctransfer -y 7 ' "$cmds" && fail "raw transfer to i2c7"
	:
done

# Without the flag, 0x49 gets current-address reads only.
grep -E 'i2ctransfer|@0x49| 1 0x49' "$TMP/plain.cmds" && fail "0x49 write without opt-in"
# With it, exactly one pointer-select of 0x00 and a bounded read.
[ "$(grep -c 'i2ctransfer' "$TMP/pointer.cmds")" -eq 1 ] ||
	fail "expected one i2ctransfer"
grep -qx '\$ i2ctransfer -y 1 w1@0x49 0x00 r16@0x49' "$TMP/pointer.cmds" ||
	fail "unexpected 0x49 pointer select"

# Argument validation.
sh "$SURVEY" --dry-run >/dev/null 2>&1 && fail "accepted missing label"
sh "$SURVEY" --dry-run 'a/b' >/dev/null 2>&1 && fail "accepted path-like label"
sh "$SURVEY" --dry-run --bogus x >/dev/null 2>&1 && fail "accepted unknown option"
if [ "$(id -u)" -ne 0 ]; then
	sh "$SURVEY" battery >/dev/null 2>&1 && fail "ran hardware path without root"
fi

echo "PASS: dc1-i2c-survey dry run is read-only"
