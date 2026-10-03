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
cat >"$TMP/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DC1_TEST_SYSTEMCTL_LOG"
case $1 in
enable) [ -f "$DC1_TEST_VAR_DIR/enable-auto-suspend" ] || exit 2 ;;
stop) [ ! -e "$DC1_TEST_VAR_DIR/enable-auto-suspend" ] || exit 2 ;;
*) exit 2 ;;
esac
[ ! -e "$DC1_TEST_SYSTEMCTL_FAIL" ]
EOF
chmod +x "$TMP/systemctl"
export DC1_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log"
export DC1_TEST_SYSTEMCTL_FAIL="$TMP/systemctl.fail"
export DC1_TEST_VAR_DIR="$TMP/var"

DC1_OWNER_SETTINGS_LIB=1 \
DC1_OWNER_VAR_DIR="$TMP/var" \
DC1_OWNER_CHARGE_CURRENT="$TMP/constant_charge_current" \
DC1_OWNER_SYSTEMCTL="$TMP/systemctl" \
	. "$HELPER"

status_value() {
	cmd_status | awk -F= -v key="$1" '$1 == key { print $2; exit }'
}

echo "-- status maps opt-out markers to positive UI states"
[ "$(status_value charge_current)" = 3150000 ] || fail "wrong charge current"
[ "$(status_value charging_mode)" = on ] || fail "charging mode default is not on"
[ "$(status_value auto_update)" = on ] || fail "auto-update default is not on"
[ "$(status_value auto_suspend)" = off ] || fail "automatic sleep must be opt-in"

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

echo "-- automatic sleep applies the marker and service together without reboot"
set_auto_suspend on
[ "$(status_value auto_suspend)" = on ] || fail "automatic sleep opt-in missing"
set_auto_suspend on
[ "$(tail -n 1 "$TMP/systemctl.log")" = 'enable --now dc1-sleep-on-blank.service' ] ||
	fail "automatic sleep did not enable/start its conditional unit"
set_auto_suspend off
[ "$(status_value auto_suspend)" = off ] || fail "automatic sleep opt-in not removed"
set_auto_suspend off
[ "$(tail -n 1 "$TMP/systemctl.log")" = 'stop dc1-sleep-on-blank.service' ] ||
	fail "automatic sleep did not stop its helper"

echo "-- failed service start rolls back a new opt-in, preserving an existing choice"
touch "$TMP/systemctl.fail"
! set_auto_suspend on >/dev/null 2>&1 || fail "failed start reported success"
[ "$(status_value auto_suspend)" = off ] || fail "failed start left a new opt-in"
touch "$TMP/var/enable-auto-suspend"
! set_auto_suspend on >/dev/null 2>&1 || fail "failed repeat start reported success"
[ "$(status_value auto_suspend)" = on ] || fail "failed start removed the prior choice"
! set_auto_suspend off >/dev/null 2>&1 || fail "failed stop reported success"
[ "$(status_value auto_suspend)" = off ] || fail "failed stop retained sleep authorization"
rm "$TMP/systemctl.fail"

echo "-- unknown commands and states fail closed"
! set_feature suspend on >/dev/null 2>&1 || fail "unknown feature accepted"
! set_feature auto-update maybe >/dev/null 2>&1 || fail "unknown state accepted"
before=$(cat "$TMP/systemctl.log")
! set_auto_suspend maybe >/dev/null 2>&1 || fail "unknown automatic sleep state accepted"
[ "$(status_value auto_suspend)" = off ] || fail "invalid state changed the marker"
[ "$(cat "$TMP/systemctl.log")" = "$before" ] || fail "invalid state controlled a service"

echo "dc1-owner-settings tests passed"
