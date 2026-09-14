#!/bin/sh
# An upgrade must clear the MC3416 bring-up debug drop-in, because it floods
# the journal with two LOG_DEBUG lines per accelerometer sample. It must
# clear exactly that file and nothing else: an edited drop-in, a sibling
# drop-in, or a symlink is left alone, and systemd is only touched on a live
# system where a real removal happened.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
DEV="$REPO/pmaports/device/testing/device-daylight-jagar"
HELPER="$DEV/dc1-retire-iio-debug"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "retire-iio-debug test failed: $*" >&2; exit 1; }

[ -r "$HELPER" ] || fail "missing $HELPER"
sh -n "$HELPER" || fail "syntax error in dc1-retire-iio-debug"

DIR="$TMP/etc/systemd/system/iio-sensor-proxy.service.d"
DROP="$DIR/debug.conf"
BAD='[Service]
Environment=G_MESSAGES_DEBUG=all
'

mkdir -p "$TMP/bin"
cat >"$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$DC1_RETIRE_ROOT/calls"
STUB
chmod +x "$TMP/bin/systemctl"

# plant: write $1 as the drop-in body. run: invoke the helper with $TMP as
# the root. reset: drop the drop-in tree and the recorded systemctl calls.
plant() { mkdir -p "$DIR"; printf '%s' "$1" >"$DROP"; }
run() { DC1_RETIRE_ROOT="$TMP" PATH="$TMP/bin:$PATH" sh "$HELPER"; }
reset() { rm -rf "$TMP/etc" "$TMP/calls"; }

echo "-- a package build without PID 1 removes the file, not systemd"
reset
plant "$BAD"
run
test ! -e "$DROP" || fail "known-bad drop-in survived"
test ! -d "$DIR" || fail "emptied drop-in directory survived"
test ! -e "$TMP/calls" || fail "systemctl ran without a systemd runtime"

echo "-- a live upgrade reloads before restarting, and only after a removal"
reset
mkdir -p "$TMP/run/systemd/system"
plant "$BAD"
run
printf '%s\n' 'daemon-reload' 'try-restart iio-sensor-proxy.service' >"$TMP/expected"
cmp "$TMP/expected" "$TMP/calls" || fail "wrong systemctl sequence"
# The file is gone now, so a second upgrade must not churn the service.
run
cmp "$TMP/expected" "$TMP/calls" || fail "a no-op upgrade still restarted systemd units"

echo "-- an edited, commented, or differently-valued drop-in is left alone"
for body in '[Service]
Environment=G_MESSAGES_DEBUG=all
Environment=FOO=bar
' '[Service]
#Environment=G_MESSAGES_DEBUG=all
' '[Service]
Environment=G_MESSAGES_DEBUG=proxy
'; do
	reset
	plant "$body"
	run
	test -f "$DROP" || fail "an edited drop-in was removed"
	test ! -e "$TMP/calls" || fail "an edited drop-in triggered systemd"
done

echo "-- a differently-named drop-in in the same directory is untouched"
reset
plant "$BAD"
printf '%s\n' '[Service]' 'Environment=OTHER=1' >"$DIR/other.conf"
run
test ! -e "$DROP" || fail "known-bad drop-in survived next to a sibling"
test -d "$DIR" || fail "drop-in directory was removed while a sibling remained"
test -f "$DIR/other.conf" || fail "sibling drop-in was removed"

echo "-- a symlink is neither followed nor deleted"
reset
mkdir -p "$DIR"
real=$TMP/real.conf
printf '%s' "$BAD" >"$real"
ln -s "$real" "$DROP"
run
test -L "$DROP" || fail "symlinked drop-in was removed"
test -f "$real" || fail "symlink target was removed"

echo "-- an absent drop-in is a clean no-op"
reset
run
test ! -e "$DIR" || fail "an absent drop-in created its directory"
test ! -e "$TMP/calls" || fail "a no-op run touched systemd"

# The helper is only useful if the upgrade hook actually calls it.
PATH=/bin:/usr/bin sh -c 'grep -q dc1-retire-iio-debug "$1"' _ \
	"$DEV/device-daylight-jagar.post-upgrade" ||
	fail "post-upgrade no longer calls the retire helper"

echo 'retire-iio-debug tests passed'
