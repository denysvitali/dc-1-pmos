#!/bin/sh
# Run every offline installer test. No root, no device, no network.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
# Syntax gate first: a typo in any installer script fails fast here.
for s in "$HERE"/../build.sh "$HERE"/../src/*.sh "$HERE"/../src/*.script \
         "$HERE"/../src/system/*.sh "$HERE"/../host/*.sh "$HERE"/*.sh; do
	sh -n "$s" || { echo "SYNTAX ERROR: $s"; exit 1; }
done
for t in "$HERE"/test-*.sh; do
	echo "==== $(basename "$t") ===="
	sh "$t" || rc=1
	echo
done
[ "$rc" -eq 0 ] && echo "ALL INSTALLER TESTS PASSED" || echo "INSTALLER TESTS FAILED"
exit "$rc"
