#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# pkg-config flags are intentionally split into compiler arguments.
# shellcheck disable=SC2046
${CC:-cc} -Wall -Wextra -Werror $(pkg-config --cflags libdrm) \
    -o "$tmp/test" "$HERE/test-dc1-charging-display.c" $(pkg-config --libs libdrm)
"$tmp/test"
