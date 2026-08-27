#!/bin/sh
# Prefetch the kernel GitHub archive into a distfiles directory and prove its
# sha512 before abuild sees it. GitHub /archive tarballs have landed at full
# size with a bad hash (CI 2026-08-27, twice); abuild then renames the file
# and exits with "Use 'abuild checksum'" instead of retrying the download.
set -eu

usage() {
	echo "usage: $0 DEST_DIR" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
dest_dir=$1
[ -d "$dest_dir" ] || {
	echo "not a directory: $dest_dir" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
apkbuild=${DC1_KERNEL_APKBUILD:-"$script_dir/../pmaports/device/testing/linux-postmarketos-mediatek-mt6789/APKBUILD"}
[ -f "$apkbuild" ] || {
	echo "missing $apkbuild" >&2
	exit 1
}

curl_cmd=${DC1_CURL:-curl}
retries=${DC1_PREFETCH_RETRIES:-5}
case "$retries" in
	''|*[!0-9]*|0) echo "DC1_PREFETCH_RETRIES must be a positive integer" >&2; exit 1 ;;
esac

command -v sha512sum >/dev/null || {
	echo "missing required tool: sha512sum" >&2
	exit 1
}

# Source APKBUILD only to expand source=/sha512sums=. Top-level is assignments.
startdir=$(CDPATH= cd -- "$(dirname -- "$apkbuild")" && pwd)
srcdir="$startdir/src"
# shellcheck disable=SC1091
. "$apkbuild"

set -- $source
[ "$#" -eq 1 ] || {
	echo "expected exactly one kernel distfile, got $#" >&2
	exit 1
}
src=$1
name=${src%%::*}
name=${name##*/}
case "$src" in
	*::*) url=${src#*::} ;;
	*) url=$src ;;
esac
[ -n "$name" ] && [ -n "$url" ] || {
	echo "could not parse kernel source" >&2
	exit 1
}

set -- $sha512sums
[ "$#" -eq 2 ] || {
	echo "expected one kernel checksum pair, got $#" >&2
	exit 1
}
hash=$1
file=$2
[ "$file" = "$name" ] || {
	echo "checksum filename '$file' != '$name'" >&2
	exit 1
}

dest="$dest_dir/$name"
if [ -f "$dest" ] && echo "$hash  $dest" | sha512sum -c >/dev/null 2>&1; then
	echo "kernel distfile already valid: $name"
	exit 0
fi

part="${TMPDIR:-/tmp}/kernel-distfile.$$.part"
trap 'rm -f "$part"' EXIT

i=1
while [ "$i" -le "$retries" ]; do
	echo "prefetch kernel distfile attempt $i/$retries: $name"
	if "$curl_cmd" -fL --retry 3 --retry-delay 2 --retry-all-errors \
		-o "$part" "$url" \
		&& echo "$hash  $part" | sha512sum -c >/dev/null 2>&1; then
		mv "$part" "$dest"
		trap - EXIT
		echo "kernel distfile verified: $name"
		exit 0
	fi
	echo "kernel distfile attempt $i failed (download or sha512)" >&2
	rm -f "$part"
	i=$((i + 1))
	if [ "$i" -le "$retries" ] && [ "${DC1_PREFETCH_SLEEP:-1}" != 0 ]; then
		sleep $((i * 2))
	fi
done

echo "kernel distfile failed sha512 after $retries attempts: $name" >&2
exit 1
