#!/bin/sh
# Offline tests for dc1-gpu-freq: snapping, persist, apply defaults, and
# the min/max ordering that the kernel rejects if inverted. No root, no
# GPU, no polkit -- the helper honours DC1_GPUFREQ_SYSFS / DC1_GPUFREQ_CONF.
#
# HARNESS NOTE: interactive shells in some development environments wrap
# grep; every assertion therefore runs in a clean subprocess via
# PATH=/bin:/usr/bin sh -c '...'.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DEVDIR="$HERE/../../pmaports/device/testing/device-daylight-jagar"
HELPER="$DEVDIR/dc1-gpu-freq"

fail() { echo "dc1-gpu-freq test failed: $*" >&2; exit 1; }

[ -r "$HELPER" ] || fail "missing $HELPER"
sh -n "$HELPER" || fail "syntax error in dc1-gpu-freq"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

OPPS='390000000 467000000 545000000 622000000 700000000 812000000 1100000000'

mksysfs() {
	sysfs=$tmp/gpu
	mkdir -p "$sysfs"
	printf '%s\n' "$OPPS" >"$sysfs/available_frequencies"
	printf '%s\n' 390000000 >"$sysfs/min_freq"
	printf '%s\n' 1100000000 >"$sysfs/max_freq"
	printf '%s\n' 390000000 >"$sysfs/cur_freq"
	printf '%s\n' 50 >"$sysfs/polling_interval"
	printf '%s\n' simple_ondemand >"$sysfs/governor"
	conf=$tmp/gpu-freq.conf
	rm -f "$conf"
}

run() {
	# $1... = helper args. Uses the mock sysfs/conf in $tmp.
	DC1_GPUFREQ_SYSFS=$tmp/gpu DC1_GPUFREQ_CONF=$tmp/gpu-freq.conf \
		PATH=/bin:/usr/bin "$HELPER" "$@"
}

expect_file() { # $1=path $2=expected
	got=$(tr -d '\n\r' <"$1")
	[ "$got" = "$2" ] || fail "$1: got $got want $2"
}

expect_status() { # $1=key $2=expected
	got=$(DC1_GPUFREQ_SYSFS=$tmp/gpu DC1_GPUFREQ_CONF=$tmp/gpu-freq.conf \
		PATH=/bin:/usr/bin "$HELPER" status | PATH=/bin:/usr/bin awk -F= -v k="$1" '$1==k{print $2; exit}')
	[ "$got" = "$2" ] || fail "status $1: got '$got' want '$2'"
}

echo "-- apply uses Smooth defaults when no conf exists"
mksysfs
run apply
expect_file "$tmp/gpu/min_freq" 812000000
expect_file "$tmp/gpu/max_freq" 1100000000
expect_file "$tmp/gpu/polling_interval" 20
[ -f "$tmp/gpu-freq.conf" ] || fail "apply did not write conf"
expect_status min_freq 812000000
expect_status default_min_freq 812000000

echo "-- apply restores the persisted experiment"
mksysfs
printf 'MIN_FREQ=545000000\nMAX_FREQ=812000000\n' >"$tmp/gpu-freq.conf"
run apply
expect_file "$tmp/gpu/min_freq" 545000000
expect_file "$tmp/gpu/max_freq" 812000000

echo "-- set-min snaps to the nearest OPP and raises max if needed"
mksysfs
run apply >/dev/null
run set-min 680000000
expect_file "$tmp/gpu/min_freq" 700000000
run set-min 1100000000
expect_file "$tmp/gpu/min_freq" 1100000000
expect_file "$tmp/gpu/max_freq" 1100000000

echo "-- set-max snaps down and lowers min if needed"
mksysfs
run apply >/dev/null
run set-max 850000000
expect_file "$tmp/gpu/max_freq" 812000000
run set-max 390000000
expect_file "$tmp/gpu/min_freq" 390000000
expect_file "$tmp/gpu/max_freq" 390000000

echo "-- set writes both and persists"
mksysfs
run set 545000000 700000000
expect_file "$tmp/gpu/min_freq" 545000000
expect_file "$tmp/gpu/max_freq" 700000000
expect_status min_freq 545000000
PATH=/bin:/usr/bin sh -c 'grep -q "^MIN_FREQ=545000000$" "$1"' _ "$tmp/gpu-freq.conf" \
	|| fail "conf missing MIN_FREQ"
PATH=/bin:/usr/bin sh -c 'grep -q "^MAX_FREQ=700000000$" "$1"' _ "$tmp/gpu-freq.conf" \
	|| fail "conf missing MAX_FREQ"

echo "-- reset returns to Smooth defaults"
run reset
expect_file "$tmp/gpu/min_freq" 812000000
expect_file "$tmp/gpu/max_freq" 1100000000

echo "-- polling_interval EACCES does not fail a min/max set"
mksysfs
run apply >/dev/null
chmod a-w "$tmp/gpu/polling_interval"
run set-min 545000000
expect_file "$tmp/gpu/min_freq" 545000000
chmod u+w "$tmp/gpu/polling_interval"

echo "-- session persist works when conf is writable but confdir is not"
mksysfs
run apply >/dev/null
confdir=$tmp/nowrite
mkdir -p "$confdir"
printf 'MIN_FREQ=812000000\nMAX_FREQ=1100000000\n' >"$confdir/gpu-freq.conf"
chmod 0664 "$confdir/gpu-freq.conf"
chmod a-w "$confdir"
DC1_GPUFREQ_SYSFS=$tmp/gpu DC1_GPUFREQ_CONF=$confdir/gpu-freq.conf \
	PATH=/bin:/usr/bin "$HELPER" set-min 545000000
expect_file "$tmp/gpu/min_freq" 545000000
PATH=/bin:/usr/bin sh -c 'grep -q "^MIN_FREQ=545000000$" "$1"' _ "$confdir/gpu-freq.conf" \
	|| fail "in-place persist did not update MIN_FREQ"
chmod u+w "$confdir"

echo "-- apply is a no-op (exit 0) when the GPU is absent"
rm -rf "$tmp/gpu"
DC1_GPUFREQ_SYSFS=$tmp/missing DC1_GPUFREQ_CONF=$tmp/gpu-freq.conf \
	PATH=/bin:/usr/bin "$HELPER" apply
echo "-- garbage input is rejected"
mksysfs
if run set-min no 2>/dev/null; then
	fail "set-min accepted non-numeric"
fi
if run set 1 2>/dev/null; then
	fail "set accepted a missing max"
fi

echo "dc1-gpu-freq tests passed"
