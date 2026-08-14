#!/bin/sh
# receive.sh -- device-side handler for one DC1-INSTALL-V1 session (the USB
# fallback transport; the primary path is the on-device tui.sh/netinstall.sh).
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
# The fail-closed write/verify core (GPT PARTNAME resolution, held-back
# superblock, scrub-on-reject, jagar-root label requirement) lives in
# writelib.sh and is shared with the network installer.
#
# Offline-testable: set DC1_LIB=1 and source this file to get the functions
# without running a session; DC1_SYSBLOCK / DC1_DEV / DC1_PART_BYTES override
# sysfs and the resolved device node for tests.

STATUS_FILE=${DC1_STATUS_FILE:-/tmp/installer-status}

# Shared fail-closed userdata resolution (defines SYSBLOCK, MIN_SECTORS,
# resolve_userdata) and the write/verify core. DC1_PARTLIB / DC1_WRITELIB let
# the offline tests point at src/.
. "${DC1_PARTLIB:-/etc/installer/partlib.sh}"
. "${DC1_WRITELIB:-/etc/installer/writelib.sh}"

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
	wr_unlock
	exit 1
}

# Parse "key=value" header lines from stdin until the empty line.
# Sets: hdr_size hdr_sha256 hdr_answers hdr_unprovisioned
read_header() {
	hdr_size=""
	hdr_sha256=""
	hdr_answers=""
	hdr_unprovisioned=""
	read -r magic || return 1
	magic=$(echo "$magic" | tr -d '\r')
	[ "$magic" = "DC1-INSTALL-V1" ] || { echo "bad magic: $magic" >&2; return 1; }
	while read -r line; do
		line=$(echo "$line" | tr -d '\r')
		[ -n "$line" ] || break
		case "$line" in
			size=*)          hdr_size=${line#size=} ;;
			sha256=*)        hdr_sha256=${line#sha256=} ;;
			answers=*)       hdr_answers=${line#answers=} ;;
			unprovisioned=*) hdr_unprovisioned=${line#unprovisioned=} ;;
			*) echo "unknown header line: $line" >&2; return 1 ;;
		esac
	done
	case "$hdr_size" in ''|*[!0-9]*) echo "bad size: $hdr_size" >&2; return 1 ;; esac
	[ "$hdr_size" -ge $((8 * MIB)) ] || { echo "size too small: $hdr_size" >&2; return 1; }
	case "$hdr_sha256" in
		*[!0-9a-f]*|'') echo "bad sha256: $hdr_sha256" >&2; return 1 ;;
	esac
	[ ${#hdr_sha256} -eq 64 ] || { echo "sha256 not 64 hex chars" >&2; return 1; }
	# answers is required only for a provisioned install. unprovisioned=1
	# (an optional, backward-compatible header) installs the image with no
	# answers, so the on-device Flutter onboarding runs on first boot.
	if [ "$hdr_unprovisioned" = "1" ]; then
		hdr_answers=""
	else
		[ -n "$hdr_answers" ] || { echo "missing answers" >&2; return 1; }
	fi
	return 0
}

install_session() {
	say "HOST CONNECTED"

	wr_lock || { echo "DC1-INSTALL: FAIL another install is running"; exit 1; }

	read_header || fail "bad header"

	if [ "$hdr_unprovisioned" = "1" ]; then
		say "UNPROVISIONED INSTALL: onboarding will run on first boot"
		export DC1_SKIP_PROVISION=1
	else
		echo "$hdr_answers" | base64 -d > /tmp/answers 2>/dev/null \
			|| fail "answers: base64 decode failed"
		chmod 600 /tmp/answers

		# Validate the answers BEFORE any destructive step, so a typo in the
		# username does not cost a 2 GiB transfer and a wiped partition.
		/etc/installer/provision.sh --validate /tmp/answers \
			|| fail "answers failed validation"
	fi

	wr_open_target
	[ "$hdr_size" -le "$WR_PART_BYTES" ] || \
		fail "image ($hdr_size bytes) larger than userdata ($WR_PART_BYTES bytes)"

	wr_scrub
	say "RECEIVING IMAGE"
	wr_receive_stream "$hdr_size" || wr_reject "device write failed mid-stream"

	[ "$WR_SHA256" = "$hdr_sha256" ] || \
		wr_reject "sha256 mismatch: got $WR_SHA256 want $hdr_sha256 (short or corrupt transfer)"
	say "SHA-256 VERIFIED"

	wr_commit
	wr_finalize /tmp/answers
	rm -f /tmp/answers
	wr_unlock

	echo "DC1-INSTALL: OK $WR_RESIZE_NOTE rebooting-to-bootloader"
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
