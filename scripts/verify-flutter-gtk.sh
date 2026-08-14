#!/bin/sh
# verify-flutter-gtk.sh -- assert that the flutter-gtk apk the shipped rootfs
# will install is the exact artifact the Flutter bundle was built against.
#
#   sh scripts/verify-flutter-gtk.sh CACHE_DIRECTORY
#
# Why a byte-level pin and not just the version string: flutter-gtk provides
# so:libflutter_linux_gtk.so, which the committed shell dlopens by soname.
# The engine ABI is not stable across Flutter releases, so an embedder that
# is merely "flutter-gtk" is a black screen waiting for Alpine edge to move.
# A version pin alone would already fail closed here -- edge serves one file
# per pkgver-pkgrel, so a bump 404s this URL -- but the size + SHA-256 pair
# also catches a rebuilt r2 and a mirror serving something else, which is the
# same fail-closed shape installer/build.sh uses for the MT7902 firmware.
#
# Recorded from https://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64/
# on 2026-08-14. The library inside is byte-identical (SHA-256
# e0d2e7ad8720b2195d35cd1b8b065a5c398c19ff24b3b3f4ca25c5dff7308eb2) to the
# libflutter_linux_gtk.so a chroot `flutter build linux --release` puts in
# the bundle, which is why the package ships the apk's copy and drops the
# bundle's.
set -eu

# Keep in step with depends= in pmaports/device/testing/dc1-ui/APKBUILD and
# FLUTTER_DESKTOP_VERSION in scripts/build-flutter-ui.sh; scripts/verify.sh
# asserts all three agree.
FLUTTER_GTK_VERSION=3.38.4-r2
FLUTTER_GTK_NAME="flutter-gtk-$FLUTTER_GTK_VERSION.apk"
FLUTTER_GTK_SIZE=5437971
FLUTTER_GTK_SHA256=40359ab1567bcd4fb3fd0c771ac7cafd3e9b4a57d312665631b37b639b2b6dfa

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64"

usage() {
	echo "usage: $0 CACHE_DIRECTORY" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
	""|/|/dev|/dev/*) echo "refusing unsafe cache directory: $1" >&2; exit 2 ;;
esac

fatal() {
	echo "verify-flutter-gtk: $*" >&2
	exit 1
}

cache_dir=$(mkdir -p -- "$1" && CDPATH= cd -- "$1" && pwd)
apk_path="$cache_dir/$FLUTTER_GTK_NAME"

if [ ! -s "$apk_path" ]; then
	command -v curl >/dev/null || fatal "curl is not on PATH"
	curl -fsSL --retry 3 -o "$apk_path.part" \
		"$ALPINE_MIRROR/$FLUTTER_GTK_NAME" ||
		fatal "download failed: $ALPINE_MIRROR/$FLUTTER_GTK_NAME (pin moved off edge?)"
	mv "$apk_path.part" "$apk_path"
fi

actual_size=$(wc -c < "$apk_path" | tr -d ' ')
[ "$actual_size" = "$FLUTTER_GTK_SIZE" ] ||
	fatal "$FLUTTER_GTK_NAME has size $actual_size, expected $FLUTTER_GTK_SIZE"
actual_sha=$(sha256sum "$apk_path")
actual_sha=${actual_sha%% *}
[ "$actual_sha" = "$FLUTTER_GTK_SHA256" ] ||
	fatal "$FLUTTER_GTK_NAME has unexpected SHA-256 $actual_sha (see header comment)"

echo "verified $FLUTTER_GTK_NAME: $actual_size bytes, sha256 $actual_sha"
