#!/bin/sh
# boot.sh -- second stage of the DC-1 SYSTEM boot initramfs, run in the
# FOREGROUND by /init (dc1-system-init). Finds and verifies the installed
# rootfs; /init does the actual switch_root (only PID 1 can).
#
# Fail-closed: this script writes NOTHING to any partition it has not
# verified. Any mismatch exits non-zero and /init drops to a rescue shell;
# only the verified jagar-root filesystem is ever written (offline resize,
# reachability-watchdog deploy).
#
# Success contract with /init: rootfs mounted at /mnt/root, device name in
# /tmp/rootdev, exit 0.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

log()  { echo "[boot] $*" > /dev/kmsg 2>/dev/null; echo "[boot] $*" > /dev/tty0 2>/dev/null; }
fail() { log "FAILED: $*"; exit 1; }

# Shared fail-closed userdata resolution (SYSBLOCK, MIN_SECTORS,
# resolve_userdata); staged at /etc/partlib.sh in this image.
. "${DC1_PARTLIB:-/etc/partlib.sh}"

# UFS probes seconds after the gadget-less kernel starts; the userdata
# partition (and its uevent) appears late. Retry the whole resolution rather
# than failing on one early ENOENT.
dev=""
n=0
while [ "$n" -lt 60 ]; do
	dev=$(resolve_userdata 2>/dev/null) && [ -b "$dev" ] && break
	dev=""
	n=$((n + 1))
	case "$n" in
		10|30|50) log "still waiting for userdata partition (${n}s)" ;;
	esac
	sleep 1
done
[ -n "$dev" ] || fail "userdata partition not found after 60s"
log "userdata resolved: $dev"

# The label is load-bearing: only the filesystem the installer wrote (and
# hash-verified) carries it. Anything else -- stock Android f2fs, a wiped
# partition, a half-install (the installer holds the superblock back until
# the hash matched) -- fails here, read-only.
blkid "$dev" 2>/dev/null | grep -q 'TYPE="ext4"' \
	|| fail "$dev is not ext4 (not installed? run the installer)"
blkid "$dev" 2>/dev/null | grep -q 'LABEL="jagar-root"' \
	|| fail "$dev is not labelled jagar-root (not our filesystem; refusing)"

# fsck -p if available. The default initramfs has only busybox (no e2fsck):
# skipping is acceptable because the filesystem was SHA-256-verified at
# install time and ext4 journals recover ordinary unclean shutdowns; stage
# e2fsck into the image to enable this. Exit codes 0 and 1 (errors
# corrected) are success; >=2 is not.
if command -v e2fsck >/dev/null 2>&1; then
	e2fsck -p "$dev"
	rc=$?
	[ "$rc" -le 1 ] || fail "e2fsck found uncorrectable errors (rc=$rc)"
	log "e2fsck clean (rc=$rc)"
else
	log "e2fsck not in initramfs; skipping fsck (ext4 journal + install-time hash verification)"
fi

# Grow the filesystem to fill userdata, OFFLINE, before it is mounted. This is
# the safe resize: the ONLINE path (EXT4_IOC_RESIZE_FS on a mounted fs)
# corrupts the extent tree on this kernel (7.2.0-rc5 mtk-ufs). It self-heals
# any install whose installer-time resize did not happen (the installer's
# wr_finalize has the same step; this is the backstop). Idempotent: on an
# already-grown fs resize2fs reports "nothing to do". Best-effort -- a failure
# leaves a valid smaller root, and the next boot retries.
if command -v resize2fs >/dev/null 2>&1; then
	# -f: the fs ships at image size and resize2fs refuses to grow it until
	# the EXT2_VALID_FS "cleanly unmounted" flag is set, which e2fsck -p
	# (preen) does NOT set and a full `e2fsck -f` does -- slowly, every boot.
	# The fs is hash-verified at install and preened above, so forcing is safe;
	# once grown, resize2fs is a no-op on subsequent boots.
	if resize2fs -f "$dev" 2>/tmp/resize.err; then
		log "resized root filesystem to fill userdata"
	else
		log "resize2fs failed: $(head -c 200 /tmp/resize.err 2>/dev/null)"
	fi
	rm -f /tmp/resize.err
else
	log "resize2fs not in initramfs; root left at image size"
fi

mkdir -p /mnt/root
mount -t ext4 "$dev" /mnt/root || fail "mount of $dev failed"
if [ ! -x /mnt/root/sbin/init ]; then
	umount /mnt/root 2>/dev/null
	fail "no executable /sbin/init in $dev"
fi

# ---------------------------------------------------------------------------
# Self-heal deploy: the reachability watchdog. jagar-boot.img is the only
# artifact fastboot can update without a running system, so the initramfs --
# not the device package -- carries the watchdog for the installed system and
# (re)deploys it on every boot. See src/system/boot-watchdog.sh; the short
# version: unreachable over every shell channel for too long => reboot into
# LK fastboot, the one state the attached host can always recover from.
#
# Best-effort by design: a deploy failure must not fail an otherwise good
# boot (the previous boot's copy, if any, still applies). /init arms its
# post-switch_root deadman only when this reports success via
# /tmp/reach-armed, so a rootfs that never got the service is never rebooted
# for missing a pat it could not have delivered.
if [ -x /mnt/root/usr/lib/systemd/systemd ] && [ -d /etc/deploy ]; then
	R=/mnt/root
	wd_ok=1
	mkdir -p "$R/usr/local/sbin" "$R/var/lib/dc1" \
	         "$R/etc/systemd/system/multi-user.target.wants" || wd_ok=0
	# A pat from the previous boot must not satisfy this boot's deadman.
	rm -f "$R/var/lib/dc1/boot-ok"
	cp /etc/deploy/dc1-boot-watchdog "$R/usr/local/sbin/dc1-boot-watchdog" \
		&& chmod 0755 "$R/usr/local/sbin/dc1-boot-watchdog" || wd_ok=0
	cp /etc/deploy/dc1-boot-watchdog.service \
		"$R/etc/systemd/system/dc1-boot-watchdog.service" || wd_ok=0
	ln -sf ../dc1-boot-watchdog.service \
		"$R/etc/systemd/system/multi-user.target.wants/dc1-boot-watchdog.service" \
		|| wd_ok=0
	# The watchdog's reboot tool comes from this image's own dc1tools -- the
	# installed rootfs may predate the device package that ships the C one.
	# ~2.5 MB, so copy only when it actually changed, and never through a
	# half-written file.
	if ! cmp -s /bin/dc1tools "$R/usr/local/sbin/dc1tools"; then
		cp /bin/dc1tools "$R/usr/local/sbin/dc1tools.new" \
			&& chmod 0755 "$R/usr/local/sbin/dc1tools.new" \
			&& mv "$R/usr/local/sbin/dc1tools.new" "$R/usr/local/sbin/dc1tools" \
			|| wd_ok=0
	fi
	ln -sf dc1tools "$R/usr/local/sbin/dc1-reboot-fastboot" || wd_ok=0
	# dc1-boot-sync used to key on the gzipped-kernel hash of the ACTIVE
	# slot, and a dtbswap payload can never match /boot/vmlinuz: the moment
	# the device got network it would download the CI image over the
	# inactive slot, arm it, and reboot. A dtbswap-aware dc1-boot-sync
	# (device pkgrel >= 44, detected by its marker string) compares the
	# UNCOMPRESSED inner kernels instead, and CI now ships mainline-DT
	# images -- so for that version the mask comes OFF. Anything older
	# stays masked. This initramfs owns the mask either way.
	if grep -q dtbswap-aware "$R/usr/libexec/dc1-boot-sync" 2>/dev/null; then
		if [ "$(readlink "$R/etc/systemd/system/dc1-boot-sync.service" 2>/dev/null)" = /dev/null ]; then
			rm -f "$R/etc/systemd/system/dc1-boot-sync.service"
			log "dc1-boot-sync is dtbswap-aware; mask lifted"
		fi
	else
		ln -sf /dev/null "$R/etc/systemd/system/dc1-boot-sync.service" || wd_ok=0
	fi
	if [ "$wd_ok" = 1 ]; then
		echo 1 > /tmp/reach-armed
		log "watchdog deployed: dc1-boot-watchdog enabled, dc1-boot-sync masked"
	else
		log "watchdog deploy INCOMPLETE; boot continues without the reachability deadman"
	fi
fi

echo "$dev" > /tmp/rootdev
log "rootfs verified on $dev; handing to PID 1 for switch_root"
exit 0
