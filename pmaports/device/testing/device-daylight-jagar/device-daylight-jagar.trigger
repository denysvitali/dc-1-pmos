#!/bin/sh
# apk trigger. Two watch sets share this script; apk passes the paths that
# changed. Dispatch so a wireplumber upgrade cannot fire the kernel
# boot-image deploy.
#
# Kernel paths (/boot/vmlinuz, /usr/share/kernel/*): deploy the matching
# boot image to the inactive A/B slot and arm it. Best-effort -- a failure
# here (no network, download error) must not break the apk transaction;
# the boot-time dc1-boot-sync oneshot retries on the next boot.
#
# WirePlumber alsa.lua: re-apply the Dummy Output tostring() guard. A
# wireplumber upgrade restores the upstream script, which concatenates a
# nil node.name on adapter bind failure and takes the ALSA monitor down.
set -u

libexec="${DC1_LIBEXEC:-/usr/libexec}"

kernel=0
wireplumber=0
for path in "$@"; do
	case "$path" in
		/boot/vmlinuz*|/usr/share/kernel/*) kernel=1 ;;
		*/alsa.lua|/usr/share/wireplumber/scripts/monitors/*) wireplumber=1 ;;
	esac
done

# apk has historically invoked this trigger with no args on a kernel
# upgrade. Keep that as a kernel deploy so we cannot silently drop the
# A/B arming path.
if [ $# -eq 0 ]; then
	kernel=1
fi

if [ "$wireplumber" -eq 1 ]; then
	"$libexec/dc1-fix-wireplumber-alsa" || true
fi
if [ "$kernel" -eq 1 ]; then
	exec "$libexec/dc1-boot-sync" --deploy
fi
exit 0
