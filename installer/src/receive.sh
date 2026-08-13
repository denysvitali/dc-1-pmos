#!/bin/sh
# receive.sh -- device-side handler for one DC1-INSTALL-V1 session.
#
# Run by busybox `nc -l -p 5555 -e` with the socket on stdin/stdout. The host
# (installer/host/dc1-install.sh) sends a text header, a blank line, then the
# raw (uncompressed) ext4 rootfs image:
#
#   DC1-INSTALL-V1
#   size=<decimal bytes of the raw image>
#   sha256=<64-hex digest of the raw image>
#   answers=<base64 of the answers file, single line>
#   <empty line>
#   <raw image bytes>
#
# Replies are text lines: "DC1: <progress>" while working, then exactly one of
# "DC1-INSTALL: OK ..." or "DC1-INSTALL: FAIL <reason>".
#
# Fail-closed rules, in the order they protect:
#   * the target is resolved BY GPT PARTITION NAME (PARTNAME=userdata in
#     sysfs), never a hardcoded /dev/sdX, and must be unique and >= 32 GiB.
#     Nothing else is ever written. preloader / lk / dtbo / vendor_boot /
#     boot partitions are untouchable by construction.
#   * the image's first MiB (superblock) is held back in RAM and written
#     LAST, only after the SHA-256 of the full stream verified -- so an
#     aborted or corrupted transfer can never leave a mountable filesystem
#     labelled jagar-root behind.
#   * the written filesystem must carry ext4 label "jagar-root" (the label
#     the boot initramfs mounts by) before it is mounted or provisioned.
#
# Offline-testable: set DC1_LIB=1 and source this file to get the functions
# without running a session; DC1_SYSBLOCK / DC1_DEV override sysfs and the
# resolved device node for tests.

STATUS_FILE=${DC1_STATUS_FILE:-/tmp/installer-status}
MIB=1048576

# Shared fail-closed userdata resolution (defines SYSBLOCK, MIN_SECTORS,
# resolve_userdata). DC1_PARTLIB lets the offline tests point at src/.
. "${DC1_PARTLIB:-/etc/installer/partlib.sh}"

say() {
	# To the socket (host) and the status file (painted on the panel).
	echo "DC1: $*"
	echo "$*" > "$STATUS_FILE" 2>/dev/null
	echo "[installd] $*" > /dev/kmsg 2>/dev/null
}

fail() {
	echo "DC1-INSTALL: FAIL $*"
	printf 'INSTALL FAILED\n%s\n' "$*" > "$STATUS_FILE" 2>/dev/null
	echo "[installd] FAIL: $*" > /dev/kmsg 2>/dev/null
	exit 1
}

# Parse "key=value" header lines from stdin until the empty line.
# Sets: hdr_size hdr_sha256 hdr_answers
read_header() {
	hdr_size=""
	hdr_sha256=""
	hdr_answers=""
	read -r magic || return 1
	magic=$(echo "$magic" | tr -d '\r')
	[ "$magic" = "DC1-INSTALL-V1" ] || { echo "bad magic: $magic" >&2; return 1; }
	while read -r line; do
		line=$(echo "$line" | tr -d '\r')
		[ -n "$line" ] || break
		case "$line" in
			size=*)    hdr_size=${line#size=} ;;
			sha256=*)  hdr_sha256=${line#sha256=} ;;
			answers=*) hdr_answers=${line#answers=} ;;
			*) echo "unknown header line: $line" >&2; return 1 ;;
		esac
	done
	case "$hdr_size" in ''|*[!0-9]*) echo "bad size: $hdr_size" >&2; return 1 ;; esac
	[ "$hdr_size" -ge $((8 * MIB)) ] || { echo "size too small: $hdr_size" >&2; return 1; }
	case "$hdr_sha256" in
		*[!0-9a-f]*|'') echo "bad sha256: $hdr_sha256" >&2; return 1 ;;
	esac
	[ ${#hdr_sha256} -eq 64 ] || { echo "sha256 not 64 hex chars" >&2; return 1; }
	[ -n "$hdr_answers" ] || { echo "missing answers" >&2; return 1; }
	return 0
}

install_session() {
	say "HOST CONNECTED"

	read_header || fail "bad header"

	echo "$hdr_answers" | base64 -d > /tmp/answers 2>/dev/null \
		|| fail "answers: base64 decode failed"
	chmod 600 /tmp/answers

	# Validate the answers BEFORE any destructive step, so a typo in the
	# username does not cost a 2 GiB transfer and a wiped partition.
	/etc/installer/provision.sh --validate /tmp/answers \
		|| fail "answers failed validation"

	dev=${DC1_DEV:-$(resolve_userdata)} || fail "cannot resolve userdata partition"
	[ -b "$dev" ] || fail "$dev is not a block device"
	sectors=$(cat "$SYSBLOCK/$(basename "$dev")/size" 2>/dev/null || echo 0)
	part_bytes=$((sectors * 512))
	[ "$hdr_size" -le "$part_bytes" ] || \
		fail "image ($hdr_size bytes) larger than userdata ($part_bytes bytes)"
	say "TARGET $dev ($((part_bytes / 1024 / 1024 / 1024)) GIB)"

	# Kill any existing filesystem signature first: from this point on the
	# partition is not bootable until the verified superblock lands last.
	dd if=/dev/zero of="$dev" bs=$MIB count=1 conv=fsync 2>/dev/null \
		|| fail "cannot write to $dev"

	say "RECEIVING IMAGE"
	rm -f /tmp/hash.fifo /tmp/hash.out /tmp/first-mib
	mkfifo /tmp/hash.fifo || fail "mkfifo failed"
	sha256sum /tmp/hash.fifo > /tmp/hash.out &
	hashpid=$!
	# busybox head -c never reads past its byte count, so the inner head
	# splits off exactly the first MiB and dd receives the remainder.
	head -c "$hdr_size" | tee /tmp/hash.fifo | {
		head -c $MIB > /tmp/first-mib
		dd of="$dev" bs=$MIB seek=1 conv=fsync 2>/dev/null
	}
	wait "$hashpid"
	got_sha=$(cut -d' ' -f1 < /tmp/hash.out)
	rm -f /tmp/hash.fifo

	if [ "$got_sha" != "$hdr_sha256" ]; then
		# The superblock was never written, but scrub anyway.
		dd if=/dev/zero of="$dev" bs=$MIB count=1 conv=fsync 2>/dev/null
		fail "sha256 mismatch: got $got_sha want $hdr_sha256 (short or corrupt transfer)"
	fi
	first_bytes=$(wc -c < /tmp/first-mib | tr -d ' ')
	[ "$first_bytes" -eq $MIB ] || fail "held-back superblock block is $first_bytes bytes"
	say "SHA-256 VERIFIED"

	dd if=/tmp/first-mib of="$dev" bs=$MIB conv=fsync 2>/dev/null \
		|| fail "writing verified superblock failed"
	rm -f /tmp/first-mib
	sync

	# The label is load-bearing: the boot initramfs finds root by it.
	blkid "$dev" 2>/dev/null | grep -q 'TYPE="ext4"' \
		|| fail "written image is not ext4"
	blkid "$dev" 2>/dev/null | grep -q 'LABEL="jagar-root"' \
		|| fail "written filesystem is not labelled jagar-root"
	say "IMAGE WRITTEN + VERIFIED"

	mkdir -p /mnt/root
	mount -t ext4 "$dev" /mnt/root || fail "mount failed"
	mount -o bind /dev  /mnt/root/dev  2>/dev/null
	mount -t proc  proc  /mnt/root/proc 2>/dev/null
	mount -t sysfs sysfs /mnt/root/sys  2>/dev/null

	# Grow the filesystem to the whole partition. ext4 supports online grow,
	# so this runs from the freshly installed rootfs via chroot. Non-fatal:
	# a system at image size still boots; the failure is reported loudly.
	resize_note="RESIZED"
	if chroot /mnt/root /usr/sbin/resize2fs "$dev" 2>/dev/null \
	   || chroot /mnt/root /sbin/resize2fs "$dev" 2>/dev/null; then
		say "FILESYSTEM RESIZED"
	else
		resize_note="RESIZE-FAILED"
		say "WARNING: RESIZE2FS FAILED - ROOT STAYS AT IMAGE SIZE"
	fi

	say "PROVISIONING"
	if ! /etc/installer/provision.sh /mnt/root /tmp/answers; then
		umount /mnt/root/dev /mnt/root/proc /mnt/root/sys 2>/dev/null
		umount /mnt/root 2>/dev/null
		fail "provisioning failed (image is written; fix answers and retry)"
	fi
	rm -f /tmp/answers

	umount /mnt/root/dev /mnt/root/proc /mnt/root/sys 2>/dev/null
	umount /mnt/root || fail "umount failed"
	sync

	echo "DC1-INSTALL: OK $resize_note rebooting-to-bootloader"
	printf 'INSTALL COMPLETE\nREBOOTING TO FASTBOOT\nFLASH THE REAL BOOT IMAGE\n' \
		> "$STATUS_FILE" 2>/dev/null
	echo "[installd] install complete; rebooting to bootloader" > /dev/kmsg 2>/dev/null
	# Give the host a moment to read the OK line, then reboot into LK
	# fastboot (BCB "boot-fastboot") so the host can flash the real boot
	# image over the installer.
	sleep 3
	if [ -x /bin/rebootbl ]; then
		exec /bin/rebootbl
	fi
	reboot -f
}

if [ -z "${DC1_LIB:-}" ]; then
	install_session
fi
