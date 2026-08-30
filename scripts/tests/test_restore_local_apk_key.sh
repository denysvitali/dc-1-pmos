#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESTORE="$HERE/../restore-local-apk-key.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "restore-local-apk-key test failed: $*" >&2; exit 1; }

# Cold cache: no derived directories are created.
mkdir "$TMP/cold"
sh "$RESTORE" "$TMP/cold" >/dev/null
[ ! -e "$TMP/cold/config_apk_keys" ] || fail "cold cache created a key directory"

# A restored abuild configuration without its public half is corrupt.
mkdir -p "$TMP/bad/config_abuild"
: >"$TMP/bad/config_abuild/abuild.conf"
if sh "$RESTORE" "$TMP/bad" >/dev/null 2>&1; then
	fail "accepted a restored abuild configuration with no public key"
fi

# The public half is copied byte-exact, made world-readable for apk, and does
# not remove official repository keys already in config_apk_keys.
mkdir -p "$TMP/good/config_abuild" "$TMP/good/config_apk_keys"
: >"$TMP/good/config_abuild/abuild.conf"
printf 'local public key\n' >"$TMP/good/config_abuild/pmos.rsa.pub"
printf 'official key\n' >"$TMP/good/config_apk_keys/alpine.rsa.pub"
sh "$RESTORE" "$TMP/good" >/dev/null
cmp -s "$TMP/good/config_abuild/pmos.rsa.pub" \
	"$TMP/good/config_apk_keys/pmos.rsa.pub" || fail "public key changed"
[ "$(stat -c '%a' "$TMP/good/config_apk_keys/pmos.rsa.pub")" = 644 ] ||
	fail "restored public key is not mode 0644"
[ -f "$TMP/good/config_apk_keys/alpine.rsa.pub" ] ||
	fail "existing official key was removed"

echo "restore-local-apk-key tests passed"
