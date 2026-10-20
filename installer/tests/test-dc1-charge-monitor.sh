#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/test-dc1-charge-monitor.py"
