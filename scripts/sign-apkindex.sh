#!/bin/sh
# Sign an APKINDEX.tar.gz exactly the way abuild-sign does, so apk-tools
# verifies it against a committed *.rsa.pub key.
#
# Usage: sign-apkindex.sh PRIVKEY PUBKEY INDEX
#
# The signature is an RSA/SHA-1 digest of the whole index (apk v2 ".SIGN.RSA."
# convention, matching abuild-sign's default and the throwaway keys
# pmbootstrap already signs the packages with). It is prepended to the index
# as a gzip'd POSIX tar holding one file named ".SIGN.RSA.<pubkey basename>".
# apk-tools resolves the signing key by THAT filename, so the pubkey basename
# is load-bearing: it must match the file a device installs in /etc/apk/keys.
#
# Only the private key is secret; the public key is committed to the repo and
# shipped on-device. This script writes the signature to a private temp dir
# and signs the index in place.
set -eu

[ "$#" -eq 3 ] || {
	echo "usage: $0 PRIVKEY PUBKEY INDEX" >&2
	exit 2
}
privkey=$1
pubkey=$2
index=$3

for f in "$privkey" "$pubkey" "$index"; do
	[ -f "$f" ] || { echo "sign-apkindex: missing file: $f" >&2; exit 1; }
done

keyname=${pubkey##*/}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sig="$tmp/.SIGN.RSA.$keyname"

openssl dgst -sha1 -sign "$privkey" -out "$sig" "$index"

# Build the signature tar with the same options abuild's apk_tar() uses
# (POSIX format + a pax extended header, which apk-tools requires to find
# the signature entry). GNU tar then pads the archive with trailing
# zero-blocks; abuild-tar --cut strips those, leaving exactly the four
# content blocks (pax header, pax data, file header, file data). For a
# <= 512-byte RSA signature that is always 2048 bytes, so replicate the cut
# with head -c. The keyname and 4096-bit key are fixed by this repo, so the
# four-block layout is stable.
tar --format=posix \
	--pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0 \
	--no-recursion --null -c -C "$tmp" ".SIGN.RSA.$keyname" |
	head -c 2048 | gzip -n -9 >"$tmp/sig.tar.gz"

cat "$tmp/sig.tar.gz" "$index" >"$tmp/signed.tar.gz"
mv "$tmp/signed.tar.gz" "$index"
