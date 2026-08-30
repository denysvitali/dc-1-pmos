#!/bin/sh
# Recreate pmbootstrap's derived local-repository trust key after cache restore.
#
# pmbootstrap stores the abuild private/public pair in config_abuild, but copies
# the public half into config_apk_keys only in the same branch that generates a
# new key. Restoring config_abuild therefore skips key generation and leaves a
# fresh rootfs unable to verify the cached local APK repository unless we
# recreate that public-key copy first.
set -eu

[ "$#" -eq 1 ] || {
	echo "usage: $0 PMBOOTSTRAP_WORK_DIR" >&2
	exit 2
}
work=$1
abuild_dir="$work/config_abuild"
apk_keys_dir="$work/config_apk_keys"

fail() { echo "local apk key restore failed: $*" >&2; exit 1; }

# A cold cache has no abuild.conf; pmbootstrap will generate the keypair and
# populate config_apk_keys itself during the first package build.
[ -f "$abuild_dir/abuild.conf" ] || {
	echo "no restored abuild configuration; pmbootstrap will generate keys"
	exit 0
}

set -- "$abuild_dir"/*.pub
[ -f "$1" ] || fail "restored config_abuild has no public key"

mkdir -p "$apk_keys_dir"
for key in "$@"; do
	[ -f "$key" ] || fail "unexpected public-key path: $key"
	cp "$key" "$apk_keys_dir/${key##*/}"
	chmod 0644 "$apk_keys_dir/${key##*/}"
	echo "restored local APK trust key: ${key##*/}"
done
