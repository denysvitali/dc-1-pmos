#!/bin/sh
# Offline tests for dc1-boot-sync's fail-closed boot-slot resolution. The
# script's destructive path (download, dd, arm, reboot) is not exercised here;
# the part worth proving offline is that resolve_boot refuses a moved or
# ambiguous GPT mapping rather than pointing dd at a boot-critical partition.
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

echo "boot-sync resolver tests passed"
