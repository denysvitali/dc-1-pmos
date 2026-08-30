#!/bin/sh
# Offline regression for the source-overlay collision guard. The refusal must
# happen before prepare.sh initializes/fetches a checkout or removes recipes.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
PREPARE="$REPO/scripts/prepare.sh"
DEVICE="$REPO/pmaports/device/testing/device-daylight-jagar/APKBUILD"

fail() { echo "prepare safety test failed: $*" >&2; exit 1; }

[ -f "$DEVICE" ] || fail "device overlay missing before test"
before=$(sha256sum "$DEVICE" | cut -d' ' -f1)
log=$(mktemp)
trap 'rm -f "$log"' EXIT

if "$PREPARE" "$REPO" >"$log" 2>&1; then
	fail "repository root was accepted as a work directory"
fi
grep -q 'source overlay' "$log" ||
	fail "collision refusal did not explain the source-overlay risk"
[ -f "$DEVICE" ] || fail "device overlay was removed"
after=$(sha256sum "$DEVICE" | cut -d' ' -f1)
[ "$after" = "$before" ] || fail "device overlay changed during refusal"

echo "prepare source-overlay collision test passed"
