#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay_dir=$(CDPATH= cd -- "$script_dir/../pmaports" && pwd)
device_dir="$overlay_dir/device/testing/device-daylight-jagar"
kernel_dir="$overlay_dir/device/testing/linux-postmarketos-mediatek-mt6789"
ui_dir="$overlay_dir/device/testing/dc1-ui"

fail() {
	echo "postmarketOS packaging verification failed: $*" >&2
	exit 1
}

for file in \
	"$script_dir/versions.env" \
	"$device_dir/APKBUILD" \
	"$device_dir/deviceinfo" \
	"$kernel_dir/APKBUILD" \
	"$ui_dir/APKBUILD"; do
	[ -f "$file" ] || fail "missing $file"
done

sh -n "$script_dir/prepare.sh"
sh -n "$script_dir/build-rootfs.sh"
sh -n "$script_dir/export-artifacts.sh"
sh -n "$script_dir/make-ext4-image.sh"
sh -n "$script_dir/build-flutter-ui.sh"
sh -n "$script_dir/build-backend.sh"
sh -n "$script_dir/build-ui-payload.sh"
sh -n "$script_dir/verify-flutter-gtk.sh"
sh -n "$script_dir/verify.sh"
sh -n "$device_dir/APKBUILD"
sh -n "$kernel_dir/APKBUILD"
sh -n "$ui_dir/APKBUILD"
sh -n "$ui_dir/dc1-ui-session"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$script_dir/make-rootfs-archive.py"
python3 "$script_dir/tests/test_make_rootfs_archive.py"

(
	cd "$device_dir"
	want=$(awk '/  deviceinfo$/ { print $1 }' APKBUILD)
	actual=$(sha512sum deviceinfo | awk '{ print $1 }')
	[ "$want" = "$actual" ]
) || fail "deviceinfo checksum mismatch"

. "$script_dir/versions.env"
[ ${#PMAPORTS_COMMIT} -eq 40 ] || fail "invalid pmaports commit"
[ ${#PMBOOTSTRAP_COMMIT} -eq 40 ] || fail "invalid pmbootstrap commit"
[ ${#KERNEL_COMMIT} -eq 40 ] || fail "invalid kernel commit"

grep -qx 'deviceinfo_codename="daylight-jagar"' "$device_dir/deviceinfo" ||
	fail "wrong device codename"
grep -qx 'deviceinfo_flash_method="none"' "$device_dir/deviceinfo" ||
	fail "flash method must remain none"

for unsafe in \
	deviceinfo_generate_bootimg deviceinfo_header_version \
	deviceinfo_flash_kernel_on_update deviceinfo_flash_rootfs_partition_name \
	deviceinfo_flash_boot_partition_name deviceinfo_flash_sparse; do
	! grep -q "^$unsafe=" "$device_dir/deviceinfo" || fail "unsafe $unsafe enabled"
done

for obsolete in mtkclient 'U-Boot' mediatek-g99 deviceinfo_boot_filesystem; do
	! grep -R "$obsolete" "$device_dir" "$kernel_dir" >/dev/null ||
		fail "obsolete assumption remains in overlay: $obsolete"
done

# Wi-Fi/BT firmware must come from upstream packages, never a committed blob:
# linux-firmware-mediatek ships mediatek/WIFI_RAM_CODE_MT7902_1.bin and the
# BT/MCU patch blobs, wireless-regdb ships regulatory.db.
grep -q 'linux-firmware-mediatek' "$device_dir/APKBUILD" ||
	fail "device package no longer pulls upstream MediaTek firmware"
grep -q 'wireless-regdb' "$device_dir/APKBUILD" ||
	fail "device package no longer pulls wireless-regdb"
find "$overlay_dir" -name '*.bin' -print -quit | grep -q . &&
	fail "a firmware blob is committed in the overlay" || :

# The shipped rootfs gets the runtime Flutter embedder and nothing else of
# the toolchain: flutter-desktop pulls flutter-common, flutter-tool and
# dart-sdk, which is ~2 GB written to userdata for a build dependency. The
# exact-version pin is what makes the engine ABI claim true; details and the
# byte-level pin live in scripts/verify-flutter-gtk.sh.
grep -qF 'flutter-gtk=3.38.4-r2' "$ui_dir/APKBUILD" ||
	fail "dc1-ui no longer pins the flutter-gtk embedder exactly"
# Scoped to the depends block on purpose: the APKBUILD names these packages
# in a comment saying they must never be dependencies.
ui_depends=$(sed -n '/^depends="/,/^\t"/p' "$ui_dir/APKBUILD")
for buildonly in flutter-desktop flutter-common flutter-tool dart-sdk; do
	! printf '%s\n' "$ui_depends" | grep -q "$buildonly" ||
		fail "build-only Flutter package in the shipped package: $buildonly"
done
grep -q '^extra_packages = .*dc1-ui' "$script_dir/build-rootfs.sh" ||
	fail "the rootfs no longer installs dc1-ui"

grep -q "_commit=\"$KERNEL_COMMIT\"" "$kernel_dir/APKBUILD" ||
	fail "kernel commit drift"
grep -q 'github.com/denysvitali/$_repository/archive/$_commit.tar.gz' \
	"$kernel_dir/APKBUILD" || fail "kernel source is not the pinned GitHub archive"
grep -q 'LLVM=/usr/lib/llvm20/bin/' "$kernel_dir/APKBUILD" || fail "compiler boundary drift"
grep -q 'LD=/usr/bin/ld.lld' "$kernel_dir/APKBUILD" || fail "compiler boundary drift"

# ccache has to be routed in through CC/HOSTCC. Alpine's ccache package ships
# symlinks for cc/gcc/g++/c++/cpp and the musl triple only -- there is no clang
# symlink -- so a PATH-based setup compiles everything from scratch while
# looking cached. These assertions exist so that cannot be undone quietly.
grep -qF 'CC="ccache clang-20"' "$kernel_dir/APKBUILD" ||
	fail "kernel build no longer routes the compiler through ccache"
grep -qF 'HOSTCC="ccache clang-20"' "$kernel_dir/APKBUILD" ||
	fail "kernel build no longer routes the host compiler through ccache"
grep -qF 'CCACHE_DIR="/home/pmos/.ccache"' "$kernel_dir/APKBUILD" ||
	fail "kernel build does not pin CCACHE_DIR to pmbootstrap's cache mount"
grep -qF 'ccache saw zero compiles' "$kernel_dir/APKBUILD" ||
	fail "kernel build lost its ccache positive control"
grep -qF 'ccache' "$kernel_dir/APKBUILD" || fail "ccache is not a makedepend"

grep -q 'install --no-image' "$script_dir/build-rootfs.sh" ||
	fail "rootfs build must remain image-free"

# The scripts CI executes must contain no deployment primitive at all.
for forbidden in flasher fastboot ssh scp /dev/sd; do
	! grep -E "(^|[^A-Za-z0-9_-])$forbidden([^A-Za-z0-9_-]|$)" \
		"$script_dir/prepare.sh" "$script_dir/build-rootfs.sh" \
		"$script_dir/export-artifacts.sh" \
		"$script_dir/make-ext4-image.sh" \
		"$script_dir/build-flutter-ui.sh" \
		"$script_dir/build-ui-payload.sh" \
		"$script_dir/build-backend.sh" \
		"$script_dir/verify-flutter-gtk.sh" >/dev/null ||
		fail "builder contains forbidden deployment primitive: $forbidden"
done

# The image builder must keep the label the initramfs actually searches for,
# and the rootfs builder must ask for exactly that label.
grep -qF 'label=${3:-jagar-root}' "$script_dir/make-ext4-image.sh" ||
	fail "ext4 default label drift"
grep -qF 'export-artifacts.sh' "$script_dir/build-rootfs.sh" ||
	fail "rootfs build no longer exports artifacts"
grep -qF 'make-ext4-image.sh' "$script_dir/export-artifacts.sh" ||
	fail "export no longer produces a filesystem image"
grep -qF 'jagar-rootfs.ext4" jagar-root' "$script_dir/export-artifacts.sh" ||
	fail "rootfs image is not built with the jagar-root label"
grep -qF 'boot_image_included=false' "$script_dir/export-artifacts.sh" ||
	fail "provenance must record that no boot image is published"

sh "$script_dir/tests/test_make_ext4_image.sh"
sh "$script_dir/tests/test_export_artifacts.sh"
sh "$script_dir/tests/test_flutter_ui.sh"
sh "$script_dir/tests/test_dc1_ui_package.sh"

echo "postmarketOS packaging verification passed"
