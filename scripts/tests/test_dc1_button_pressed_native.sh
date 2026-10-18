#!/bin/sh
# Optional live-library regression test; it creates no windows on the owner desktop.
set -eu
[ "$#" -eq 0 ] || exit 2
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=$(mktemp -d "${TMPDIR:-/tmp}/dc1-button-native.XXXXXX")
trap 'rm -rf -- "$runtime"' EXIT
env -u DISPLAY -u WAYLAND_DISPLAY \
	DC1_BUTTON_NATIVE_TEST=1 \
	XDG_RUNTIME_DIR="$runtime" XDG_CONFIG_HOME="$runtime" \
	GSETTINGS_BACKEND=keyfile \
	GI_TYPELIB_PATH="/usr/lib/mutter-16:/usr/lib/gnome-shell${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}" \
	LD_LIBRARY_PATH="/usr/lib/mutter-16:/usr/lib/gnome-shell${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	dbus-run-session -- gjs -m "$directory/test_dc1_button_pressed_native.js"
