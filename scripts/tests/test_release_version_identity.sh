#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/../check-release-version-identity.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/candidate"

printf old >"$TMP/candidate/linux-test-1-r1.apk"
(cd "$TMP/candidate" && sha256sum linux-test-1-r1.apk) >"$TMP/old-sums"
sh "$CHECK" "$TMP/candidate" "$TMP/old-sums" >/dev/null

printf changed >"$TMP/candidate/linux-test-1-r1.apk"
if sh "$CHECK" "$TMP/candidate" "$TMP/old-sums" >/dev/null 2>&1; then
	echo "same-version drift was accepted" >&2
	exit 1
fi

mv "$TMP/candidate/linux-test-1-r1.apk" "$TMP/candidate/linux-test-1-r2.apk"
sh "$CHECK" "$TMP/candidate" "$TMP/old-sums" >/dev/null

echo "release version identity tests passed"
