# partlib.sh -- shared, fail-closed partition resolution.
# Sourced (not executed) by the installer's write path (writelib.sh, via
# receive.sh and netinstall.sh) and by the system initramfs' boot.sh;
# offline-testable via DC1_SYSBLOCK.
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

# resolve_named_part NAME MIN_SECTORS MAX_SECTORS -> prints the device node
# path, or returns 1 with a diagnostic on stderr. Same fail-closed rules as
# resolve_userdata (exact PARTNAME match, required unique) plus a size WINDOW:
# used by the on-device installer to find boot_a (the slot the user already
# flashed the installer to over fastboot), where both "too small" and "too
# big" mean the GPT mapping is not what we think it is.
resolve_named_part() {
	rnp_name=$1
	rnp_min=$2
	rnp_max=$3
	found=""
	count=0
	for u in "$SYSBLOCK"/*/uevent; do
		[ -f "$u" ] || continue
		grep -q "^PARTNAME=$rnp_name\$" "$u" || continue
		count=$((count + 1))
		found=$(basename "$(dirname "$u")")
	done
	[ "$count" -eq 1 ] || { echo "expected exactly 1 PARTNAME=$rnp_name, found $count" >&2; return 1; }
	[ -n "$found" ] || { echo "empty device name for $rnp_name" >&2; return 1; }
	sectors=$(cat "$SYSBLOCK/$found/size" 2>/dev/null || echo 0)
	case "$sectors" in ''|*[!0-9]*) sectors=0 ;; esac
	if [ "$sectors" -lt "$rnp_min" ] || [ "$sectors" -gt "$rnp_max" ]; then
		echo "$rnp_name ($found) is $sectors sectors, outside [$rnp_min, $rnp_max]; refusing" >&2
		return 1
	fi
	echo "/dev/$found"
}
