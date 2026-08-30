#!/bin/sh
# Exercise the APKINDEX signature tar across the 512-byte tar-data boundary.
# The historical implementation cut a fixed 2048 bytes and silently assumed
# an RSA signature no larger than one tar block.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
signer="$here/../sign-apkindex.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "sign-apkindex test failed: $*" >&2; exit 1; }

# The publisher runs on Ubuntu and sign-apkindex deliberately uses GNU tar's
# pax controls. Alpine's BusyBox tar cannot create that format; keep the full
# repository verify runnable on-device while CI exercises the actual signer.
if ! tar --help 2>&1 | grep -q -- '--format'; then
	echo "sign-apkindex tests skipped: GNU tar is unavailable"
	exit 0
fi

for bits in 2048 5120; do
	key="$tmp/key-$bits.rsa"
	pub="$tmp/key-$bits.rsa.pub"
	index="$tmp/APKINDEX-$bits.tar.gz"
	unsigned="$tmp/APKINDEX-$bits.unsigned.tar.gz"
	sig="$tmp/signature-$bits"

	openssl genrsa -out "$key" "$bits" 2>/dev/null
	openssl rsa -in "$key" -pubout -out "$pub" 2>/dev/null
	printf 'P:synthetic\nV:1-r0\nA:aarch64\n\n' >"$tmp/APKINDEX"
	tar --format=posix --blocking-factor=1 -czf "$index" \
		-C "$tmp" APKINDEX
	cp "$index" "$unsigned"

	sh "$signer" "$key" "$pub" "$index"
	tar -xOzf "$index" ".SIGN.RSA.${pub##*/}" >"$sig" 2>/dev/null ||
		fail "$bits-bit signature entry is not readable"
	[ -s "$sig" ] || fail "$bits-bit signature entry is empty"
	openssl dgst -sha1 -verify "$pub" -signature "$sig" "$unsigned" \
		>/dev/null 2>&1 || fail "$bits-bit signature does not verify"
done

echo "sign-apkindex tests passed"
