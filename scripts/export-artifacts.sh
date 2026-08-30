#!/bin/sh
# Turn a pmbootstrap-installed root filesystem into the published artifact set.
#
# Split out of build-rootfs.sh so it can be exercised offline against a
# synthetic tree (tests/test_export_artifacts.sh). Everything here runs only
# after a ~1 hour package build, so a typo found in CI costs an hour; a typo
# found by the unit test costs a second.
#
# It writes files below OUTPUT_DIRECTORY and nothing else. No device node, no
# slot, no partition, no transport.
set -eu

usage() {
	echo "usage: $0 ROOTFS_DIR PACKAGES_DIR SOURCES_FILE OUTPUT_DIR" >&2
	exit 2
}

[ "$#" -eq 4 ] || usage
rootfs_dir=$1
packages_dir=$2
sources_file=$3
output_dir=$4

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/versions.env"

fail() { echo "artifact export failed: $*" >&2; exit 1; }

[ -d "$rootfs_dir" ] || fail "rootfs directory missing: $rootfs_dir"
[ -d "$packages_dir" ] || fail "package directory missing: $packages_dir"
[ -f "$sources_file" ] || fail "source manifest missing: $sources_file"
[ -d "$output_dir" ] || fail "output directory missing: $output_dir"
[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
	fail "output directory must be empty: $output_dir"

# pmbootstrap builds its chroots as root even when invoked as a normal user, so
# these steps have to be able to read a root-owned tree. Escalate only when the
# tree is genuinely unreadable.
as_root() {
	if [ "$(id -u)" -eq 0 ] || [ -r "$rootfs_dir/etc/os-release" ]; then
		"$@"
	elif command -v sudo >/dev/null; then
		sudo -n "$@"
	else
		fail "cannot read $rootfs_dir and no non-interactive sudo is available"
	fi
}

# Anything an escalated step created is owned by root; hand it back so the
# remaining unprivileged steps (compression, hashing) can operate on it.
reclaim_outputs() {
	[ "$(id -u)" -ne 0 ] || return 0
	find "$output_dir" ! -user "$(id -un)" -print -quit 2>/dev/null |
		grep -q . || return 0
	sudo -n chown -R "$(id -u):$(id -g)" "$output_dir"
}

magic() { od -An -v -tx1 -N"$2" "$1" | tr -d ' \n'; }

as_root python3 "$script_dir/make-rootfs-archive.py" \
	--source "$rootfs_dir" \
	--archive "$output_dir/jagar-rootfs.tar.gz" \
	--inventory "$output_dir/FILES.tsv" \
	--epoch "$SOURCE_DATE_EPOCH"

# The bootable payload. LK loads the Android boot image but ignores the DTB in
# vendor_boot; boot/dtbswap packs this kernel and our DTB into the boot image's
# kernel slot and replaces LK's signed-tree handoff at runtime. This exporter
# produces only those two inputs; release assembly builds the images later.
kernel_release_file="$rootfs_dir/usr/share/kernel/postmarketos-mediatek-mt6789/kernel.release"
[ -s "$kernel_release_file" ] || fail "kernel package recorded no kernel.release"
kernel_release=$(cat "$kernel_release_file")

mkdir "$output_dir/boot"
cp "$rootfs_dir/boot/vmlinuz" "$output_dir/boot/Image.gz"
cp "$rootfs_dir/boot/dtbs/mediatek/mt8781-daylight-jagar.dtb" \
	"$output_dir/boot/mt8781-daylight-jagar.dtb"
[ "$(magic "$output_dir/boot/Image.gz" 2)" = 1f8b ] ||
	fail "exported kernel is not gzip-compressed"
[ "$(magic "$output_dir/boot/mt8781-daylight-jagar.dtb" 4)" = d00dfeed ] ||
	fail "exported DTB has no FDT magic"

# The deliverable a user can actually write to userdata. It is a plain file
# here; writing it to a partition is a separate step done on the device by the
# installer (see the installation documentation).
ext4_result=$(as_root sh "$script_dir/make-ext4-image.sh" \
	"$rootfs_dir" "$output_dir/jagar-rootfs.ext4" jagar-root)
echo "$ext4_result"
ext4_uuid=${ext4_result##*uuid=}
case "$ext4_uuid" in
	????????-????-????-????-????????????) : ;;
	*) fail "could not read back the filesystem UUID" ;;
esac
reclaim_outputs
# Level 19 on a multi-gigabyte image costs more wall clock than the size it
# saves; 12 keeps a hosted runner honest.
zstd -q -12 -T0 --rm "$output_dir/jagar-rootfs.ext4"
[ -s "$output_dir/jagar-rootfs.ext4.zst" ] ||
	fail "ext4 image compression produced nothing"

# Publish the three packages by EXACT version, never "whatever *.apk is there".
# The local binary repository is cached between CI runs so it legitimately
# holds older builds; globbing would ship one of those and the release would
# describe a kernel it does not contain.
overlay="$script_dir/../pmaports/device/testing"
apkbuild_field() {
	awk -F= -v field="$2" '
		$1 == field { gsub(/"/, "", $2); print $2; exit }
	' "$1"
}

# Gate A: the rootfs must contain exactly the builds we are about to ship.
# pmbootstrap silently reuses an unchanged pkgver-pkgrel from cache, and
# nothing else here would notice the shipped .apk set and the installed
# database drifting apart -- the release would describe packages the image
# does not have, and dc1-update's parity report would compare against air.
installed_db="$rootfs_dir/lib/apk/db/installed"
as_root [ -s "$installed_db" ] ||
	fail "no installed package database at $installed_db"

mkdir "$output_dir/packages"
package_provenance=""
for package in mutter-mobile linux-postmarketos-mediatek-mt6789 \
	device-daylight-jagar; do
	apkbuild="$overlay/$package/APKBUILD"
	[ -f "$apkbuild" ] || fail "missing overlay APKBUILD: $apkbuild"
	pkgver=$(apkbuild_field "$apkbuild" pkgver)
	pkgrel=$(apkbuild_field "$apkbuild" pkgrel)
	[ -n "$pkgver" ] && [ -n "$pkgrel" ] ||
		fail "could not read pkgver/pkgrel for $package"
	wanted="$package-$pkgver-r$pkgrel.apk"
	built=$(find "$packages_dir" -type f -name "$wanted" -print -quit)
	[ -n "$built" ] ||
		fail "no $wanted in the local package repository (stale cache?)"
	cp -p "$built" "$output_dir/packages/$wanted"

	installed=$(as_root awk -v pkg="$package" '
		/^P:/ { p = substr($0, 3) }
		/^V:/ && p == pkg { print substr($0, 3); exit }
	' "$installed_db")
	[ -n "$installed" ] ||
		fail "package $package is not recorded in the rootfs database"
	[ "$installed" = "$pkgver-r$pkgrel" ] ||
		fail "rootfs holds $package $installed but the release ships $pkgver-r$pkgrel (stale package cache?)"
	# Space-separated: $(...) strips the trailing newline a printf-per-entry
	# would produce, so the lines are split again where they are written.
	package_provenance="$package_provenance package_$(echo "$package" | tr - _)=$installed"
done

cp "$sources_file" "$output_dir/SOURCES"
{
	echo "builder_source=$PMBOOTSTRAP_COMMIT"
	echo "pmaports_source=$PMAPORTS_COMMIT"
	echo "kernel_source=$KERNEL_COMMIT"
	echo "source_date_epoch=$SOURCE_DATE_EPOCH"
	echo "device=daylight-jagar"
	echo "architecture=aarch64"
	echo "kernel_release=$kernel_release"
	# Exact package builds this rootfs was verified (Gate A) to contain.
	for provenance_entry in $package_provenance; do
		echo "$provenance_entry"
	done
	# The identity stamped into dc1tools (dc1-debug version/info): short SHA,
	# -dirty on an unclean tree, unknown without git -- same rule as
	# installer/build.sh, computed independently so the exporter also works
	# when re-run against exported inputs.
	installer_version=$(git -C "$script_dir/.." rev-parse --short HEAD 2>/dev/null || true)
	if [ -n "$(git -C "$script_dir/.." status --porcelain 2>/dev/null)" ] &&
		[ -n "$installer_version" ]; then
		installer_version="${installer_version}-dirty"
	fi
	echo "installer_version=${installer_version:-unknown}"
	echo "rootfs_label=jagar-root"
	echo "user=dc1"
	echo "user_password=build placeholder, change on first boot"
	echo "rootfs_uuid=$ext4_uuid"
	# flash_method stays none: generic postmarketOS boot deployment does not
	# reproduce this device's proven Android v4 image, and nothing here may
	# write a partition. The rootfs image is deployable only through the
	# documented installer flow, and no artifact here is boot-proven.
	echo "flash_method=none"
	echo "boot_image_included=false"
	echo "deployable=rootfs-image-only"
	echo "hardware_verified=false"
} >"$output_dir/PROVENANCE"

# Relative paths: the manifest travels with the artifacts and must not record
# the build machine's directory layout.
(
	cd "$output_dir"
	find . -type f ! -name SHA256SUMS -exec sha256sum {} + |
		LC_ALL=C sort >SHA256SUMS
	# -c, not --check --strict: busybox coreutils have neither long option,
	# so the GNU spelling made this (and scripts/verify.sh with it) fail on
	# any Alpine host -- including the device itself, where verify.sh is the
	# obvious thing to run. --strict only guards against a malformed manifest,
	# which cannot happen here: sha256sum generated it one line earlier.
	sha256sum -c SHA256SUMS >/dev/null
) || fail "the manifest does not describe the files that were written"

echo "exported non-deployable postmarketOS artifacts to $output_dir"
