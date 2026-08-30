#!/bin/sh
# Refuse to replace an APK's bytes without changing its pkgver-pkgrel filename.
set -eu

[ "$#" -eq 2 ] || {
	echo "usage: $0 CANDIDATE_DIR EXISTING_SHA256SUMS_OR_URL" >&2
	exit 2
}
candidate_dir=$1
existing_source=$2

fail() { echo "release identity check failed: $*" >&2; exit 1; }
[ -d "$candidate_dir" ] || fail "candidate directory missing: $candidate_dir"

old_sums=$(mktemp)
trap 'rm -f "$old_sums"' EXIT HUP INT TERM
case $existing_source in
	http://*|https://*|file://*)
		curl -fsSL "$existing_source" >"$old_sums" ||
			fail "cannot fetch existing manifest: $existing_source"
		;;
	*) [ -f "$existing_source" ] || fail "existing manifest missing: $existing_source"
		cp "$existing_source" "$old_sums" ;;
esac

for apk in "$candidate_dir"/*.apk; do
	[ -f "$apk" ] || fail "candidate contains no APKs"
	name=${apk##*/}
	old=$(awk -v wanted="$name" '
		{ file=$2; sub(/^\*/, "", file); if (file == wanted) print $1 }
	' "$old_sums")
	[ -n "$old" ] || continue
	new=$(sha256sum "$apk" | cut -d' ' -f1)
	[ "$new" = "$old" ] || fail \
		"$name changed ($old -> $new) without a pkgver-pkgrel bump"
	echo "unchanged version kept byte identity: $name"
done

echo "cross-release APK identity passed"
