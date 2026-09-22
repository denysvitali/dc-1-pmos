#!/bin/sh
# Offline role-switch and ramdisk-size regressions; never touch real sysfs.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$here/test-usb-docking.py"
