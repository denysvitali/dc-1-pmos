#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$HERE/test-dc1-charging-settings.py"
