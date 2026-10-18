#!/bin/sh
# Exercise upgrade cleanup without root, real services, or device access.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEV=$HERE/../../pmaports/device/testing/device-daylight-jagar
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DC1_RETIRE_ROOT/calls"
if [ "$1" = stop ]; then
	test ! -e "$DC1_RETIRE_ROOT/still-active" || exit 1
	rm -f "$DC1_RETIRE_ROOT/running"
fi
if [ "$1" = is-active ]; then
	test -e "$DC1_RETIRE_ROOT/running" || test -e "$DC1_RETIRE_ROOT/still-active"
fi
STUB
chmod +x "$TMP/bin/systemctl"

plant() {
	mkdir -p "$TMP/usr/lib/systemd/system" "$TMP/usr/libexec" \
		"$TMP/etc/init.d" "$TMP/etc/runlevels/default" \
		"$TMP/etc/systemd/system/multi-user.target.wants"
	for f in usr/lib/systemd/system/dc1-debug-shell.service \
		usr/libexec/dc1-debug-shell etc/init.d/dc1-debug-shell; do
		printf 'old debug artifact\n' > "$TMP/$f"
	done
	ln -sf /dev/null "$TMP/etc/systemd/system/dc1-debug-shell.service"
	ln -sf /usr/lib/systemd/system/dc1-debug-shell.service \
		"$TMP/etc/systemd/system/multi-user.target.wants/dc1-debug-shell.service"
	ln -sf /etc/init.d/dc1-debug-shell "$TMP/etc/runlevels/default/dc1-debug-shell"
	printf 'keep USB networking\n' > "$TMP/usr/libexec/dc1-usb-gadget"
}
run() { DC1_RETIRE_ROOT="$TMP" PATH="$TMP/bin:$PATH" sh "$DEV/dc1-retire-debug-shell"; }
assert_removed() {
	for f in usr/lib/systemd/system/dc1-debug-shell.service \
		usr/libexec/dc1-debug-shell etc/init.d/dc1-debug-shell \
		etc/runlevels/default/dc1-debug-shell \
		etc/systemd/system/multi-user.target.wants/dc1-debug-shell.service \
		etc/systemd/system/dc1-debug-shell.service; do
		test ! -e "$TMP/$f" && test ! -L "$TMP/$f"
	done
	test "$(cat "$TMP/usr/libexec/dc1-usb-gadget")" = 'keep USB networking'
}

# Offline roots remove files/links without invoking the host's init system.
plant
run
assert_removed
test ! -e "$TMP/calls"

# Live upgrades must stop the cached unit even when apk removed its definition.
plant
mkdir -p "$TMP/run/systemd/system"
rm "$TMP/usr/lib/systemd/system/dc1-debug-shell.service"
touch "$TMP/running"
run
assert_removed
test ! -e "$TMP/running"
run
printf '%s\n' 'stop dc1-debug-shell.service' \
	'is-active --quiet dc1-debug-shell.service' 'disable dc1-debug-shell.service' 'daemon-reload' \
	'reset-failed dc1-debug-shell.service' > "$TMP/expected"
cat "$TMP/expected" "$TMP/expected" > "$TMP/expected-twice"
cmp "$TMP/expected-twice" "$TMP/calls"

# Failed shutdown must not silently remove a still-running unit's definition.
plant
touch "$TMP/still-active"
if run; then echo 'accepted a still-running debug service' >&2; exit 1; fi
test -f "$TMP/usr/lib/systemd/system/dc1-debug-shell.service"
rm "$TMP/still-active"
run
assert_removed

# Administrator-owned replacement units are not the retired vendor service.
printf '[Service]\nExecStart=/usr/bin/true\n' > "$TMP/etc/systemd/system/dc1-debug-shell.service"
run
test -f "$TMP/etc/systemd/system/dc1-debug-shell.service"

# Shipped normal/charging startup must never restore the retired channels.
for f in dc1-debug-shell dc1-debug-shell.service dc1-debug-shell.initd; do
	test ! -e "$DEV/$f"
done
! grep -q 'enable dc1-debug-shell' "$DEV/80-device-daylight-jagar.preset"
! grep -q 'rc-update add dc1-debug-shell' "$DEV/device-daylight-jagar.post-install" \
	"$DEV/device-daylight-jagar.post-upgrade"
! grep '^Wants=' "$DEV/dc1-charging.target" | grep -Eq 'debug-shell|usb-gadget|unudhcpd'
echo 'debug-shell retirement tests passed'
