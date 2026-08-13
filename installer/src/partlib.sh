# partlib.sh -- shared, fail-closed userdata partition resolution.
# Sourced (not executed) by installer/src/receive.sh and by the system
# initramfs' boot.sh; offline-testable via DC1_SYSBLOCK.
#
# The DC-1's UFS exposes ~62 partitions and the initramfs has no udev, so
# there are no /dev/block/by-name links. The GPT partition name IS available:
# the kernel puts PARTNAME= into each partition's sysfs uevent. Resolving by
# that name -- required unique, required big -- is what keeps every
# boot-critical partition (preloader, lk, dtbo, vendor_boot, boot) out of
# reach by construction.

SYSBLOCK=${DC1_SYSBLOCK:-/sys/class/block}
MIN_SECTORS=67108864     # 32 GiB in 512-byte sectors: userdata is ~109 GiB,
                         # every boot-critical partition is far smaller.

# resolve_userdata -> prints the device node path, or returns 1 with a
# diagnostic on stderr.
resolve_userdata() {
	found=""
	count=0
	for u in "$SYSBLOCK"/*/uevent; do
		[ -f "$u" ] || continue
		grep -q '^PARTNAME=userdata$' "$u" || continue
		count=$((count + 1))
		found=$(basename "$(dirname "$u")")
	done
	[ "$count" -eq 1 ] || { echo "expected exactly 1 PARTNAME=userdata, found $count" >&2; return 1; }
	[ -n "$found" ] || { echo "empty device name for userdata" >&2; return 1; }
	sectors=$(cat "$SYSBLOCK/$found/size" 2>/dev/null || echo 0)
	case "$sectors" in ''|*[!0-9]*) sectors=0 ;; esac
	[ "$sectors" -ge "$MIN_SECTORS" ] || {
		echo "userdata ($found) is only $sectors sectors; refusing (mapping moved?)" >&2
		return 1
	}
	echo "/dev/$found"
}
