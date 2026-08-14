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
# first MiB (busybox head -c never reads past its byte count) and writes the
# remainder at offset 1 MiB. dd failure (ENOSPC past the partition end, I/O
# error) is recorded and the rest of the stream is drained so the hash side
# still sees every byte.
wr_body_() {
	head -c $MIB > "$WR_FIRST"
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
	rm -f /tmp/hash.fifo /tmp/hash.out /tmp/dd.status "$WR_FIRST"
	mkfifo /tmp/hash.fifo || fail "mkfifo failed"
	sha256sum /tmp/hash.fifo > /tmp/hash.out &
	wr_hashpid=$!
	if [ -n "$wr_limit" ]; then
		head -c "$wr_limit" | tee /tmp/hash.fifo | wr_body_
	else
		tee /tmp/hash.fifo | wr_body_
	fi
	wait "$wr_hashpid"
	WR_SHA256=$(cut -d' ' -f1 < /tmp/hash.out)
	rm -f /tmp/hash.fifo /tmp/hash.out
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
	dd if="$WR_FIRST" of="$WR_DEV" bs=$MIB conv=fsync 2>/dev/null \
		|| fail "writing verified superblock failed"
	rm -f "$WR_FIRST"
	sync
	blkid "$WR_DEV" 2>/dev/null | grep -q 'TYPE="ext4"' \
		|| fail "written image is not ext4"
	blkid "$WR_DEV" 2>/dev/null | grep -q 'LABEL="jagar-root"' \
		|| fail "written filesystem is not labelled jagar-root"
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

	# Grow the filesystem to the whole partition. ext4 supports online grow,
	# so this runs from the freshly installed rootfs via chroot. Non-fatal:
	# a system at image size still boots; the failure is reported loudly.
	WR_RESIZE_NOTE="RESIZED"
	if chroot /mnt/root /usr/sbin/resize2fs "$WR_DEV" 2>/dev/null \
	   || chroot /mnt/root /sbin/resize2fs "$WR_DEV" 2>/dev/null; then
		say "FILESYSTEM RESIZED"
	else
		WR_RESIZE_NOTE="RESIZE-FAILED"
		say "WARNING: RESIZE2FS FAILED - ROOT STAYS AT IMAGE SIZE"
	fi

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
