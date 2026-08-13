#!/bin/sh
# Exercise make-ext4-image.sh end to end: one image that must be built and
# readable, and the refusals that must fire. A builder whose safety checks are
# never executed is not a safety check.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
builder="$here/../make-ext4-image.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "make-ext4-image test failed: $*" >&2; exit 1; }

root="$tmp/root"
mkdir -p "$root/sbin" "$root/etc"
printf '#!/bin/sh\n' >"$root/sbin/init"
chmod 0755 "$root/sbin/init"
printf 'ID=postmarketos\n' >"$root/etc/os-release"
printf 'hello\n' >"$root/etc/marker"

# Positive control: a small image with the load-bearing label.
SOURCE_DATE_EPOCH=1700000000 PMOS_EXT4_SIZE_MIB=32 \
	sh "$builder" "$root" "$tmp/out.ext4" jagar-root >"$tmp/log" 2>&1 ||
	{ cat "$tmp/log" >&2; fail "builder refused a valid source tree"; }
[ -f "$tmp/out.ext4" ] || fail "no image produced"
[ ! -e "$tmp/out.ext4.staging" ] || fail "staging file was left behind"
label=$(dumpe2fs -h "$tmp/out.ext4" 2>/dev/null |
	awk -F':[ \t]*' '/^Filesystem volume name:/ { print $2 }')
[ "$label" = jagar-root ] || fail "label is '$label', not jagar-root"
e2fsck -fn "$tmp/out.ext4" >/dev/null || fail "produced filesystem is unclean"
debugfs -R "cat /etc/marker" "$tmp/out.ext4" 2>/dev/null |
	grep -qx hello || fail "source content missing from the image"

# The UUID must be a function of the inputs, not of the wall clock: rebuilding
# the same tree twice has to give the same identity.
first=$(dumpe2fs -h "$tmp/out.ext4" 2>/dev/null |
	awk -F':[ \t]*' '/^Filesystem UUID:/ { print $2 }')
SOURCE_DATE_EPOCH=1700000000 PMOS_EXT4_SIZE_MIB=32 \
	sh "$builder" "$root" "$tmp/again.ext4" jagar-root >/dev/null 2>&1 ||
	fail "second build refused"
second=$(dumpe2fs -h "$tmp/again.ext4" 2>/dev/null |
	awk -F':[ \t]*' '/^Filesystem UUID:/ { print $2 }')
[ "$first" = "$second" ] || fail "UUID is not deterministic: $first vs $second"

# Refusals.
! sh "$builder" "$root" "$tmp/out.ext4" jagar-root >/dev/null 2>&1 ||
	fail "builder overwrote an existing output"
! sh "$builder" "$root" /dev/null jagar-root >/dev/null 2>&1 ||
	fail "builder accepted a target under /dev"
mkdir -p "$tmp/empty"
! sh "$builder" "$tmp/empty" "$tmp/empty.ext4" jagar-root >/dev/null 2>&1 ||
	fail "builder accepted a tree with no /sbin/init"
! sh "$builder" "$root" "$tmp/long.ext4" this-label-is-far-too-long \
	>/dev/null 2>&1 || fail "builder accepted an oversized ext4 label"

echo "make-ext4-image tests passed"
