#!/bin/sh
# Build a jagar-root ext4 filesystem IMAGE FILE from a populated rootfs
# directory.
#
# This writes a regular file and nothing else. It does not resolve a device
# node, select or arm a slot, or write a partition. Deployment of the produced
# file is a separate step done on the device by the installer.
#
# The label matters: the boot initramfs mounts the persistent root by scanning
# for LABEL="jagar-root", so an image with any other label boots to the
# recovery shell instead of userspace.
set -eu

usage() {
	echo "usage: $0 SOURCE_DIRECTORY OUTPUT_IMAGE [LABEL]" >&2
	exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
source_dir=$1
output_image=$2
label=${3:-jagar-root}

fail() { echo "ext4 image build failed: $*" >&2; exit 1; }

# Fail closed on anything that is not a plain file below the current tree.
case "$output_image" in
	/dev/*|/proc/*|/sys/*) fail "refusing non-file output target: $output_image" ;;
esac
[ ! -b "$output_image" ] || fail "refusing block-device output: $output_image"
[ ! -e "$output_image" ] || fail "output already exists: $output_image"
[ -d "$source_dir" ] || fail "source directory missing: $source_dir"
[ -x "$source_dir/sbin/init" ] || fail "source is not a populated root: no /sbin/init"
[ -s "$source_dir/etc/os-release" ] || fail "source has no /etc/os-release"
[ ${#label} -le 16 ] || fail "ext4 label longer than 16 bytes: $label"

for tool in mkfs.ext4 e2fsck dumpe2fs du; do
	command -v "$tool" >/dev/null || fail "missing required tool: $tool"
done

# Size: content plus 40% slack, floored at 1536 MiB. The image is deliberately
# much smaller than the ~109 GiB userdata partition it is written to; the
# documented deployment step grows the filesystem with resize2fs afterwards.
content_kib=$(du -sk "$source_dir" | awk '{ print $1 }')
case "$content_kib" in
	""|*[!0-9]*) fail "could not measure source size" ;;
esac
size_mib=$(( content_kib * 140 / 100 / 1024 ))
[ "$size_mib" -ge 1536 ] || size_mib=1536
if [ -n "${PMOS_EXT4_SIZE_MIB:-}" ]; then
	case "$PMOS_EXT4_SIZE_MIB" in
		""|*[!0-9]*) fail "PMOS_EXT4_SIZE_MIB must be an integer" ;;
	esac
	size_mib=$PMOS_EXT4_SIZE_MIB
fi

# A deterministic UUID keeps two builds of the same inputs comparable. Byte
# identity is NOT claimed: mkfs.ext4 still records its own metadata layout.
if [ -n "${PMOS_EXT4_UUID:-}" ]; then
	uuid=$PMOS_EXT4_UUID
else
	seed=$(printf '%s:%s:%s' "$label" "${SOURCE_DATE_EPOCH:-0}" "$size_mib" |
		sha256sum | cut -c1-32)
	uuid=$(printf '%s-%s-%s-%s-%s' \
		"$(echo "$seed" | cut -c1-8)" "$(echo "$seed" | cut -c9-12)" \
		"$(echo "$seed" | cut -c13-16)" "$(echo "$seed" | cut -c17-20)" \
		"$(echo "$seed" | cut -c21-32)")
fi

staging="$output_image.staging"
rm -f "$staging"
mkfs.ext4 -q -F \
	-L "$label" \
	-U "$uuid" \
	-d "$source_dir" \
	-m 1 \
	-E root_owner=0:0,hash_seed="$uuid" \
	"$staging" "${size_mib}M" || fail "mkfs.ext4 failed"

e2fsck -fn "$staging" >/dev/null || fail "produced filesystem is not clean"

read_label=$(dumpe2fs -h "$staging" 2>/dev/null |
	awk -F':[ \t]*' '/^Filesystem volume name:/ { print $2 }')
[ "$read_label" = "$label" ] ||
	fail "readback label mismatch: got '$read_label', want '$label'"
read_uuid=$(dumpe2fs -h "$staging" 2>/dev/null |
	awk -F':[ \t]*' '/^Filesystem UUID:/ { print $2 }')
[ "$read_uuid" = "$uuid" ] ||
	fail "readback UUID mismatch: got '$read_uuid', want '$uuid'"

# The initramfs refuses to switch_root without an executable /sbin/init, so
# assert it survived the copy rather than trusting mkfs's exit code.
if command -v debugfs >/dev/null; then
	debugfs -R "stat /sbin/init" "$staging" 2>/dev/null |
		grep -q 'Inode:' || fail "/sbin/init missing from the built filesystem"
fi

mv "$staging" "$output_image"
echo "wrote $output_image: ${size_mib} MiB, label=$label, uuid=$uuid"
