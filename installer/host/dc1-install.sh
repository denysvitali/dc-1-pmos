#!/bin/sh
# dc1-install.sh -- host side of the DC-1 installation flow.
#
# The DC-1 has a touchscreen but no keyboard, and during installation it is
# USB-connected to this host anyway (fastboot), so all questions are asked
# HERE and applied on the device.
#
#   dc1-install.sh --rootfs jagar-rootfs.ext4.zst \
#                  [--installer-boot installer-boot.img] \
#                  [--boot-image jagar-boot.img] \
#                  [--answers FILE] [--device-ip IP] [--host-ip IP]
#
# Flow:
#   1. (--installer-boot) put the device into installation mode:
#        fastboot flash boot_a installer-boot.img && fastboot reboot
#      NOTE: tethered `fastboot boot <img>` is UNVERIFIED on this LK -- no
#      recorded evidence it works -- so the installer is flashed to boot_a
#      and the real boot image is flashed over it at the end. Without
#      --installer-boot, the device is assumed to be in installation mode
#      already.
#   2. Ask username / password / hostname / timezone / optional Wi-Fi.
#      The password is hashed HERE (crypt sha512); cleartext never leaves
#      this machine.
#   3. Wait for the installer's USB network (CDC-ECM, host-side MAC
#      02:1a:11:00:00:01), address it 172.16.42.2/24.
#   4. Stream the raw ext4 rootfs + SHA-256 + answers to the device on TCP
#      5555 (DC1-INSTALL-V1 protocol; see installer/src/receive.sh). The
#      device verifies the hash before the filesystem becomes mountable,
#      resizes, provisions, and reboots into LK fastboot.
#   5. (--boot-image) prove jagar-boot.img is a dtbswap payload (its kernel
#      slot carries OUR device tree -- a plain image would boot LK's signed
#      stock tree), fastboot-flash it to boot_a, and reboot into the
#      installed system. The --installer-boot image gets the same dtbswap
#      check before step 1: the stock tree black-screens installation mode
#      on some units (issue #1). vendor_boot is never written: LK ignores
#      its DTB (it builds the tree from its signed lk_main_dtb + dtbo), so
#      the dtbswap stub in the boot image is the only DT delivery channel.
#
# Needs: fastboot (for steps 1/5), zstd (if the rootfs is .zst), ip, nc,
# sha256sum, and one of mkpasswd / openssl / busybox for password hashing.
# Run as root, or with sudo available for the `ip` calls.

set -eu

DEVICE_IP=${DC1_DEVICE_IP:-172.16.42.1}
HOST_IP=${DC1_HOST_IP:-172.16.42.2}
HOST_MAC=02:1a:11:00:00:01
PORT=5555

msg() { echo "dc1-install: $*"; }
die() { echo "dc1-install: ERROR: $*" >&2; exit 1; }

maybe_sudo() {
	if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# --------------------------------------------------------------- validation
# Kept in functions (and side-effect free) so installer/tests can source this
# file with DC1_INSTALL_LIB=1 and exercise them offline.

valid_username() {
	case "$1" in
		root|nobody) return 1 ;;
		[a-z_]) return 0 ;;
		[a-z_][a-z0-9_-]*) [ ${#1} -le 32 ] ;;
		*) return 1 ;;
	esac
}

valid_hostname() {
	case "$1" in
		*-) return 1 ;;
		[a-z0-9]) return 0 ;;
		[a-z0-9][a-z0-9-]*) [ ${#1} -le 63 ] ;;
		*) return 1 ;;
	esac
}

valid_timezone() {
	case "$1" in
		''|*..*|/*|*/) return 1 ;;
		*[!A-Za-z0-9_+/-]*) return 1 ;;
		*) return 0 ;;
	esac
}

valid_psk() {
	[ ${#1} -ge 8 ] && [ ${#1} -le 63 ]
}

# require_dtbswap IMG -- refuse a boot image that would boot the device's
# own device tree. LK builds the kernel's tree from its SIGNED lk_main_dtb +
# dtbo, so a plain boot image silently boots the stock tree; jagar-boot.img
# must be a dtbswap payload (kernel slot = gzip([stub | our dtb | kernel
# Image]), boot/dtbswap/README.md). Same structural check the on-device
# installer and dc1-boot-sync apply before their writes -- here it runs
# BEFORE fastboot, where a refusal costs nothing.
require_dtbswap() {
	img=$1
	le32at() { od -An -tu4 -N4 -j"$1" "$img" 2>/dev/null | tr -d ' '; }
	ksz=$(le32at 8)
	case "$ksz" in ''|*[!0-9]*|0)
		die "$img: unreadable kernel size (not an Android v4 image?)" ;;
	esac
	blob=$(mktemp)
	if ! dd if="$img" bs=4096 skip=1 2>/dev/null | head -c "$ksz" \
			| gunzip -c > "$blob" 2>/dev/null; then
		rm -f "$blob"
		die "$img: kernel slot does not decompress (not a dtbswap payload)"
	fi
	doff=$(od -An -tu4 -N4 -j64 "$blob" | tr -d ' ')
	koff=$(od -An -tu4 -N4 -j72 "$blob" | tr -d ' ')
	klen=$(od -An -tu4 -N4 -j76 "$blob" | tr -d ' ')
	total=$(wc -c < "$blob")
	ok=1
	case "$doff" in ''|*[!0-9]*|0) ok=0 ;; esac
	case "$koff" in ''|*[!0-9]*)   ok=0 ;; esac
	case "$klen" in ''|*[!0-9]*|0) ok=0 ;; esac
	if [ "$ok" = 1 ]; then
		[ "$koff" -gt "$doff" ] \
			&& [ $((koff + klen)) -eq "$total" ] \
			&& [ "$(od -An -tx1 -N4 -j56 "$blob" | tr -d ' \n')" = 41524d64 ] \
			&& [ "$(od -An -tx1 -N4 -j"$doff" "$blob" | tr -d ' \n')" = d00dfeed ] \
			|| ok=0
	fi
	rm -f "$blob"
	[ "$ok" = 1 ] || die "$img is not a dtbswap payload (would boot the device's stock device tree); refusing to flash it"
}

# hash_password PASSWORD -> crypt sha512 hash on stdout
hash_password() {
	if command -v mkpasswd >/dev/null 2>&1; then
		mkpasswd -m sha-512 "$1"
	elif command -v openssl >/dev/null 2>&1; then
		openssl passwd -6 "$1"
	elif command -v busybox >/dev/null 2>&1 && \
	     busybox cryptpw --help >/dev/null 2>&1; then
		salt=$(head -c 12 /dev/urandom | base64 | tr '+/' 'ab' | head -c 16)
		busybox cryptpw -m sha512 "$1" "$salt"
	else
		return 1
	fi
}

b64_line() {
	printf '%s' "$1" | base64 | tr -d '\n'
}

# make_answers OUTFILE USER HASH HOSTNAME TZ SSID PSK
make_answers() {
	umask 077
	{
		echo "DC1_USER=$2"
		echo "DC1_PASS_HASH=$3"
		echo "DC1_HOSTNAME=$4"
		echo "DC1_TZ=$5"
		if [ -n "$6" ]; then
			echo "DC1_WIFI_SSID_B64=$(b64_line "$6")"
			echo "DC1_WIFI_PSK_B64=$(b64_line "$7")"
		else
			echo "DC1_WIFI_SSID_B64="
			echo "DC1_WIFI_PSK_B64="
		fi
	} > "$1"
	umask 022
}

# Find the host-side interface of the installer's ECM gadget by its fixed MAC.
find_usb_iface() {
	for a in /sys/class/net/*/address; do
		[ -f "$a" ] || continue
		if [ "$(cat "$a")" = "$HOST_MAC" ]; then
			basename "$(dirname "$a")"
			return 0
		fi
	done
	return 1
}

# Pick a working "send stdin, print replies" nc invocation.
run_nc() {
	if nc -h 2>&1 | grep -q -- '-N'; then
		nc -N "$DEVICE_IP" "$PORT"
	else
		nc "$DEVICE_IP" "$PORT"
	fi
}

# Library mode for offline tests: stop before any side effect.
if [ -n "${DC1_INSTALL_LIB:-}" ]; then
	return 0 2>/dev/null || exit 0
fi

# ------------------------------------------------------------------- args

ROOTFS=""
INSTALLER_BOOT=""
BOOT_IMAGE=""
ANSWERS_IN=""
SKIP_PROVISION=""
usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}
while [ $# -gt 0 ]; do
	case "$1" in
		--rootfs)              ROOTFS=${2:?}; shift 2 ;;
		--installer-boot)      INSTALLER_BOOT=${2:?}; shift 2 ;;
		--boot-image)          BOOT_IMAGE=${2:?}; shift 2 ;;
		--answers)             ANSWERS_IN=${2:?}; shift 2 ;;
		--skip-provision)      SKIP_PROVISION=1; shift ;;
		--device-ip)           DEVICE_IP=${2:?}; shift 2 ;;
		--host-ip)             HOST_IP=${2:?}; shift 2 ;;
		-h|--help)             usage ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done
[ -n "$ROOTFS" ] || usage
[ -f "$ROOTFS" ] || die "rootfs image missing: $ROOTFS"
[ -z "$INSTALLER_BOOT" ] || [ -f "$INSTALLER_BOOT" ] || \
	die "installer boot image missing: $INSTALLER_BOOT"
[ -z "$BOOT_IMAGE" ] || [ -f "$BOOT_IMAGE" ] || \
	die "boot image missing: $BOOT_IMAGE"
# Both images must be dtbswap payloads: the stock tree black-screens
# installation mode on some units (issue #1), and a plain jagar-boot.img
# would boot the stock tree on every unit. dtbswap-only, no exceptions.
[ -z "$INSTALLER_BOOT" ] || require_dtbswap "$INSTALLER_BOOT"
[ -z "$BOOT_IMAGE" ] || require_dtbswap "$BOOT_IMAGE"
command -v nc >/dev/null || die "need nc"
command -v sha256sum >/dev/null || die "need sha256sum"

TMPDIR_INSTALL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

# ------------------------------------------------------------- 1. answers
# Collected FIRST so the user is not typing against a timeout while the
# device waits. --skip-provision installs with no answers at all, so the
# system boots with no user-chosen account (auto-login as the build-time
# default user) instead of the classic host-driven prompts.

if [ -n "$SKIP_PROVISION" ]; then
	[ -z "$ANSWERS_IN" ] || die "--skip-provision and --answers are mutually exclusive"
	ANSWERS=""
	msg "unprovisioned install: no account setup (auto-login as build-time default user)"
elif [ -n "$ANSWERS_IN" ]; then
	[ -f "$ANSWERS_IN" ] || die "answers file missing: $ANSWERS_IN"
	ANSWERS="$ANSWERS_IN"
	msg "using answers from $ANSWERS_IN"
else
	printf 'Username: '
	read -r A_USER
	valid_username "$A_USER" || die "invalid username (lowercase, [a-z_][a-z0-9_-]*, max 32)"

	while :; do
		printf 'Password: '
		stty -echo; read -r A_PASS; stty echo; echo
		printf 'Password (again): '
		stty -echo; read -r A_PASS2; stty echo; echo
		[ "$A_PASS" = "$A_PASS2" ] && [ -n "$A_PASS" ] && break
		echo "Passwords empty or do not match, try again."
	done

	printf 'Hostname [dc1]: '
	read -r A_HOSTNAME
	A_HOSTNAME=${A_HOSTNAME:-dc1}
	valid_hostname "$A_HOSTNAME" || die "invalid hostname"

	printf 'Timezone [UTC]: '
	read -r A_TZ
	A_TZ=${A_TZ:-UTC}
	valid_timezone "$A_TZ" || die "invalid timezone"

	printf 'Wi-Fi SSID (empty to skip): '
	read -r A_SSID
	A_PSK=""
	if [ -n "$A_SSID" ]; then
		printf 'Wi-Fi passphrase: '
		stty -echo; read -r A_PSK; stty echo; echo
		valid_psk "$A_PSK" || die "WPA passphrase must be 8..63 characters"
	fi

	A_HASH=$(hash_password "$A_PASS") || \
		die "no password hasher found (need mkpasswd, openssl, or busybox cryptpw)"
	A_PASS=""; A_PASS2=""

	ANSWERS="$TMPDIR_INSTALL/answers"
	make_answers "$ANSWERS" "$A_USER" "$A_HASH" "$A_HOSTNAME" "$A_TZ" \
		"${A_SSID:-}" "${A_PSK:-}"
	msg "answers prepared (password stored as hash only)"
fi

# -------------------------------------------------- 2. installation mode
if [ -n "$INSTALLER_BOOT" ]; then
	command -v fastboot >/dev/null || die "need fastboot for --installer-boot"
	msg "waiting for a fastboot device (put the DC-1 in fastboot mode)..."
	while ! fastboot devices | grep -q .; do sleep 1; done
	# `fastboot boot` (tethered, no flash) is unverified on this LK; flash
	# the installer to boot_a and restore the real image in step 5.
	msg "flashing installer to boot_a"
	fastboot flash boot_a "$INSTALLER_BOOT"
	fastboot reboot
fi

# ---------------------------------------------------- 3. USB network up
msg "waiting for the installer's USB network interface (MAC $HOST_MAC)..."
IFACE=""
n=0
while [ -z "$IFACE" ]; do
	IFACE=$(find_usb_iface) || IFACE=""
	[ -n "$IFACE" ] && break
	n=$((n + 1))
	[ "$n" -le 120 ] || die "no ECM interface after 120s -- is the device in installation mode?"
	sleep 1
done
msg "found $IFACE"
maybe_sudo ip link set "$IFACE" up
ip addr show "$IFACE" | grep -q "inet $HOST_IP/" || \
	maybe_sudo ip addr add "$HOST_IP/24" dev "$IFACE"
msg "waiting for $DEVICE_IP to answer..."
n=0
while ! ping -c 1 -W 1 "$DEVICE_IP" >/dev/null 2>&1; do
	n=$((n + 1))
	[ "$n" -le 60 ] || die "device at $DEVICE_IP not reachable"
done

# -------------------------------------------------- 4. stream the image
RAW="$ROOTFS"
case "$ROOTFS" in
	*.zst)
		command -v zstd >/dev/null || die "need zstd for $ROOTFS"
		RAW="$TMPDIR_INSTALL/rootfs.ext4"
		msg "decompressing $ROOTFS (the device receives the raw image)..."
		zstd -d -o "$RAW" "$ROOTFS"
		;;
esac
SIZE=$(wc -c < "$RAW" | tr -d ' ')
msg "hashing $RAW ($SIZE bytes)..."
SHA=$(sha256sum "$RAW" | cut -d' ' -f1)
msg "sha256 $SHA"

msg "sending to $DEVICE_IP:$PORT (this takes a few minutes)..."
SESSION="$TMPDIR_INSTALL/session.log"
{
	echo "DC1-INSTALL-V1"
	echo "size=$SIZE"
	echo "sha256=$SHA"
	if [ -n "$SKIP_PROVISION" ]; then
		echo "unprovisioned=1"
	else
		echo "answers=$(base64 < "$ANSWERS" | tr -d '\n')"
	fi
	echo
	cat "$RAW"
} | run_nc | tee "$SESSION"

grep -q '^DC1-INSTALL: OK' "$SESSION" || \
	die "install did not complete -- see the device log (nc $DEVICE_IP 4444 or /dev/ttyACM0)"
msg "device reports install OK; it is rebooting into LK fastboot"

# ------------------------------------------------- 5. real boot image
if [ -n "$BOOT_IMAGE" ]; then
	command -v fastboot >/dev/null || die "need fastboot for --boot-image"

	msg "waiting for fastboot (device rebooting)..."
	n=0
	while ! fastboot devices | grep -q .; do
		n=$((n + 1))
		[ "$n" -le 120 ] || die "device did not reappear in fastboot; flash boot_a with $BOOT_IMAGE manually"
		sleep 1
	done
	msg "flashing real boot image to boot_a"
	fastboot flash boot_a "$BOOT_IMAGE"
	fastboot reboot
	msg "done -- the DC-1 is booting the installed system."
else
	msg "done -- now flash the real boot image over the installer:"
	msg "    fastboot flash boot_a jagar-boot.img"
	msg "    fastboot reboot"
	msg ""
	msg "The boot image carries our device tree via the dtbswap stub in its"
	msg "kernel slot. vendor_boot is never written: LK ignores its DTB, so"
	msg "flashing it cannot change the tree the kernel boots with."
fi
