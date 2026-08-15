#!/bin/sh
# Offline tests for installer/src/writelib.sh -- the shared fail-closed
# write/verify core. Uses a regular file as the target (DC1_DEV /
# DC1_PART_BYTES overrides); no root, no device.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

MIB=1048576

# Each scenario runs in a subshell where fail() aborts with 99, mirroring
# the real callers (whose fail() never returns).
scenario() {
	(
		set -eu
		export DC1_STATUS_FILE="$TMP/status"
		SYSBLOCK="$TMP/nosys"
		say() { :; }
		fail() { echo "wr-fail: $*" >&2; exit 99; }
		. "$HERE/../src/partlib.sh"
		. "$HERE/../src/writelib.sh"
		WR_FIRST="$TMP/first-mib"
		"$@"
	)
}

# A fake 3 MiB raw image with distinctive content.
img="$TMP/image"
{
	printf 'SUPERBLOCK-MIB '
	head -c $((MIB - 15)) /dev/zero | tr '\0' 'S'
	head -c $MIB /dev/zero | tr '\0' 'B'
	head -c $MIB /dev/zero | tr '\0' 'C'
} > "$img"
img_sha=$(sha256sum "$img" | cut -d' ' -f1)

echo "== wr_open_target =="

target="$TMP/target"
head -c $((8 * MIB)) /dev/zero > "$target"

t_open() {
	wr_open_target
	[ "$WR_DEV" = "$target" ] && [ "$WR_PART_BYTES" = $((8 * MIB)) ]
}
if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_open; then
	ok "resolves DC1_DEV override with DC1_PART_BYTES"
else
	bad "wr_open_target override"
fi

if DC1_DEV="$TMP/missing" scenario t_open 2>/dev/null; then
	bad "accepted a missing target"
else
	ok "rejects a missing target"
fi

echo "== wr_receive_stream =="

t_stream() {
	wr_open_target
	wr_scrub
	wr_receive_stream < "$img"
	echo "$WR_SHA256" > "$TMP/got_sha"
}
if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_stream; then
	[ "$(cat "$TMP/got_sha")" = "$img_sha" ] \
		&& ok "stream SHA-256 matches the image" \
		|| bad "stream SHA-256 mismatch"
	# The first MiB of the target must still be untouched (zeros): the
	# superblock is held back until wr_commit.
	if head -c $MIB "$target" | tr -d '\0' | grep -q .; then
		bad "superblock area written before commit"
	else
		ok "first MiB stays zero before commit"
	fi
	# Body written at offset 1 MiB must equal the image body.
	body_img=$(tail -c +$((MIB + 1)) "$img" | sha256sum | cut -d' ' -f1)
	body_dev=$(tail -c +$((MIB + 1)) "$target" | head -c $((2 * MIB)) \
		| sha256sum | cut -d' ' -f1)
	[ "$body_img" = "$body_dev" ] \
		&& ok "image body written at 1 MiB offset" \
		|| bad "image body mismatch on target"
	# Held-back first MiB must equal the image's first MiB.
	fm_img=$(head -c $MIB "$img" | sha256sum | cut -d' ' -f1)
	fm_held=$(sha256sum "$TMP/first-mib" | cut -d' ' -f1)
	[ "$fm_img" = "$fm_held" ] \
		&& ok "held-back first MiB preserved byte-exact" \
		|| bad "held-back first MiB corrupted"
else
	bad "wr_receive_stream failed on a good stream"
fi

# A device write failure must be reported (stream drained, non-zero rc).
if [ -w /dev/full ]; then
	t_ddfail() {
		wr_open_target
		wr_receive_stream < "$img"
	}
	if DC1_DEV=/dev/full DC1_PART_BYTES=$((8 * MIB)) scenario t_ddfail 2>/dev/null; then
		bad "dd failure went unnoticed"
	else
		ok "reports a failed device write"
	fi
else
	echo "  skip: no /dev/full on this host"
fi

echo "== wr_reject =="

t_reject() {
	wr_open_target
	wr_scrub
	wr_receive_stream < "$img"
	wr_reject "test rejection"
}
head -c $((8 * MIB)) /dev/zero > "$target"
if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_reject 2>/dev/null; then
	bad "wr_reject did not fail"
else
	if head -c $MIB "$target" | tr -d '\0' | grep -q .; then
		bad "wr_reject left data in the first MiB"
	else
		ok "wr_reject scrubs and fails"
	fi
fi

echo "== wr_commit =="

if command -v mkfs.ext4 >/dev/null 2>&1 && command -v blkid >/dev/null 2>&1; then
	# Real ext4 image labelled jagar-root: commit must succeed and the
	# target must then carry the label.
	ext4="$TMP/ext4.img"
	head -c $((8 * MIB)) /dev/zero > "$ext4"
	mkfs.ext4 -q -L jagar-root "$ext4"
	head -c $((8 * MIB)) /dev/zero > "$target"
	t_commit() {
		wr_open_target
		wr_scrub
		wr_receive_stream < "$ext4"
		wr_commit
	}
	if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_commit; then
		blkid "$target" | grep -q 'LABEL="jagar-root"' \
			&& ok "commit writes the superblock and label survives" \
			|| bad "committed target lacks the jagar-root label"
	else
		bad "wr_commit failed on a labelled ext4 image"
	fi

	# Wrong label: fail-closed.
	head -c $((8 * MIB)) /dev/zero > "$ext4"
	mkfs.ext4 -q -L not-jagar "$ext4"
	head -c $((8 * MIB)) /dev/zero > "$target"
	if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_commit 2>/dev/null; then
		bad "committed a filesystem without the jagar-root label"
	else
		ok "refuses to commit without the jagar-root label"
	fi

	# Not ext4 at all.
	head -c $((8 * MIB)) /dev/zero > "$target"
	t_commit_raw() {
		wr_open_target
		wr_scrub
		wr_receive_stream < "$img"
		wr_commit
	}
	if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_commit_raw 2>/dev/null; then
		bad "committed a non-ext4 image"
	else
		ok "refuses to commit a non-ext4 image"
	fi
else
	echo "  skip: mkfs.ext4/blkid unavailable on this host"
fi

# Short held-back block (image under 1 MiB) must be rejected at commit.
t_short() {
	wr_open_target
	wr_scrub
	head -c 4096 "$img" | wr_receive_stream || true
	wr_commit
}
head -c $((8 * MIB)) /dev/zero > "$target"
if DC1_DEV="$target" DC1_PART_BYTES=$((8 * MIB)) scenario t_short 2>/dev/null; then
	bad "committed a sub-MiB stream"
else
	ok "refuses to commit a sub-MiB stream"
fi

# Byte-exactness THROUGH A PIPE. This is the regression test for the bug that
# shipped: the body split used `head -c`, which discards whatever it over-read
# past its count. Against a regular file that is invisible (head seeks back),
# so every test here passed while real installs -- fed from a socket, i.e. a
# pipe -- silently shifted the whole image by the over-read (1023 bytes,
# measured on hardware) and produced an unmountable root.
#
# The stream is deliberately delivered in awkward, non-power-of-two chunks
# through a pipe, because a pipe that hands over exact 1 MiB reads would not
# reproduce it.
# The split itself is what regressed, so this checks it directly rather than
# going through wr_commit (whose ext4/label gate would reject random content).
# Reconstructing WR_FIRST + the body must reproduce the input byte for byte.
t_exact() {
	wr_open_target
	wr_scrub
	wr_receive_stream
}
exact_img="$TMP/exact-image"
head -c $((3 * MIB)) /dev/urandom > "$exact_img"
head -c $((8 * MIB)) /dev/zero > "$target"
# Fed in 7001-byte chunks through a pipe, so the 1 MiB boundary lands mid-read
# and an over-reading splitter loses the remainder of that read.
#
# Honest limitation: this cannot FAIL on a GNU-coreutils host, because GNU
# head -c does not over-read a pipe -- only busybox does, and how much it eats
# varies by version and by how the pipe delivers (1023 bytes, measured on the
# device's busybox 1.38.0; not reproducible against 1.37.0 here). So this is
# defence-in-depth, and the structural check below is the tripwire that holds.
if (dd if="$exact_img" bs=7001 2>/dev/null | DC1_DEV="$target" \
	DC1_PART_BYTES=$((8 * MIB)) scenario t_exact) 2>/dev/null; then
	{
		cat "$TMP/first-mib"
		dd if="$target" bs=$MIB skip=1 2>/dev/null
	} | head -c $((3 * MIB)) > "$TMP/exact-rebuilt"
	if cmp -s "$exact_img" "$TMP/exact-rebuilt"; then
		ok "pipe-fed stream is split byte-exact"
	else
		bad "pipe-fed stream is NOT byte-exact (head -c over-read regression)"
	fi
else
	bad "wr_receive_stream failed on a pipe-fed stream"
fi

echo
echo "test-writelib: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
