#!/bin/sh
# Compile and test the complete backlight mirror against fake sysfs only.
# Discovered by run-tests.sh's test-*.sh loop; no service or hardware access.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEVDIR="$HERE/../../pmaports/device/testing/device-daylight-jagar"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
${CC:-cc} -std=c99 -O2 -Wall -Wextra -Werror \
	-o "$tmp/dc1-screen-backlight" "$DEVDIR/dc1-screen-backlight.c"
python3 "$HERE/test-dc1-screen-backlight.py" "$tmp/dc1-screen-backlight"
