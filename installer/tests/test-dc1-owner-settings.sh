#!/bin/sh
# Offline tests for the strictly allowlisted Charging Profile backend.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-owner-settings"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "dc1-owner-settings test failed: $*" >&2; exit 1; }

mkdir -p "$TMP/var"
printf '3150000\n' >"$TMP/constant_charge_current"

DC1_OWNER_SETTINGS_LIB=1 \
DC1_OWNER_VAR_DIR="$TMP/var" \
DC1_OWNER_CHARGE_CURRENT="$TMP/constant_charge_current" \
	. "$HELPER"

status_value() {
	cmd_status | awk -F= -v key="$1" '$1 == key { print $2; exit }'
}

echo "-- status maps opt-out markers to positive UI states"
[ "$(status_value charge_current)" = 3150000 ] || fail "wrong charge current"
[ "$(status_value charging_mode)" = on ] || fail "charging mode default is not on"
[ "$(status_value auto_update)" = on ] || fail "auto-update default is not on"

echo "-- exact charge-current allowlist and readback"
set_charge_current 2000000
[ "$(cat "$TMP/constant_charge_current")" = 2000000 ] || fail "2 A write failed"
set_charge_current 3150000
[ "$(cat "$TMP/constant_charge_current")" = 3150000 ] || fail "3.15 A write failed"
! set_charge_current 3150001 >/dev/null 2>&1 || fail "out-of-policy current accepted"
! set_charge_current '3150000;reboot' >/dev/null 2>&1 || fail "non-numeric current accepted"

echo "-- marker mutations are idempotent and leave no staging files"
set_feature charging-mode off
[ -f "$TMP/var/no-charging-mode" ] || fail "charging-mode opt-out missing"
[ "$(status_value charging_mode)" = off ] || fail "charging-mode status did not change"
set_feature charging-mode off
set_feature charging-mode on
[ ! -e "$TMP/var/no-charging-mode" ] || fail "charging-mode opt-out not removed"

set_feature auto-update off
[ -f "$TMP/var/no-auto-update" ] || fail "auto-update opt-out missing"
[ "$(status_value auto_update)" = off ] || fail "auto-update status did not change"
set_feature auto-update on
[ ! -e "$TMP/var/no-auto-update" ] || fail "auto-update opt-out not removed"
[ -z "$(find "$TMP/var" -name '.*.tmp.*' -print -quit)" ] ||
	fail "temporary marker file was left behind"

echo "-- unknown commands and states fail closed"
! set_feature suspend on >/dev/null 2>&1 || fail "unknown feature accepted"
! set_feature auto-update maybe >/dev/null 2>&1 || fail "unknown state accepted"

echo "dc1-owner-settings tests passed"
