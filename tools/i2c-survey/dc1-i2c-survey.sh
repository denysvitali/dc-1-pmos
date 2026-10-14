#!/bin/sh
# Read-only survey of the DC-1's open I2C parts: RT9471 (i2c7 0x53), the
# BQ78Z100 pack gauge (i2c7 0x55) and the unidentified ALS/PS part (i2c1
# 0x49). See README.md for the operations issued and how to read results.
set -eu

usage() {
	cat <<'EOF'
Usage: dc1-i2c-survey.sh [--dry-run] [--mn29-pointer-select] LABEL

Run once on battery (LABEL=battery) and once with a charger attached
(LABEL=charging). Requires root unless --dry-run is given.

  --dry-run              print the I2C/GPIO commands without running them
  --mn29-pointer-select  also send one register-select byte (0x00) to 0x49
                         and read 16 bytes; this is a write transaction
EOF
}

dry_run=0
mn29_pointer=0
label=
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=1 ;;
		--mn29-pointer-select) mn29_pointer=1 ;;
		-h|--help) usage; exit 0 ;;
		-*) usage >&2; exit 2 ;;
		*)
			[ -z "$label" ] || { usage >&2; exit 2; }
			label=$1
			;;
	esac
	shift
done
[ -n "$label" ] || { usage >&2; exit 2; }
case "$label" in
	*[!A-Za-z0-9_-]*) echo "LABEL must be [A-Za-z0-9_-]" >&2; exit 2 ;;
esac

if [ "$dry_run" -eq 0 ]; then
	[ "$(id -u)" -eq 0 ] || { echo "run as root (or use --dry-run)" >&2; exit 1; }
	for tool in i2cget i2cdetect i2ctransfer gpioinfo; do
		command -v "$tool" >/dev/null 2>&1 || {
			echo "missing $tool (i2c-tools/libgpiod)" >&2; exit 1; }
	done
fi

# Every hardware access goes through run(); --dry-run prints it instead.
run() {
	printf '$ %s\n' "$*"
	[ "$dry_run" -eq 1 ] && return 0
	"$@" 2>&1 || printf '(exit %s)\n' "$?"
}

section() { printf '\n== %s ==\n' "$1"; }

sysfs() {
	for f in "$@"; do
		if [ -r "$f" ]; then
			printf '%s=%s\n' "$f" "$(cat "$f" 2>/dev/null || echo '?')"
		else
			printf '%s=(unreadable)\n' "$f"
		fi
	done
}

section "context ($label)"
date -u +%Y-%m-%dT%H:%M:%SZ
uname -r
apk info -v 2>/dev/null | grep -E '^(device-daylight-jagar|linux-postmarketos-mediatek-mt6789)-[0-9]' || true
ps=/sys/class/power_supply
sysfs "$ps/mt6358-fg/status" "$ps/mt6358-fg/capacity" \
	"$ps/mt6358-fg/voltage_now" "$ps/mt6358-fg/current_now" \
	"$ps/mt6375-charger/online" "$ps/mt6375-charger/status" \
	"$ps/mt6375-charger/input_current_limit" \
	"$ps/mt6375-charger/constant_charge_current" \
	/sys/class/typec/port0/power_role /sys/class/typec/port0/data_role
ls -d /sys/bus/i2c/devices/7-0053/driver /sys/bus/i2c/devices/7-0055 2>&1 || true

# RT9471 CE is active-low on GPIO151. Read the pad state only: gpioget
# requests the line as an input and would release a driven CE.
section "rt9471 enable pin (GPIO151)"
if [ "$dry_run" -eq 1 ]; then
	printf '$ grep -H GPIO151 /sys/kernel/debug/pinctrl/*/pins\n'
else
	grep -HE 'GPIO151([^0-9]|$)' /sys/kernel/debug/pinctrl/*/pins 2>&1 ||
		echo "(debugfs pins unavailable)"
fi
# gpioinfo (libgpiod v2) only queries line info; it does not request it.
run gpioinfo -c gpiochip0 151

# RT9471 registers per drivers/power/supply/rt9471.c; 0x0b bits 6:3 hold the
# device ID (0x68 = RT9471, 0x70 = RT9471D). 0x20-0x23 are the
# IRQ flag registers (treated as clear-on-read) and 0x40+ are vendor/test
# space; neither is touched.
section "rt9471 i2c7 0x53"
for reg in 0x0b 0x00 0x01 0x02 0x03 0x04 0x05 0x07 0x08 0x0a 0x0c 0x0e 0x0f 0x10 0x11 0x12; do
	run i2cget -y 7 0x53 "$reg"
done

# -r forces read-byte probes; never use -q (SMBus quick write).
section "pack gauge scan"
run i2cdetect -y -r 7
for bus in 0 1 2 5 6 8 9; do
	run i2cdetect -y -r "$bus" 0x0b 0x0b
	run i2cdetect -y -r "$bus" 0x55 0x55
done

# Standard bq27xxx-style word reads; only attempted on i2c7 0x55. A
# missing device makes each one fail with an error, which is the result.
section "pack gauge i2c7 0x55 reads"
for reg in 0x08 0x06 0x0a 0x2c 0x12 0x3c; do
	run i2cget -y 7 0x55 "$reg" w
done

section "als/ps i2c1 0x49 current-address reads"
run dc1-mn29-probe --samples 512 --interval-ms 0
run dc1-mn29-probe --samples 512 --interval-ms 0
if [ "$mn29_pointer" -eq 1 ]; then
	section "als/ps i2c1 0x49 pointer-select 0x00 + 16-byte read"
	run i2ctransfer -y 1 w1@0x49 0x00 r16@0x49
fi

section "done"
echo "Keep this report out of Git; review it before sharing."
