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
#   * pins apk-tools-static by version + SHA-256, like installer/build.sh
#     pins busybox-static.
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

for tool in openssl curl sha256sum tar gzip head diff; do
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

# Pinned static apk-tools (aarch64: this job runs on ubuntu-24.04-arm). A
# version bump by Alpine edge 404s here and fails the build closed; update
# the pin deliberately, exactly like the ALPINE_APKS list in installer/build.sh.
apk_pkg="apk-tools-static-3.0.7-r0.apk"
apk_url="https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64/$apk_pkg"
apk_sha256="07476bd1231f7596b186a112ecd6e68a595e27814cf8ba2b0fb994608e3e6d41"
curl -fsSL --retry 3 -o "$work/$apk_pkg" "$apk_url"
printf '%s  %s\n' "$apk_sha256" "$work/$apk_pkg" | sha256sum -c - >/dev/null
tar -xzf "$work/$apk_pkg" -C "$work" 2>/dev/null || true
APK="$work/sbin/apk.static"
[ -x "$APK" ] || { echo "build-apkindex: failed to extract apk.static" >&2; exit 1; }

# Build the (unsigned) index over the published packages. --allow-untrusted
# is required: pmbootstrap signs each run's packages with a throwaway key,
# and the packages need not carry our stable key's signature -- apk verifies
# downloaded packages against the index's checksum, not their own signature
# (apk_sign_ctx action APK_SIGN_VERIFY_IDENTITY). The trust anchor is the
# index signature below.
( cd "$release_dir" &&
	"$APK" index --allow-untrusted --no-warnings -o APKINDEX.tar.gz ./*.apk )

sh "$script_dir/sign-apkindex.sh" "$privkey" "$pubkey" "$release_dir/APKINDEX.tar.gz"

echo "built and signed $release_dir/APKINDEX.tar.gz with $keyname.rsa.pub"
