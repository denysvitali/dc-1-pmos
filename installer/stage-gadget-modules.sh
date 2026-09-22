#!/bin/sh
# Optional legacy gadget modules, in the same dependency set as src/rc.sh.
# Peripheral modules belong on the rootfs, never in the installer ramdisk.
set -eu
[ "$#" -eq 2 ] || { echo "usage: $0 MODDIR DESTDIR" >&2; exit 2; }
moddir=$1
dest=$2
[ -d "$moddir" ] || { echo "missing module tree: $moddir" >&2; exit 1; }
mkdir -p "$dest"
for name in libcomposite u_serial usb_f_acm u_ether usb_f_ecm; do
	# The production recipe emits uncompressed modules. Refuse duplicates
	# instead of choosing an arbitrary ABI from a multi-release tree.
	found=$(find "$moddir" -type f -name "$name.ko")
	[ -n "$found" ] || continue
	[ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] || {
		echo "ambiguous gadget module: $name" >&2; exit 1;
	}
	cp "$found" "$dest/$name.ko"
done
