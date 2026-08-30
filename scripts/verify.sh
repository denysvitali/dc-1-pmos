#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay_dir=$(CDPATH= cd -- "$script_dir/../pmaports" && pwd)
device_dir="$overlay_dir/device/testing/device-daylight-jagar"
kernel_dir="$overlay_dir/device/testing/linux-postmarketos-mediatek-mt6789"
mutter_dir="$overlay_dir/device/testing/mutter-mobile"

fail() {
	echo "postmarketOS packaging verification failed: $*" >&2
	exit 1
}

for file in \
	"$script_dir/versions.env" \
	"$device_dir/APKBUILD" \
	"$device_dir/deviceinfo" \
	"$kernel_dir/APKBUILD" \
	"$mutter_dir/APKBUILD"; do
	[ -f "$file" ] || fail "missing $file"
done

sh -n "$script_dir/prepare.sh"
sh -n "$script_dir/build-rootfs.sh"
sh -n "$script_dir/export-artifacts.sh"
sh -n "$script_dir/check-release-version-identity.sh"
sh -n "$script_dir/restore-local-apk-key.sh"
sh -n "$script_dir/sign-apkindex.sh"
sh -n "$script_dir/make-ext4-image.sh"
sh -n "$script_dir/prefetch-kernel-distfile.sh"
sh -n "$script_dir/verify.sh"
sh -n "$script_dir/../boot/repack-boot.sh"
sh -n "$script_dir/../boot/dtbswap/pack.sh"
sh -n "$script_dir/tests/test_repack_boot.sh"
sh -n "$script_dir/tests/test_prepare_safety.sh"
sh -n "$script_dir/tests/test_sign_apkindex.sh"
sh -n "$script_dir/tests/test_restore_local_apk_key.sh"
sh -n "$device_dir/APKBUILD"
sh -n "$kernel_dir/APKBUILD"
sh -n "$mutter_dir/APKBUILD"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$script_dir/make-rootfs-archive.py"
python3 "$script_dir/tests/test_make_rootfs_archive.py"
# The apk version comparator backs the staleness gates below; its semantics
# were transcribed from the apk-tools the devices actually run, so its test
# suite rides the same verify pass.
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$script_dir/apk_version_compare.py"
python3 "$script_dir/tests/test_apk_version_compare.py"
python3 "$script_dir/tests/test_verify_kernel_artifacts.py"

(
	cd "$device_dir"
	want=$(awk '/  deviceinfo$/ { print $1 }' APKBUILD)
	actual=$(sha512sum deviceinfo | awk '{ print $1 }')
	[ "$want" = "$actual" ]
) || fail "deviceinfo checksum mismatch"

# abuild's default_fetch() pairs $source with $sha512sums POSITIONALLY:
# source[i] is checked against checksum[i]. The two lists must be in the
# same order -- a filename moved in one but not the other silently compares
# every following file against the wrong hash (a multi-CI-cycle failure).
# Source both lists exactly as abuild does and assert the pairing, then hash
# every local file against its paired checksum.
for dir in "$device_dir" "$kernel_dir" "$mutter_dir"; do
	(
		cd "$dir" || exit 1
		startdir=$(pwd)
		srcdir="$startdir/src"
		# shellcheck disable=SC1090,SC1091
		. ./APKBUILD
		set -- $sha512sums
		[ $# -eq $(( $(set -- $source; echo $#) * 2 )) ] ||
			fail "$dir: source/checksum count mismatch"
		for src in $source; do
			hash=$1; file=$2; shift 2
			name=${src%%::*}
			name=${name##*/}
			[ "$name" = "$file" ] ||
				fail "$dir: '$name' is not paired with its own checksum '$file' (lists out of order?)"
			case "$src" in
				*::http://*|*::https://*|*::ftp://*|http://*|https://*|ftp://*)
					: remote source, nothing local to hash ;;
				*)
					echo "$hash  $name" | sha512sum -c >/dev/null 2>&1 ||
						fail "$dir: $name checksum mismatch" ;;
			esac
		done
	)
done

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

# This board has no modem. Keep generic desktop components from probing the
# condition-skipped ModemManager, and keep LocalSearch's Landlock sandbox
# usable with Alpine's usr-merged musl loader paths.
grep -qF 'bluez5.hfphsp-backend-native-modem = "none"' \
	"$device_dir/55-dc1-audio.conf" || fail "WirePlumber still probes ModemManager"
grep -qF 'Environment=LD_LIBRARY_PATH=/usr/lib:/usr/local/lib' \
	"$device_dir/10-dc1-localsearch.conf" || fail "LocalSearch loader path guard missing"
grep -qF '/usr/lib/systemd/user/localsearch-3.service.d/10-dc1-landlock.conf' \
	"$device_dir/APKBUILD" || fail "LocalSearch user-unit drop-in is not packaged"

grep -q "_commit=\"$KERNEL_COMMIT\"" "$kernel_dir/APKBUILD" ||
	fail "kernel commit drift"
grep -q 'github.com/denysvitali/$_repository/archive/$_commit.tar.gz' \
	"$kernel_dir/APKBUILD" || fail "kernel source is not the pinned GitHub archive"
grep -q 'LLVM=/usr/lib/llvm20/bin/' "$kernel_dir/APKBUILD" || fail "compiler boundary drift"
grep -q 'LD=/usr/bin/ld.lld' "$kernel_dir/APKBUILD" || fail "compiler boundary drift"
grep -qx "pkgver=$KERNEL_VERSION" "$kernel_dir/APKBUILD" ||
	fail "KERNEL_VERSION in versions.env does not match the kernel APKBUILD pkgver"

# The committed AVB0 boot-signature page is vendor-derived with recorded
# provenance (boot/README.md). Pin its size and hash so a different
# 4096-byte AVB0-looking page cannot be swapped in silently.
sig="$script_dir/../boot/boot-signature.bin"
[ "$(stat -c%s "$sig")" = "4096" ] || fail "boot-signature.bin is not 4096 bytes"
[ "$(sha256sum "$sig" | awk '{ print $1 }')" = \
	"403d35c3dfd74f04d0c3e20b17f4031b3cbedb7de656b44ceb70b90580dd8009" ] ||
	fail "boot-signature.bin hash drifted from the recorded provenance"

# ccache has to be routed in through CC/HOSTCC. Alpine's ccache package ships
# symlinks for cc/gcc/g++/c++/cpp and the musl triple only -- there is no clang
# symlink -- so a PATH-based setup compiles everything from scratch while
# looking cached. These assertions exist so that cannot be undone quietly.
grep -qF 'CC="ccache clang-20"' "$kernel_dir/APKBUILD" ||
	fail "kernel build no longer routes the compiler through ccache"
grep -qF 'HOSTCC="ccache clang-20"' "$kernel_dir/APKBUILD" ||
	fail "kernel build no longer routes the host compiler through ccache"
grep -qF 'HOSTLD=/usr/bin/ld.lld' "$kernel_dir/APKBUILD" ||
	fail "kernel host linker boundary drift"
grep -qF 'HOSTCC="gcc"' "$kernel_dir/APKBUILD" ||
	fail "DTB host compiler workaround drift"
grep -qF -- '-j1 dtbs' "$kernel_dir/APKBUILD" ||
	fail "DTB build is no longer serial"
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
		"$script_dir/make-ext4-image.sh" >/dev/null ||
		fail "builder contains forbidden deployment primitive: $forbidden"
done

# The image builder must keep the label the initramfs actually searches for,
# and the rootfs builder must ask for exactly that label.
grep -qF 'label=${3:-jagar-root}' "$script_dir/make-ext4-image.sh" ||
	fail "ext4 default label drift"
grep -qF 'export-artifacts.sh' "$script_dir/build-rootfs.sh" ||
	fail "rootfs build no longer exports artifacts"
grep -qF 'DC1_SOURCE_VERSION="${DC1_SOURCE_VERSION:-}"' \
	"$script_dir/build-rootfs.sh" ||
	fail "rootfs export loses the explicit source identity across sudo"
grep -qF 'make-ext4-image.sh' "$script_dir/export-artifacts.sh" ||
	fail "export no longer produces a filesystem image"
grep -qF 'jagar-rootfs.ext4" jagar-root' "$script_dir/export-artifacts.sh" ||
	fail "rootfs image is not built with the jagar-root label"
grep -qF 'boot_image_included=false' "$script_dir/export-artifacts.sh" ||
	fail "provenance must record that no boot image is published"
grep -qF 'touch -h -d "@$SOURCE_DATE_EPOCH"' "$script_dir/../installer/build.sh" ||
	fail "initramfs staging mtimes are not normalized"
grep -qF -- '--renumber-inodes' "$script_dir/../installer/build.sh" ||
	fail "initramfs cpio inode allocation is not reproducible"

# GPU floor must stay in dc1-gpu-freq, not a hardcoded udev ATTR, or the
# Settings panel and the boot path drift.
grep -q 'RUN+="/usr/libexec/dc1-gpu-freq apply"' 	"$device_dir/90-device-daylight-jagar.rules" ||
	fail "udev no longer applies GPU limits through dc1-gpu-freq"
grep -E 'ATTR\{min_freq\}' "$device_dir/90-device-daylight-jagar.rules" &&
	fail "udev hardcodes GPU min_freq again" || :

sh -n "$device_dir/dc1-fix-wireplumber-alsa"
sh -n "$device_dir/dc1-gpu-freq"
sh -n "$device_dir/dc1-charging-generator"
sh -n "$device_dir/dc1-charging-monitor"
sh -n "$device_dir/dc1-poweroff-flag"
sh -n "$device_dir/dc1-battery-state"
sh -n "$device_dir/dc1-audio"
sh -n "$device_dir/dc1-bluetooth"
sh -n "$device_dir/dc1-boot-sync"
sh -n "$device_dir/dc1-debug-shell"
sh -n "$device_dir/dc1-display-gate"
sh -n "$device_dir/dc1-first-boot"
sh -n "$device_dir/dc1-frontlight"
sh -n "$device_dir/dc1-gpu"
sh -n "$device_dir/dc1-link-apk-keys"
sh -n "$device_dir/dc1-owner-settings"
sh -n "$device_dir/dc1-screen-backlight"
sh -n "$device_dir/dc1-update"
sh -n "$device_dir/dc1-usb-gadget"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' 	"$device_dir/dc1-gpu-settings"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' 	"$device_dir/dc1-charging-settings"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' 	"$device_dir/dc1-orientation"
sh -n "$device_dir/device-daylight-jagar.trigger"
sh -n "$device_dir/device-daylight-jagar.post-install"
sh -n "$device_dir/device-daylight-jagar.post-upgrade"
sh "$script_dir/tests/test_dc1_fix_wireplumber_alsa.sh"
sh "$script_dir/tests/test_repack_boot.sh"
sh "$script_dir/tests/test_make_ext4_image.sh"
sh "$script_dir/tests/test_export_artifacts.sh"
sh "$script_dir/tests/test_prefetch_kernel_distfile.sh"
sh "$script_dir/tests/test_prepare_safety.sh"
sh "$script_dir/tests/test_release_version_identity.sh"
sh "$script_dir/tests/test_restore_local_apk_key.sh"
sh "$script_dir/tests/test_sign_apkindex.sh"

# LK ignores vendor_boot's DTB; keep the exporter aligned with the dtbswap
# delivery path so stale comments do not revive an unsafe flash recipe.
! grep -qF 'DTB from vendor_boot' "$script_dir/export-artifacts.sh" ||
	fail "exporter still claims vendor_boot supplies the device tree"

echo "postmarketOS packaging verification passed"
