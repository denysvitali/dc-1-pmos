#!/bin/sh
# Offline tests for dc1-reboot-fastboot (the source lives with the device
# package; the installer compiles the same file into both initramfses).
#
# Everything is faked through the tool's documented test hooks: DC1_SYSBLOCK
# for the sysfs walk, DC1_DEVDIR for /dev, DC1_MEMDEV + DC1_MEMBASE for the
# watchdog register. No root, no device, no /dev/mem.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-reboot-fastboot.c"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

CC=${CC:-cc}
BIN="$TMP/dc1-reboot-fastboot"
# -D_FORTIFY_SOURCE=2 on purpose: Ubuntu's gcc turns it on by default and its
# snprintf checks are stricter than the plain build, so CI would otherwise be
# the first place a truncation warning shows up.
"$CC" -Os -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 -o "$BIN" "$SRC" \
	|| { echo "  FAIL: compile"; exit 1; }
ok "compiles clean with -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2"

# A fake /sys/class/block. mkpart <name> <partname> <sectors>
mkpart() {
	mkdir -p "$TMP/sys/$1"
	printf 'MAJOR=8\nDEVNAME=%s\nPARTNAME=%s\n' "$1" "$2" > "$TMP/sys/$1/uevent"
	printf '%s\n' "$3" > "$TMP/sys/$1/size"
	: > "$TMP/dev/$1"
}
mkdir -p "$TMP/sys" "$TMP/dev"

# A fake misc: 1 MiB (2048 sectors), and a page of fake registers. The nibble
# lives at offset 0x24 of the mapping, so DC1_MEMBASE=0 keeps mmap happy on a
# regular file.
mkpart sdc1 misc 2048
mkpart sdc57 userdata 228589568
head -c 65536 /dev/zero > "$TMP/dev/sdc1"
head -c 4096 /dev/zero > "$TMP/mem"

export DC1_SYSBLOCK="$TMP/sys" DC1_DEVDIR="$TMP/dev"
export DC1_MEMDEV="$TMP/mem" DC1_MEMBASE=0

# Read the boot mode nibble out of the fake register page.
nibble() {
	od -An -tx1 -j 36 -N 1 "$TMP/mem" | tr -d ' \n'
}
# Write a BCB command into the fake misc.
arm_bcb() {
	head -c 64 /dev/zero > "$TMP/bcb"
	printf '%s' "$1" | dd of="$TMP/bcb" bs=1 conv=notrunc 2>/dev/null
	dd if="$TMP/bcb" of="$TMP/dev/sdc1" bs=64 count=1 conv=notrunc 2>/dev/null
}

echo "-- resolution and dry run"
out=$("$BIN" --dry-run 2>&1) || bad "dry run exited non-zero: $out"
case "$out" in
	*"misc = $TMP/dev/sdc1"*) ok "resolves PARTNAME=misc, not userdata" ;;
	*) bad "did not resolve misc: $out" ;;
esac
[ "$(nibble)" = "00" ] && ok "dry run left the register alone" \
	|| bad "dry run wrote the register"

echo "-- fail closed on a suspicious mapping"
# Resolution failing is not fatal (the nibble is still worth writing), but the
# tool must refuse to name -- let alone write -- the wrong block device.
printf '%s\n' 228589568 > "$TMP/sys/sdc1/size"
out=$("$BIN" --dry-run 2>&1)
case "$out" in
	*"refusing (mapping moved?)"*) ok "refuses an oversized misc" ;;
	*) bad "wrong diagnostic for oversized misc: $out" ;;
esac
case "$out" in
	*"misc = "*) bad "named a device it had just refused" ;;
	*) ok "does not fall back to a device it refused" ;;
esac
printf '%s\n' 2048 > "$TMP/sys/sdc1/size"

mkpart sdd1 misc 2048
out=$("$BIN" --dry-run 2>&1)
case "$out" in
	*"expected exactly 1 PARTNAME=misc, found 2"*) ok "refuses an ambiguous misc" ;;
	*) bad "wrong diagnostic for duplicate misc: $out" ;;
esac
case "$out" in
	*"misc = "*) bad "picked one of two candidates" ;;
	*) ok "does not guess between two candidates" ;;
esac
rm -rf "$TMP/sys/sdd1"

echo "-- arming"
"$BIN" --no-reboot > "$TMP/out" 2>&1 || bad "arming exited non-zero"
[ "$(nibble)" = "03" ] && ok "sets the boot mode nibble to 3 (fastboot)" \
	|| bad "nibble is $(nibble), expected 03"
grep -q "nibble 3 = fastboot" "$TMP/out" && ok "reports the armed value" \
	|| bad "no confirmation line: $(cat "$TMP/out")"

# The high bits of the register are not ours to touch. (Octal escapes rather
# than xxd: one less thing that has to exist on the runner.)
printf '\245\245\245\000' | dd of="$TMP/mem" bs=1 seek=36 conv=notrunc 2>/dev/null
"$BIN" --no-reboot > /dev/null 2>&1 || bad "arming over a dirty register failed"
[ "$(od -An -tx1 -j 36 -N 4 "$TMP/mem" | tr -d ' \n')" = "a3a5a500" ] \
	&& ok "preserves the other bits of WDT_NONRST_REG2" \
	|| bad "clobbered the register: $(od -An -tx1 -j 36 -N 4 "$TMP/mem")"
head -c 4096 /dev/zero > "$TMP/mem"

echo "-- the BCB is disarmed, never armed"
arm_bcb boot-fastboot
"$BIN" --no-reboot > "$TMP/out" 2>&1 || bad "arming with a stale BCB failed"
[ "$(od -An -c -N 13 "$TMP/dev/sdc1" | tr -d ' \n' | tr -d '\\0')" = "" ] \
	&& ok "clears a stale boot-fastboot BCB" \
	|| bad "BCB survived: $(od -An -c -N 16 "$TMP/dev/sdc1")"
grep -q "cleared the armed BCB" "$TMP/out" && ok "says so" || bad "silent clear"

arm_bcb boot-recovery
"$BIN" --dry-run > "$TMP/out" 2>&1 || bad "dry run with an armed BCB failed"
grep -q "would clear it" "$TMP/out" && ok "dry run reports an armed BCB" \
	|| bad "dry run missed the armed BCB: $(cat "$TMP/out")"
[ "$(dd if="$TMP/dev/sdc1" bs=13 count=1 2>/dev/null)" = "boot-recovery" ] \
	&& ok "dry run did not touch the BCB" || bad "dry run wrote the BCB"

# A command LK does not match is none of our business.
arm_bcb bootonce-bootloader
"$BIN" --no-reboot > /dev/null 2>&1 || bad "arming with a foreign BCB failed"
[ "$(dd if="$TMP/dev/sdc1" bs=19 count=1 2>/dev/null)" = "bootonce-bootloader" ] \
	&& ok "leaves a command LK ignores alone" || bad "cleared a foreign BCB"

# Nothing in this tool may ever write a BCB command.
if grep -nE '(strncpy|strcpy|memcpy|snprintf).*boot-(fastboot|recovery)' "$SRC"; then
	bad "source copies a BCB command string somewhere"
else
	ok "source never writes a BCB command, only compares and clears"
fi

echo "-- misc that cannot be inspected is a warning, not a stop"
out=$(DC1_SYSBLOCK="$TMP/empty" "$BIN" --no-reboot 2>&1) \
	|| bad "aborted when misc could not be resolved"
case "$out" in
	*"WARNING: could not check the BCB"*) ok "warns and continues" ;;
	*) bad "no warning: $out" ;;
esac
[ "$(nibble)" = "03" ] && ok "still armed the nibble" || bad "did not arm"

echo
echo "test-reboot-fastboot: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
