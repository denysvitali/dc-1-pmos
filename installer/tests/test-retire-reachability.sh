#!/bin/sh
# Existing boot images must be neutralized before their service can reboot.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
DEV="$REPO/pmaports/device/testing/device-daylight-jagar"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
# Both timers must be disarmed before touching the running service.
test -f "$DC1_RETIRE_ROOT/etc/dc1/boot-watchdog.disabled" || exit 91
test -f "$DC1_RETIRE_ROOT/var/lib/dc1/boot-ok" || exit 92
printf '%s\n' "$*" >> "$DC1_RETIRE_ROOT/calls"
STUB
chmod +x "$TMP/bin/systemctl"
# A package build without PID 1 still installs both migration markers.
DC1_RETIRE_ROOT="$TMP" PATH="$TMP/bin:$PATH" sh "$DEV/dc1-retire-reachability"
test -f "$TMP/etc/dc1/boot-watchdog.disabled"
test -f "$TMP/var/lib/dc1/boot-ok"
test ! -e "$TMP/calls"
# Live upgrade stops and disables the legacy unit; repeated calls are safe.
mkdir -p "$TMP/run/systemd/system"
for attempt in 1 2; do
 DC1_RETIRE_ROOT="$TMP" PATH="$TMP/bin:$PATH" sh "$DEV/dc1-retire-reachability"
done
printf '%s\n' 'daemon-reload' 'disable --now dc1-boot-watchdog.service' \
 'daemon-reload' 'disable --now dc1-boot-watchdog.service' > "$TMP/expected"
cmp "$TMP/expected" "$TMP/calls"
# The condition blocks old units redeployed by an old initramfs. tmpfiles
# provides both markers during sysinit, including boots to charging.target.
grep -qx 'ConditionPathExists=!/etc/dc1/boot-watchdog.disabled' "$DEV/90-retired-reachability.conf"
grep -q '^f /etc/dc1/boot-watchdog.disabled ' "$DEV/dc1-retired-watchdog.conf"
grep -q '^f /var/lib/dc1/boot-ok ' "$DEV/dc1-retired-watchdog.conf"
# New images must contain neither reachability timer nor deployed watchdog.
test ! -e "$REPO/installer/src/system/boot-watchdog.sh"
test ! -e "$REPO/installer/src/system/dc1-boot-watchdog.service"
! grep -qE 'start_reachability_deadman|REACH_DEADLINE_SEC|reach-armed' "$REPO/installer/src/system/init.c"
! grep -q 'etc/deploy/dc1-boot-watchdog' "$REPO/installer/build.sh"
echo 'reachability retirement tests passed'
