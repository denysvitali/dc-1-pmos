#!/bin/sh
# dc1-repair-apk.sh -- rescue path for a DC-1 installed before the signed
# package repository existed (device package pkgrel < 45).
#
# Those devices have no dc1-apk.rsa.pub, no
# /etc/apk/repositories.d/dc1-pmos.list, and sometimes not even Alpine's key
# links in /etc/apk/keys: every `apk upgrade` ends in "UNTRUSTED signature",
# so nothing that landed after install day ever reaches them, and the
# dc1-update timer cannot help because it upgrades through the same broken
# apk. This script repairs that in place from the published release.
#
# Run ON THE DEVICE as root:
#
#	curl -fsSL -o /tmp/dc1-repair-apk.sh \
#		https://github.com/denysvitali/dc-1-pmos/raw/main/installer/host/dc1-repair-apk.sh
#	sh /tmp/dc1-repair-apk.sh
#
# (or paste it through the debug shell). Needs curl and apk; network access
# to github.com.
#
# Steps, fail-closed wherever a wrong step could damage package trust:
#   1. fetch SHA256SUMS and parse the recorded digest for dc1-apk.rsa.pub;
#   2. fetch the public key and verify its sha256 against that digest;
#   3. decide_key_action: absent -> install; identical -> keep; DIFFERING ->
#      refuse. A differing key means this rootfs trusts something else and
#      needs a human decision -- never silently replace a trust anchor;
#   4. write /etc/apk/repositories.d/dc1-pmos.list only if absent (same rule);
#   5. best-effort key-link pass into /etc/apk/keys (pre-r45 systems may lack
#      even the Alpine links; mirrors dc1-link-apk-keys);
#   6. `apk update` with warnings tolerated, then `apk upgrade`;
#   7. print the resulting overlay-package versions and the reboot hint.
#
# Environment overrides (offline tests, rescue-from-installer use):
#   DC1_ROOT              operate on a mounted rootfs tree instead of /
#                         (passed to apk as --root)
#   DC1_URL_BASE          release base URL (defaults to the rolling release)
#   DC1_REPAIR_APK_LIB=1  library mode: expose the pure functions, exit

set -eu

ROOT=${DC1_ROOT:-}
URL_BASE=${DC1_URL_BASE:-https://github.com/denysvitali/dc-1-pmos/releases/download/latest}

KEY_NAME=dc1-apk.rsa.pub

# Path accessors instead of constants: they are evaluated at CALL time so a
# test (or a rescue session) can repoint DC1_ROOT between invocations.
key_dest()  { printf '%s\n' "${DC1_ROOT:-}/usr/share/apk/keys/aarch64/$KEY_NAME"; }
etc_keys()  { printf '%s\n' "${DC1_ROOT:-}/etc/apk/keys"; }
repo_list_path() { printf '%s\n' "${DC1_ROOT:-}/etc/apk/repositories.d/dc1-pmos.list"; }
apk_db_path()    { printf '%s\n' "${DC1_ROOT:-}/lib/apk/db/installed"; }

msg() { echo "dc1-repair-apk: $*"; }
die() { echo "dc1-repair-apk: ERROR: $*" >&2; exit 1; }

# sums_digest SUMS_FILE NAME -> the 64-hex SHA-256 recorded for NAME, or
# return 1. Accepts sha256sum's "HASH  NAME" and "HASH *NAME" forms; refuses
# duplicates and malformed digests (fail closed, never guess). Same parser
# as installer/src/netinstall.sh.
sums_digest() {
	sd_hits=$(awk -v n="$2" \
		'{ f = $2; sub(/^\*/, "", f); if (f == n) print $1 }' "$1")
	[ -n "$sd_hits" ] || return 1
	[ "$(printf '%s\n' "$sd_hits" | wc -l)" -eq 1 ] || return 1
	case "$sd_hits" in
		*[!0-9a-f]*) return 1 ;;
	esac
	[ ${#sd_hits} -eq 64 ] || return 1
	printf '%s\n' "$sd_hits"
}

# fetch RELPATH OUTFILE -- curl the release asset with bounded retries.
fetch() {
	curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors \
		-o "$2" "$URL_BASE/$1"
}

# file_sha FILE -> sha256 of an existing file, or "" when unreadable.
file_sha() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# decide_key_action EXPECTED_DIGEST -> "install" | "skip" | "refuse".
# Compares by hash so formatting differences cannot cause a false mismatch,
# and a real mismatch always lands on refuse.
decide_key_action() {
	dest=$(key_dest)
	got=$(file_sha "$dest")
	case "$got" in
		'') echo "install" ;;
		"$1") echo "skip" ;;
		*) echo "refuse" ;;
	esac
}

# install_key SOURCE -- place the verified key where the device package
# keeps it (/usr/share/apk/keys/aarch64) so later dc1-link-apk-keys passes
# keep finding it, then link it into /etc/apk/keys for apk-tools 3.x.
install_key() {
	dest=$(key_dest)
	keys=$(etc_keys)
	mkdir -p "${dest%/*}" "$keys"
	cp "$1" "$dest"
	[ -e "$keys/$KEY_NAME" ] || ln -sf "$dest" "$keys/$KEY_NAME"
}

# write_repo_list -- create the repository list only when absent. An existing
# list is never rewritten: like the signing key, it is a trust decision this
# script must not override.
write_repo_list() {
	list=$(repo_list_path)
	[ -e "$list" ] && return 0
	mkdir -p "${list%/*}"
	{
		echo "# dc-1-pmos rolling package repository, served from the GitHub release. The"
		echo "# URL ends in APKINDEX.tar.gz so apk treats it as an index-file URL and"
		echo "# resolves packages to <dir>/<name>-<version>.apk (the flat release layout)."
		echo "# The index is signed with dc1-apk.rsa.pub (shipped in /usr/share/apk/keys,"
		echo "# linked into /etc/apk/keys at boot by dc1-link-apk-keys)."
		echo "$URL_BASE/APKINDEX.tar.gz"
	} >"$list"
}

# key_link_pass ARCH -- best-effort mirror of dc1-link-apk-keys: link every
# .pub under the root's /usr/share/apk/keys (plus the arch subdir) into
# its /etc/apk/keys without overwriting anything. Pre-r45 roots can be
# missing even the Alpine links, which alone makes every index UNTRUSTED.
key_link_pass() {
	arch=$1
	share=${DC1_ROOT:-}/usr/share/apk/keys
	keys=$(etc_keys)
	[ -d "$share" ] || return 0
	mkdir -p "$keys" 2>/dev/null || return 0
	linked=0
	for dir in "$share" "$share/$arch"; do
		for key in "$dir"/*.pub; do
			[ -e "$key" ] || continue
			[ -e "$keys/${key##*/}" ] && continue
			ln -sf "$key" "$keys/" 2>/dev/null && linked=$((linked + 1))
		done
	done
	[ "$linked" -eq 0 ] || msg "linked $linked apk signing key(s) into $keys"
}

# installed_version PKG -> version recorded in the root's apk database.
installed_version() {
	db=$(apk_db_path)
	[ -r "$db" ] || return 1
	awk -v pkg="$1" '
		/^P:/ { p = substr($0, 3) }
		/^V:/ && p == pkg { print substr($0, 3); exit }
	' "$db"
}

# Library mode for the offline tests.
if [ -n "${DC1_REPAIR_APK_LIB:-}" ]; then
	return 0 2>/dev/null || exit 0
fi

# Root is required only for the live system; with DC1_ROOT (tests, a mounted
# rootfs) unwritable paths fail closed on their own.
[ -n "${DC1_ROOT:-}" ] || [ "$(id -u)" = 0 ] \
	|| die "must run as root (it writes under /etc/apk and /usr/share/apk)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- 1+2. fetch SHA256SUMS, then the key, verify both against each other.
msg "fetching SHA256SUMS from $URL_BASE ..."
fetch SHA256SUMS "$work/SUMS" || die "cannot fetch SHA256SUMS"
want=$(sums_digest "$work/SUMS" "$KEY_NAME") \
	|| die "no usable SHA256SUMS entry for $KEY_NAME"
fetch "$KEY_NAME" "$work/key" || die "cannot fetch $KEY_NAME"
got=$(file_sha "$work/key")
[ "$got" = "$want" ] || die "downloaded $KEY_NAME does not match SHA256SUMS ($got != $want)"
msg "$KEY_NAME verified against SHA256SUMS"

# ---- 3. never replace an existing, differing trust anchor.
case $(decide_key_action "$want") in
	install) install_key "$work/key"; msg "$KEY_NAME installed" ;;
	skip)    msg "$KEY_NAME already present and identical; keeping it" ;;
	refuse)  die "$(key_dest) exists with a DIFFERENT key than the release publishes.
dc1-repair-apk: refusing to overwrite a trust anchor -- decide manually which one is right." ;;
esac

# ---- 4. repository list (only if absent).
list=$(repo_list_path)
if [ -e "$list" ]; then
	msg "$list already exists; keeping it"
else
	write_repo_list
	msg "$list written"
fi

# ---- 5. best-effort key-link pass (also restores plain Alpine links).
key_link_pass "$(uname -m)" || true

# ---- 6. refresh indexes (tolerate partial failure), then upgrade.
apk_root_args=""
[ -n "$ROOT" ] && apk_root_args="--root $ROOT"
if apk $apk_root_args update; then
	msg "apk update ok"
else
	msg "WARNING: apk update failed; continuing with the repositories that did refresh"
fi
msg "running apk upgrade (this installs what resolves) ..."
apk $apk_root_args upgrade

# ---- 7. report + reboot hint.
msg "installed versions now:"
for package in mutter-mobile linux-postmarketos-mediatek-mt6789 device-daylight-jagar; do
	v=$(installed_version "$package") && v=" $v" || v=" (not installed)"
	msg "  $package:$v"
done
msg "done. If linux-postmarketos-mediatek-mt6789 changed, reboot once to boot the new kernel."
