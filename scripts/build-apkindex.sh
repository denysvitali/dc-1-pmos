#!/bin/sh
# Build and sign an APKINDEX.tar.gz for the published device/kernel .apk
# files, so a running device can `apk upgrade` them over the network instead
# of re-flashing. Run by CI after the release directory is assembled.
#
# Usage: DC1_APK_PRIVATE_KEY="<PEM RSA private key>" build-apkindex.sh RELEASE_DIR
#
# The index is signed with the STABLE DC-1 signing key. Its public half is
# committed at pmaports/device/testing/device-daylight-jagar/dc1-apk.rsa.pub
# and shipped on-device into /etc/apk/keys by the device package, so a device
# that trusts it once verifies every future release.
#
# Fail-closed by design:
#   * refuses to run without DC1_APK_PRIVATE_KEY (CI must not silently
#     publish an unsigned index);
#   * verifies the secret is a valid RSA key AND that its public half matches
#     the committed key (a wrong secret would sign an index no device can
#     verify, which is a silent failure on hardware);
#   * authenticates the current Alpine apk-tools-static before execution.
set -eu

usage() {
	echo "usage: DC1_APK_PRIVATE_KEY=... $0 RELEASE_DIR" >&2
	exit 2
}
[ "$#" -eq 1 ] || usage
release_dir=$(CDPATH= cd -- "$1" && pwd)
[ -d "$release_dir" ] || { echo "build-apkindex: no such directory: $release_dir" >&2; exit 1; }

: "${DC1_APK_PRIVATE_KEY:?DC1_APK_PRIVATE_KEY is required (a PEM RSA private key; see .github/workflows/build.yml)}"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
keyname=dc1-apk
pubkey="$script_dir/../pmaports/device/testing/device-daylight-jagar/$keyname.rsa.pub"
[ -f "$pubkey" ] || { echo "build-apkindex: committed public key missing: $pubkey" >&2; exit 1; }

for tool in openssl python3 sha256sum tar gzip head diff; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "build-apkindex: missing required tool: $tool" >&2
		exit 1
	}
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
chmod 700 "$work"
privkey="$work/$keyname.rsa"

# The private key reaches this script only through the environment (a CI
# secret). It is written to an ephemeral 0700 temp dir, never a committed
# path, and never echoed.
(umask 077; printf '%s\n' "$DC1_APK_PRIVATE_KEY" >"$privkey")
unset DC1_APK_PRIVATE_KEY

openssl rsa -in "$privkey" -check -noout 2>/dev/null ||
	{ echo "build-apkindex: DC1_APK_PRIVATE_KEY is not a valid RSA private key" >&2; exit 1; }

# The secret must be the mate of the committed public key. Compare DER forms,
# not PEM text, so key-encoding whitespace differences cannot false-negative.
openssl rsa -in "$privkey" -pubout -outform DER 2>/dev/null |
	sha256sum | cut -d' ' -f1 >"$work/secret-pub.der.sha256"
openssl pkey -pubin -in "$pubkey" -outform DER 2>/dev/null |
	sha256sum | cut -d' ' -f1 >"$work/committed-pub.der.sha256"
if ! diff -q "$work/secret-pub.der.sha256" "$work/committed-pub.der.sha256" >/dev/null; then
	echo "build-apkindex: DC1_APK_PRIVATE_KEY does not match the committed public key $keyname.rsa.pub" >&2
	exit 1
fi

# Bootstrap the current host apk from Alpine's signed index, without a
# version pin. No downloaded executable runs before authentication.
mkdir "$work/bootstrap"
APK=$(python3 -I "$script_dir/bootstrap-alpine-apk.py" "$work/bootstrap") || {
	echo "build-apkindex: cannot bootstrap trusted Alpine apk" >&2
	exit 1
}

# Build the (unsigned) index over the published packages. --allow-untrusted
# is required: pmbootstrap signs each run's packages with a throwaway key,
# and the packages need not carry our stable key's signature -- apk verifies
# downloaded packages against the index's checksum, not their own signature
# (apk_sign_ctx action APK_SIGN_VERIFY_IDENTITY). The trust anchor is the
# index signature below.
( cd "$release_dir" &&
	"$APK" index --allow-untrusted --no-warnings -o APKINDEX.tar.gz ./*.apk )

sh "$script_dir/sign-apkindex.sh" "$privkey" "$pubkey" "$release_dir/APKINDEX.tar.gz"

# Acceptance gate from the consumer's side. A correct-looking tar/signature is
# not enough: initialize an isolated apk database with only the committed key,
# point it at the exact flat index-file URL shape devices use, and require apk
# itself to accept and parse the signed index. This catches signing-format,
# key-name, and tar-cut regressions before publication.
verify_root="$work/verify-root"
mkdir -p "$verify_root/etc/apk/keys" "$verify_root/lib/apk" \
	"$verify_root/var/lib/apk"
cp "$pubkey" "$verify_root/etc/apk/keys/$keyname.rsa.pub"
: >"$verify_root/empty-repositories"
set --
if [ "$(id -u)" -ne 0 ]; then
	set -- --usermode
fi
"$APK" --root "$verify_root" \
	--keys-dir "$verify_root/etc/apk/keys" \
	--repositories-file "$verify_root/empty-repositories" \
	--no-cache add --initdb "$@" >/dev/null
printf 'file://%s/APKINDEX.tar.gz\n' "$release_dir" \
	>"$verify_root/repositories"
"$APK" --root "$verify_root" \
	--keys-dir "$verify_root/etc/apk/keys" \
	--repositories-file "$verify_root/repositories" \
	--no-cache update >/dev/null || {
	echo "build-apkindex: apk rejected the signed APKINDEX with the committed key" >&2
	exit 1
}

echo "built, signed, and apk-verified $release_dir/APKINDEX.tar.gz with $keyname.rsa.pub"
