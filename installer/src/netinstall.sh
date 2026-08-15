#!/bin/sh
# netinstall.sh -- on-device network install: download the rolling release
# on the DC-1 itself (over Wi-Fi brought up by tui.sh) and feed the same
# fail-closed write/verify core the USB transport uses.
#
#   netinstall.sh ANSWERS_FILE
#
# Flow (fail-closed at every step):
#   1. fetch SHA256SUMS from the release -- over verified TLS (curl + the
#      staged CA bundle); the expected digests for everything else come from
#      this file.
#   2. download jagar-rootfs.ext4.zst to tmpfs with resume+retry, then
#      verify its SHA-256 IN FULL before a single byte hits the disk.
#   3. decompress-stream it into writelib.sh: superblock held back, written
#      only after the zstd stream ended cleanly -- an aborted download or
#      truncated decompress can never leave a mountable jagar-root.
#   4. resize + provision (shared wr_finalize / provision.sh).
#   5. download jagar-boot.img, verify its SHA-256, write it to boot_a (the
#      slot the user flashed the installer to), read it back and compare.
#      This is what makes the install computer-free: after reboot the device
#      boots the real system instead of the installer.
#   6. reboot.
#
# Why download-then-verify instead of streaming the download to disk: curl
# can resume a file (-C -) across connection drops, a pipe cannot; and a
# full pre-write verification closes even the window in which corrupt bytes
# touch the partition body. The .zst fits comfortably in tmpfs RAM.
#
# Offline-testable: DC1_LIB=1 sources only the pure functions.

STATUS_FILE=${DC1_STATUS_FILE:-/tmp/installer-status}
URL_BASE=${DC1_URL_BASE:-https://github.com/denysvitali/dc-1-pmos/releases/download/latest}
NET_DIR=${DC1_NET_DIR:-/tmp/net}
ROOTFS_NAME=jagar-rootfs.ext4.zst
BOOTIMG_NAME=jagar-boot.img

# boot_a size window in 512-byte sectors: 8 MiB .. 1 GiB. Outside it the GPT
# mapping is not what we think it is and nothing gets written.
BOOTA_MIN_SECTORS=16384
BOOTA_MAX_SECTORS=2097152

. "${DC1_PARTLIB:-/etc/installer/partlib.sh}"
. "${DC1_WRITELIB:-/etc/installer/writelib.sh}"

say() {
	echo "$*" > "$STATUS_FILE" 2>/dev/null
	echo "[netinstall] $*" > /dev/kmsg 2>/dev/null
	echo "[netinstall] $*"
}

fail() {
	printf 'INSTALL FAILED\n%s\n' "$*" > "$STATUS_FILE" 2>/dev/null
	echo "[netinstall] FAIL: $*" > /dev/kmsg 2>/dev/null
	echo "[netinstall] FAIL: $*" >&2
	wr_unlock
	exit 1
}

# sums_digest SUMS_FILE NAME -> the 64-hex SHA-256 recorded for NAME, or
# return 1. Accepts sha256sum's "HASH  NAME" and "HASH *NAME" forms; refuses
# duplicates and malformed digests (fail closed, never guess).
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

# http_date_epoch_parts "Thu, 01 Jan 2026 12:00:00 GMT" -> "2026-01-01 12:00:00"
# (busybox `date -u -s` format), or return 1.
http_date_to_datespec() {
	set -- $1
	[ $# -ge 6 ] || return 1
	hd_day=$2 hd_mon=$3 hd_year=$4 hd_time=$5
	case "$hd_mon" in
		Jan) hd_m=01 ;; Feb) hd_m=02 ;; Mar) hd_m=03 ;; Apr) hd_m=04 ;;
		May) hd_m=05 ;; Jun) hd_m=06 ;; Jul) hd_m=07 ;; Aug) hd_m=08 ;;
		Sep) hd_m=09 ;; Oct) hd_m=10 ;; Nov) hd_m=11 ;; Dec) hd_m=12 ;;
		*) return 1 ;;
	esac
	case "$hd_year" in [12][0-9][0-9][0-9]) ;; *) return 1 ;; esac
	case "$hd_day" in [0-9]|[0-3][0-9]) ;; *) return 1 ;; esac
	case "$hd_time" in
		[0-2][0-9]:[0-5][0-9]:[0-6][0-9]) ;;
		*) return 1 ;;
	esac
	[ ${#hd_day} -eq 2 ] || hd_day=0$hd_day
	printf '%s-%s-%s %s\n' "$hd_year" "$hd_m" "$hd_day" "$hd_time"
}

# --- everything below has side effects ------------------------------------

CURL="curl -fsSL --connect-timeout 20"

# The RTC may hold nonsense; TLS certificate validation needs a sane clock.
# Bootstrap it from an HTTP Date header (unauthenticated, but the artifact
# trust still rests on the verified TLS chain plus SHA256SUMS afterwards --
# an attacker who controls the clock still cannot forge either).
net_fix_clock() {
	year=$(date -u +%Y)
	case "$year" in
		20[3-9][0-9]|202[5-9]) return 0 ;;
	esac
	say "CLOCK IS $year - SETTING FROM NETWORK"
	hdr=$($CURL --insecure -I "$URL_BASE/SHA256SUMS" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)
	[ -n "$hdr" ] || { say "WARNING: NO DATE HEADER; KEEPING CLOCK"; return 0; }
	spec=$(http_date_to_datespec "$hdr") || \
		{ say "WARNING: UNPARSEABLE DATE HEADER"; return 0; }
	date -u -s "$spec" >/dev/null 2>&1 || say "WARNING: DATE SET FAILED"
}

# net_fetch URL OUT -- resume + retry loop around curl. Returns non-zero
# after all attempts; partial output is kept for the next resume.
net_fetch() {
	nf_try=0
	while [ "$nf_try" -lt 4 ]; do
		if $CURL --retry 5 --retry-delay 3 -C - -o "$2" "$1"; then
			return 0
		fi
		nf_try=$((nf_try + 1))
		say "DOWNLOAD INTERRUPTED - RETRY $nf_try/4"
		sleep 3
	done
	return 1
}

# net_progress FILE LABEL -- background size ticker painted on the panel.
net_progress() {
	while :; do
		sz=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
		[ -n "$sz" ] || sz=0
		say "$2
$((sz / MIB)) MIB DOWNLOADED"
		sleep 5
	done
}

# net_get_verified NAME OUT -- download URL_BASE/NAME with resume+retry and
# require its SHA-256 to match SHA256SUMS. One full re-download on mismatch
# (a stale partial from an aborted run resumes into a wrong hash), then fail.
net_get_verified() {
	want=$(sums_digest "$NET_DIR/SHA256SUMS" "$1") \
		|| fail "no usable SHA256SUMS entry for $1"
	for attempt in 1 2; do
		net_progress "$2" "DOWNLOADING $1" &
		prog_pid=$!
		net_fetch "$URL_BASE/$1" "$2"
		nf_rc=$?
		kill "$prog_pid" 2>/dev/null
		wait "$prog_pid" 2>/dev/null
		[ "$nf_rc" -eq 0 ] || fail "download failed: $1"
		say "VERIFYING $1"
		got=$(sha256sum "$2" | cut -d' ' -f1)
		if [ "$got" = "$want" ]; then
			return 0
		fi
		rm -f "$2"
		say "SHA-256 MISMATCH ON $1 - RETRYING FROM SCRATCH"
	done
	fail "$1 does not match SHA256SUMS after re-download"
}

# net_write_boot_a IMG -- write the verified boot image to boot_a and read it
# back. boot_a is the slot the installer itself was flashed to, so this is
# the same write the fastboot step performed -- no other partition is ever
# touched (preloader / lk / dtbo / vendor_boot stay out of reach).
net_write_boot_a() {
	img=$1
	img_bytes=$(wc -c < "$img" | tr -d ' ')
	img_sha=$(sha256sum "$img" | cut -d' ' -f1)
	bdev=${DC1_BOOT_DEV:-$(resolve_named_part boot_a \
		"$BOOTA_MIN_SECTORS" "$BOOTA_MAX_SECTORS")} \
		|| fail "cannot resolve boot_a partition"
	bsectors=$(cat "$SYSBLOCK/$(basename "$bdev")/size" 2>/dev/null || echo 0)
	[ -n "${DC1_BOOT_DEV:-}" ] || [ "$img_bytes" -le $((bsectors * 512)) ] \
		|| fail "$BOOTIMG_NAME ($img_bytes bytes) larger than boot_a"
	for attempt in 1 2; do
		say "WRITING BOOT IMAGE TO $bdev"
		dd if="$img" of="$bdev" bs=$MIB conv=fsync 2>/dev/null \
			|| fail "boot image write failed"
		sync
		back=$(head -c "$img_bytes" "$bdev" | sha256sum | cut -d' ' -f1)
		[ "$back" = "$img_sha" ] && return 0
		say "BOOT IMAGE READ-BACK MISMATCH - RETRYING"
	done
	fail "boot_a read-back does not match $BOOTIMG_NAME after rewrite"
}

net_install() {
	answers=$1
	[ -f "$answers" ] || fail "answers file missing"

	wr_lock || fail "another install is running"

	# An unprovisioned install (DC1_SKIP_PROVISION, set by tui.sh's "set up
	# later" or the USB host's unprovisioned=1 header) has no answers to
	# validate: the first-boot Flutter onboarding provisions instead.
	if [ -z "${DC1_SKIP_PROVISION:-}" ]; then
		/etc/installer/provision.sh --validate "$answers" \
			|| fail "answers failed validation"
	fi

	mkdir -p "$NET_DIR"
	chmod 700 "$NET_DIR"

	net_fix_clock

	say "FETCHING SHA256SUMS"
	rm -f "$NET_DIR/SHA256SUMS"
	$CURL --retry 5 --retry-delay 3 -o "$NET_DIR/SHA256SUMS" \
		"$URL_BASE/SHA256SUMS" || fail "cannot fetch SHA256SUMS (no network?)"

	# Enough tmpfs for the compressed rootfs? Fail early, not at 90%.
	clen=$($CURL --retry 2 -I "$URL_BASE/$ROOTFS_NAME" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: //p' | tail -1)
	case "$clen" in *[!0-9]*|'') clen=0 ;; esac
	if [ "$clen" -gt 0 ]; then
		free_kib=$(df -k "$NET_DIR" 2>/dev/null | awk 'NR==2 { print $4 }')
		case "$free_kib" in *[!0-9]*|'') free_kib=0 ;; esac
		if [ "$free_kib" -gt 0 ] && [ $((clen / 1024 + 65536)) -gt "$free_kib" ]; then
			fail "not enough RAM for the download ($((clen / MIB)) MiB needed)"
		fi
	fi

	net_get_verified "$ROOTFS_NAME" "$NET_DIR/$ROOTFS_NAME"

	# Fetch + verify the boot image BEFORE wiping anything: if the release
	# is missing it, the device stays untouched and reinstallable.
	net_get_verified "$BOOTIMG_NAME" "$NET_DIR/$BOOTIMG_NAME"

	wr_open_target
	wr_scrub
	say "WRITING ROOT FILESYSTEM"

	# Decompress through a fifo so zstd's exit status gates the commit: a
	# truncated decompress must never look like a complete image.
	rm -f "$NET_DIR/raw.fifo" "$NET_DIR/zstd.rc"
	mkfifo "$NET_DIR/raw.fifo" || fail "mkfifo failed"
	( zstd -dc "$NET_DIR/$ROOTFS_NAME" > "$NET_DIR/raw.fifo" 2>/dev/null
	  echo $? > "$NET_DIR/zstd.rc.tmp"
	  mv "$NET_DIR/zstd.rc.tmp" "$NET_DIR/zstd.rc" ) &
	wr_receive_stream < "$NET_DIR/raw.fifo" \
		|| wr_reject "device write failed mid-stream"
	# EOF on the fifo precedes the writer's rc file by an instant; wait.
	n=0
	while [ ! -f "$NET_DIR/zstd.rc" ] && [ "$n" -lt 10 ]; do
		n=$((n + 1))
		sleep 1
	done
	[ "$(cat "$NET_DIR/zstd.rc" 2>/dev/null)" = 0 ] \
		|| wr_reject "zstd decompression failed (corrupt archive?)"
	rm -f "$NET_DIR/raw.fifo" "$NET_DIR/zstd.rc" "$NET_DIR/$ROOTFS_NAME"
	say "ROOT FILESYSTEM STREAM COMPLETE"

	wr_commit
	wr_finalize "$answers"
	rm -f "$answers"

	net_write_boot_a "$NET_DIR/$BOOTIMG_NAME"
	rm -f "$NET_DIR/$BOOTIMG_NAME"
	wr_unlock

	say "INSTALL COMPLETE ($WR_RESIZE_NOTE)
REBOOTING INTO POSTMARKETOS"
	echo "[netinstall] install complete; rebooting" > /dev/kmsg 2>/dev/null
	sleep 3
	reboot -f
}

if [ -z "${DC1_LIB:-}" ]; then
	[ $# -eq 1 ] || fail "usage: netinstall.sh ANSWERS_FILE"
	net_install "$1"
fi
