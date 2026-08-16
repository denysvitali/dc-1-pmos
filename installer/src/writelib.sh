# writelib.sh -- the shared, fail-closed rootfs write/verify core.
# Sourced (not executed) by BOTH transports:
#   * receive.sh   -- USB gadget network, raw image streamed by the host
#   * netinstall.sh -- on-device Wi-Fi download of the release .zst
#
# The caller must have sourced partlib.sh first and must define:
#   say  MSG   -- progress reporting (socket / status screen)
#   fail MSG   -- report and exit non-zero (never returns)
#
# Fail-closed rules owned HERE, in the order they protect:
#   * the target is resolved BY GPT PARTITION NAME (PARTNAME=userdata in
#     sysfs), never a hardcoded /dev/sdX, and must be unique and >= 32 GiB.
#     preloader / lk / dtbo / vendor_boot / boot partitions are untouchable
#     by construction.
#   * the image's first MiB (superblock) is held back in RAM and written
#     LAST, only after the caller's verification predicate passed -- so an
#     aborted or corrupted transfer can never leave a mountable filesystem
#     labelled jagar-root behind.
#   * a failed device write (dd) is FATAL: the stream is drained so the
#     hash still covers all received bytes, but nothing can be committed.
#   * the written filesystem must carry ext4 label "jagar-root" (the label
#     the boot initramfs mounts by) before it is mounted or provisioned.
#
# Offline-testable: DC1_DEV overrides the resolved target (may be a regular
# file in tests) and DC1_PART_BYTES overrides the partition size.

MIB=1048576
WR_FIRST=/tmp/first-mib
WR_SHA256=""
WR_BYTES=""
WR_RESIZE_NOTE=""

# wr_open_target: resolve and sanity-check the target. Sets WR_DEV and
# WR_PART_BYTES; calls fail on any mismatch.
wr_open_target() {
	if [ -n "${DC1_DEV:-}" ]; then
		WR_DEV=$DC1_DEV
		[ -e "$WR_DEV" ] || fail "$WR_DEV does not exist"
	else
		WR_DEV=$(resolve_userdata) || fail "cannot resolve userdata partition"
		[ -b "$WR_DEV" ] || fail "$WR_DEV is not a block device"
	fi
	if [ -n "${DC1_PART_BYTES:-}" ]; then
		WR_PART_BYTES=$DC1_PART_BYTES
	else
		wr_sectors=$(cat "$SYSBLOCK/$(basename "$WR_DEV")/size" 2>/dev/null || echo 0)
		WR_PART_BYTES=$((wr_sectors * 512))
	fi
	say "TARGET $WR_DEV ($((WR_PART_BYTES / 1024 / 1024 / 1024)) GIB)"
}

# wr_scrub: kill the first MiB (any existing filesystem signature). From this
# point on the partition is not bootable until the verified superblock lands
# last. Also used to reject: after it, nothing mountable remains.
wr_scrub() {
	dd if=/dev/zero of="$WR_DEV" bs=$MIB count=1 conv=fsync 2>/dev/null \
		|| fail "cannot write to $WR_DEV"
}

# Internal: consume the raw stream after the hash tee. Splits off exactly the
# first MiB and writes the remainder at offset 1 MiB. dd failure (ENOSPC past
# the partition end, I/O error) is recorded and the rest of the stream is
# drained so the hash side still sees every byte.
#
# `dd bs=1M count=1 iflag=fullblock`, NOT `head -c`: head reads in chunks and
# discards whatever it over-read past its byte count. On a regular file that is
# invisible (it can seek back), which is why every offline test passed -- but
# on a PIPE the over-read bytes are gone for good, so the body write starts
# mid-image and every byte after the superblock lands shifted. Measured on
# hardware: 1023 bytes swallowed, ext4 metadata and the journal shredded, and
# the install still reported success because the SHA-256 is computed on the
# tee branch (what ARRIVED) rather than on what dd wrote.
wr_body_() {
	dd of="$WR_FIRST" bs=$MIB count=1 iflag=fullblock 2>/dev/null
	if dd of="$WR_DEV" bs=$MIB seek=1 conv=fsync 2>/dev/null; then
		echo ok > /tmp/dd.status
	else
		cat > /dev/null
		echo fail > /tmp/dd.status
	fi
}

# wr_receive_stream [SIZE_LIMIT]: read the RAW ext4 image from stdin (at most
# SIZE_LIMIT bytes if given), hold the first MiB back in RAM, write the rest.
# Sets WR_SHA256 to the SHA-256 of everything read. Returns non-zero if the
# device write failed -- the caller must then wr_reject.
wr_receive_stream() {
	wr_limit=${1:-}
	rm -f /tmp/hash.fifo /tmp/count.fifo /tmp/hash.out /tmp/count.out \
		/tmp/dd.status "$WR_FIRST"
	mkfifo /tmp/hash.fifo || fail "mkfifo failed"
	mkfifo /tmp/count.fifo || fail "mkfifo failed"
	sha256sum /tmp/hash.fifo > /tmp/hash.out &
	wr_hashpid=$!
	# Byte count of the stream, so wr_commit knows how much of the device to
	# read back. Counted here rather than trusting the caller's declared size:
	# a short transfer must not shorten the verification to match itself.
	wc -c < /tmp/count.fifo > /tmp/count.out &
	wr_countpid=$!
	if [ -n "$wr_limit" ]; then
		head -c "$wr_limit" | tee /tmp/hash.fifo /tmp/count.fifo | wr_body_
	else
		tee /tmp/hash.fifo /tmp/count.fifo | wr_body_
	fi
	wait "$wr_hashpid"
	wait "$wr_countpid"
	WR_SHA256=$(cut -d' ' -f1 < /tmp/hash.out)
	WR_BYTES=$(tr -d ' \n' < /tmp/count.out)
	rm -f /tmp/hash.fifo /tmp/count.fifo /tmp/hash.out /tmp/count.out
	[ "$(cat /tmp/dd.status 2>/dev/null)" = ok ]
}

# wr_reject REASON: scrub whatever partial body was written (the superblock
# was never written, but scrub anyway) and fail.
wr_reject() {
	rm -f "$WR_FIRST"
	dd if=/dev/zero of="$WR_DEV" bs=$MIB count=1 conv=fsync 2>/dev/null
	fail "$@"
}

# wr_commit: write the held-back verified superblock, then require the result
# to be ext4 labelled jagar-root (the label the boot initramfs mounts by).
wr_commit() {
	wr_first_bytes=$(wc -c < "$WR_FIRST" | tr -d ' ')
	[ "$wr_first_bytes" -eq $MIB ] || \
		wr_reject "held-back superblock block is $wr_first_bytes bytes"
	# conv=notrunc is load-bearing: without it dd opens the target O_TRUNC and
	# writing the held-back first MiB throws away everything after it. On a
	# block device O_TRUNC is a no-op, so this is invisible on hardware and
	# only bites file targets (the offline tests, and any future image-file
	# deployment) -- which is exactly the kind of asymmetry that survives.
	dd if="$WR_FIRST" of="$WR_DEV" bs=$MIB conv=notrunc,fsync 2>/dev/null \
		|| fail "writing verified superblock failed"
	rm -f "$WR_FIRST"
	sync
	blkid "$WR_DEV" 2>/dev/null | grep -q 'TYPE="ext4"' \
		|| fail "written image is not ext4"
	blkid "$WR_DEV" 2>/dev/null | grep -q 'LABEL="jagar-root"' \
		|| fail "written filesystem is not labelled jagar-root"

	# Read the image back OFF THE DEVICE and hash it. The stream hash proves
	# what ARRIVED; only this proves what LANDED. blkid above inspects the
	# superblock alone, so a device write that dropped or reordered blocks
	# anywhere past the first MiB still passes it -- and the install is then
	# reported as successful, surfacing much later as a root that will not
	# mount. Reading ~1.5 GiB back from UFS costs a few seconds; a silent
	# corrupt install costs a reflash and a bisect.
	if [ -n "$WR_BYTES" ] && [ -n "$WR_SHA256" ]; then
		say "VERIFYING WRITTEN IMAGE"
		wr_mibs=$(( (WR_BYTES + MIB - 1) / MIB ))
		wr_back=$(dd if="$WR_DEV" bs=$MIB count="$wr_mibs" 2>/dev/null \
			| head -c "$WR_BYTES" | sha256sum | cut -d' ' -f1)
		[ "$wr_back" = "$WR_SHA256" ] || wr_reject \
			"read-back mismatch: device has $wr_back, image is $WR_SHA256"
	fi
	say "IMAGE WRITTEN + VERIFIED"
}

# wr_finalize ANSWERS_FILE: mount, grow, provision, unmount. Sets
# WR_RESIZE_NOTE to RESIZED or RESIZE-FAILED.
wr_finalize() {
	wr_answers=$1
	mkdir -p /mnt/root
	mount -t ext4 "$WR_DEV" /mnt/root || fail "mount failed"
	mount -o bind /dev  /mnt/root/dev  2>/dev/null
	mount -t proc  proc  /mnt/root/proc 2>/dev/null
	mount -t sysfs sysfs /mnt/root/sys  2>/dev/null

	# Resizing happens OFFLINE, below, after the final umount. The ONLINE path
	# (EXT4_IOC_RESIZE_FS on a mounted fs) corrupts the extent tree on this
	# kernel (7.2.0-rc5 mtk-ufs): after an install that mounted cleanly and then
	# ran an online resize, every read failed with "ext4_map_blocks: inode #2:
	# lblock 0 mapped to illegal pblock" and the final umount returned EBUSY --
	# a fresh install left unbootable. resize2fs on the UNMOUNTED device rewrites
	# the fs directly and is safe. Until the finalize path below, the note stays
	# the "not yet resized" default.
	WR_RESIZE_NOTE="NOT-RESIZED"

	# Provisioning is SKIPPED for an unprovisioned install: the rootfs is
	# written and resized, but no user/hostname/timezone/Wi-Fi is applied and
	# the idempotence marker is left unset. On first boot the installed
	# system's Flutter UI then runs onboarding and provisions itself (via
	# dc1-backend's /onboard, the Go port of provision.sh). This is the
	# "flash and interact with the touchscreen immediately" flow; the classic
	# provisioned install (answers applied here) is still the default.
	if [ -n "${DC1_SKIP_PROVISION:-}" ]; then
		say "SKIPPING PROVISIONING (unprovisioned install: onboard on first boot)"
	else
		say "PROVISIONING"
		if ! /etc/installer/provision.sh /mnt/root "$wr_answers"; then
			umount /mnt/root/dev /mnt/root/proc /mnt/root/sys 2>/dev/null
			umount /mnt/root 2>/dev/null
			fail "provisioning failed (image is written; fix answers and retry)"
		fi
	fi

	umount /mnt/root/dev /mnt/root/proc /mnt/root/sys 2>/dev/null
	umount /mnt/root || fail "umount failed"
	sync

	# Grow the filesystem to fill userdata, OFFLINE (see the note above). The
	# device is unmounted here, so resize2fs rewrites the fs directly instead of
	# the corrupting online ioctl. Idempotent and best-effort: a failure leaves
	# a valid (smaller) root, which the boot initramfs can still grow later.
	if command -v resize2fs >/dev/null 2>&1; then
		wr_resize_err=$(resize2fs "$WR_DEV" 2>&1)
		if [ $? -eq 0 ]; then
			WR_RESIZE_NOTE="RESIZED"
			say "RESIZED ROOT FILESYSTEM"
		else
			WR_RESIZE_NOTE="RESIZE-FAILED"
			say "RESIZE FAILED: $(echo "$wr_resize_err" | head -1)"
		fi
	else
		WR_RESIZE_NOTE="NOT-RESIZED"
	fi
}

# One install at a time, across BOTH transports. mkdir is the atomic test.
# wr_unlock only releases a lock THIS session took: fail() paths run it
# unconditionally, and they must never free a concurrent session's lock.
WR_LOCKED=0
wr_lock() {
	mkdir /tmp/install.lock 2>/dev/null && WR_LOCKED=1
}

wr_unlock() {
	[ "$WR_LOCKED" = 1 ] || return 0
	WR_LOCKED=0
	rmdir /tmp/install.lock 2>/dev/null
}
