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
# the signature entry). abuild-tar --cut strips GNU tar's two end markers.
# Use a one-record blocking factor, validate those final blocks are zero, then
# cut them dynamically; do not assume the signature payload is always four
# blocks or tied forever to one RSA key size.
tar --format=posix \
	--pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0 \
	--blocking-factor=1 --no-recursion --null -c -C "$tmp" \
	".SIGN.RSA.$keyname" >"$tmp/sig.tar"
sig_bytes=$(wc -c <"$tmp/sig.tar" | tr -d ' ')
[ $((sig_bytes % 512)) -eq 0 ] || {
	echo "sign-apkindex: signature tar is not 512-byte aligned" >&2
	exit 1
}
tail_nonzero=$(tail -c 1024 "$tmp/sig.tar" | od -An -v -tu1 |
	awk '{ for (i = 1; i <= NF; i++) if ($i != 0) n++ } END { print n + 0 }')
[ "$tail_nonzero" -eq 0 ] || {
	echo "sign-apkindex: signature tar lacks two zero end blocks" >&2
	exit 1
}
content_blocks=$((sig_bytes / 512 - 2))
[ "$content_blocks" -gt 0 ] || {
	echo "sign-apkindex: empty signature tar" >&2
	exit 1
}
dd if="$tmp/sig.tar" of="$tmp/sig.cut.tar" bs=512 \
	count="$content_blocks" 2>/dev/null
gzip -n -9 <"$tmp/sig.cut.tar" >"$tmp/sig.tar.gz"

cat "$tmp/sig.tar.gz" "$index" >"$tmp/signed.tar.gz"
mv "$tmp/signed.tar.gz" "$index"
