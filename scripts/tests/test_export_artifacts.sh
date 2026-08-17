#!/bin/sh
# Exercise export-artifacts.sh against a synthetic installed root filesystem.
#
# The real inputs take an hour of package building to produce, so this test
# stands in for them: it is the only thing between a typo in the export stage
# and an hour of CI followed by a red job.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exporter="$here/../export-artifacts.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "export-artifacts test failed: $*" >&2; exit 1; }

# A synthetic rootfs with the exact paths the exporter reads.
root="$tmp/rootfs"
mkdir -p "$root/sbin" "$root/etc" "$root/boot/dtbs/mediatek" \
	"$root/usr/share/kernel/postmarketos-mediatek-mt6789"
printf '#!/bin/sh\n' >"$root/sbin/init"
chmod 0755 "$root/sbin/init"
printf 'ID=postmarketos\n' >"$root/etc/os-release"
printf 'synthetic kernel\n' | gzip -n >"$root/boot/vmlinuz"
# An FDT magic header is all the exporter checks; a real DTB is not needed.
printf '\320\015\376\355synthetic device tree\n' \
	>"$root/boot/dtbs/mediatek/mt8781-daylight-jagar.dtb"
printf '7.2.0-rc5-postmarketos-mediatek-mt6789\n' \
	>"$root/usr/share/kernel/postmarketos-mediatek-mt6789/kernel.release"

packages="$tmp/packages/aarch64"
mkdir -p "$packages"
# Names must match the overlay APKBUILDs exactly; the exporter selects by
# version rather than globbing, so a stale build in the same directory must be
# ignored rather than published.
overlay="$here/../../pmaports/device/testing"
kernel_ver=$(awk -F= '$1=="pkgver" { print $2; exit }' \
	"$overlay/linux-postmarketos-mediatek-mt6789/APKBUILD")
kernel_rel=$(awk -F= '$1=="pkgrel" { print $2; exit }' \
	"$overlay/linux-postmarketos-mediatek-mt6789/APKBUILD")
device_ver=$(awk -F= '$1=="pkgver" { print $2; exit }' \
	"$overlay/device-daylight-jagar/APKBUILD")
device_rel=$(awk -F= '$1=="pkgrel" { print $2; exit }' \
	"$overlay/device-daylight-jagar/APKBUILD")
kernel_apk="linux-postmarketos-mediatek-mt6789-$kernel_ver-r$kernel_rel.apk"
device_apk="device-daylight-jagar-$device_ver-r$device_rel.apk"
printf 'fake\n' >"$packages/$kernel_apk"
printf 'fake\n' >"$packages/$device_apk"
printf 'stale\n' >"$packages/linux-postmarketos-mediatek-mt6789-0.1_git1-r0.apk"
printf 'pinned upstream sources\n' >"$tmp/SOURCES"

out="$tmp/out"
mkdir "$out"
PMOS_EXT4_SIZE_MIB=32 sh "$exporter" "$root" "$tmp/packages" "$tmp/SOURCES" \
	"$out" >"$tmp/log" 2>&1 || { cat "$tmp/log" >&2; fail "export refused a valid tree"; }

for f in jagar-rootfs.tar.gz jagar-rootfs.ext4.zst FILES.tsv SOURCES \
	PROVENANCE SHA256SUMS boot/Image.gz \
	boot/mt8781-daylight-jagar.dtb \
	"packages/$kernel_apk" "packages/$device_apk"; do
	[ -s "$out/$f" ] || fail "missing or empty output: $f"
done
[ ! -e "$out/jagar-rootfs.ext4" ] || fail "uncompressed image was left behind"

zstd -t "$out/jagar-rootfs.ext4.zst" >/dev/null 2>&1 ||
	fail "published filesystem image does not decompress"
# -c, not --check --strict: busybox has neither long option, so this test
# could not run on an Alpine host. See export-artifacts.sh.
(cd "$out" && sha256sum -c SHA256SUMS >/dev/null) ||
	fail "SHA256SUMS does not describe the published files"

for line in flash_method=none boot_image_included=false \
	hardware_verified=false rootfs_label=jagar-root \
	deployable=rootfs-image-only device=daylight-jagar \
	kernel_release=7.2.0-rc5-postmarketos-mediatek-mt6789; do
	grep -qx "$line" "$out/PROVENANCE" || fail "PROVENANCE lacks $line"
done
grep -qE '^rootfs_uuid=[0-9a-f]{8}-' "$out/PROVENANCE" ||
	fail "PROVENANCE lacks a filesystem UUID"

# Refusals: a non-empty output directory, a kernel that is not a kernel, and a
# missing device package must each stop the export rather than publish.
[ ! -e "$out/packages/linux-postmarketos-mediatek-mt6789-0.1_git1-r0.apk" ] ||
	fail "export published a stale package from the cached repository"

! sh "$exporter" "$root" "$tmp/packages" "$tmp/SOURCES" "$out" >/dev/null 2>&1 ||
	fail "export reused a populated output directory"

broken="$tmp/rootfs-broken"
cp -a "$root" "$broken"
printf 'not gzip\n' >"$broken/boot/vmlinuz"
mkdir "$tmp/out-broken"
! PMOS_EXT4_SIZE_MIB=32 sh "$exporter" "$broken" "$tmp/packages" \
	"$tmp/SOURCES" "$tmp/out-broken" >/dev/null 2>&1 ||
	fail "export published a kernel that is not gzip-compressed"

mkdir -p "$tmp/packages-partial"
cp "$packages/$kernel_apk" "$tmp/packages-partial/"
mkdir "$tmp/out-partial"
! PMOS_EXT4_SIZE_MIB=32 sh "$exporter" "$root" "$tmp/packages-partial" \
	"$tmp/SOURCES" "$tmp/out-partial" >/dev/null 2>&1 ||
	fail "export published a set with no device package"

echo "export-artifacts tests passed"
