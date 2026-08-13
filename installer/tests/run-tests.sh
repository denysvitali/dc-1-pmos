#!/bin/sh
# Run every offline installer test. No root, no device, no network.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
for t in "$HERE"/test-*.sh; do
	echo "==== $(basename "$t") ===="
	sh "$t" || rc=1
	echo
done
[ "$rc" -eq 0 ] && echo "ALL INSTALLER TESTS PASSED" || echo "INSTALLER TESTS FAILED"
exit "$rc"
