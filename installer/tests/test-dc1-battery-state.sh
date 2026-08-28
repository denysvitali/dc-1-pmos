#!/bin/sh
# Offline tests for dc1-battery-state's clean-reboot persistence contract.
# No root, device, systemd or network required.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-battery-state"

fail() { echo "dc1-battery-state test failed: $*" >&2; exit 1; }
[ -r "$HELPER" ] || fail "missing helper: $HELPER"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fg=$tmp/fg
state=$tmp/var/battery-charge
mkdir -p "$fg" "$tmp/var"
printf '%s\n' 8000000 >"$fg/charge_full_design"
printf '%s\n' 6123456 >"$fg/charge_now"

run_helper() {
	DC1_BATTERY_STATE="$state" DC1_FG_DIR="$fg" DC1_NOW="$1" \
		DC1_MAX_AGE=600 sh "$HELPER" "$2"
}

echo "-- record and valid restore"
run_helper 1700000000 record
[ "$(cat "$state")" = "v1 1700000000 6123456" ] ||
	fail "record format/value mismatch"
printf '%s\n' 1000000 >"$fg/charge_now"
run_helper 1700000060 restore
[ "$(cat "$fg/charge_now")" = 6123456 ] || fail "valid state was not restored"
[ ! -e "$state" ] || fail "valid state was not consumed"

echo "-- ten-minute boundary"
printf '%s\n' 'v1 1700000000 5000000' >"$state"
printf '%s\n' 1000000 >"$fg/charge_now"
run_helper 1700000600 restore
[ "$(cat "$fg/charge_now")" = 5000000 ] || fail "MAX_AGE boundary was refused"
[ ! -e "$state" ] || fail "boundary state was not consumed"

echo "-- stale, future, corrupt and out-of-range records fail closed"
for scenario in stale future corrupt overfull trailing; do
	printf '%s\n' 2222222 >"$fg/charge_now"
	case $scenario in
	stale)    printf '%s\n' 'v1 1700000000 6000000' >"$state"; now=1700000601 ;;
	future)   printf '%s\n' 'v1 1700000100 6000000' >"$state"; now=1700000000 ;;
	corrupt)  printf '%s\n' 'v1 yesterday much' >"$state"; now=1700000000 ;;
	overfull) printf '%s\n' 'v1 1700000000 8000001' >"$state"; now=1700000001 ;;
	trailing) printf '%s\n' 'v1 1700000000 6000000 junk' >"$state"; now=1700000001 ;;
	esac
	run_helper "$now" restore
	[ "$(cat "$fg/charge_now")" = 2222222 ] ||
		fail "$scenario state changed the charge anchor"
	[ ! -e "$state" ] || fail "$scenario state was not consumed"
done

echo "-- invalid live values are not recorded"
printf '%s\n' 8000001 >"$fg/charge_now"
run_helper 1700000000 record
[ ! -e "$state" ] || fail "overfull live value was recorded"

echo "-- usage"
rc=0
sh "$HELPER" nope >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "bad action exited $rc, want 2"

echo "dc1-battery-state tests passed"
