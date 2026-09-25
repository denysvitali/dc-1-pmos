#!/bin/sh
# Fake-sysfs tests never call systemctl or touch device power state.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-sleep-on-blank"
python3 "$HERE/test-dc1-sleep-on-blank.py" "$HELPER"
