#!/bin/sh
# Build BOTH DC-1 initramfs images:
#   installer  -- "installation mode" (on-device touch installer with Wi-Fi
#                 network install, plus USB gadget net + installd as the
#                 fallback), flashed temporarily to boot_a during installation
#   system     -- the boot initramfs inside jagar-boot.img: verify the
#                 installed jagar-root filesystem and switch_root into it
#
#   ./build.sh                          -> out/installer-initramfs.cpio.{gz,lz4}
#                                          out/system-initramfs.cpio.{gz,lz4}
#   KERNEL_IMAGE=path/Image.gz KERNEL_DTB=path/jagar.dtb ./build.sh
#                                       -> also out/installer-boot.img and
#                                          out/jagar-boot.img via
#                                          ../boot/repack-boot.sh; BOTH kernel
#                                          slots are the ../boot/dtbswap
#                                          payload (mainline device tree --
#                                          there is no stock-DT image path,
#                                          KERNEL_DTB is required)
#   MODDIR=/path/to/modules ./build.sh  -> stage flat .ko files into the
#                                          installer image's /lib/modules
#                                          (gadget stack, if modular)
#
# Run as root (or under fakeroot): the cpio needs real device nodes.
# Needs network on the first run: firmware and Alpine packages are fetched
# at BUILD time (cached under dl/, pinned below, never committed).
#
# The installer image is SECRET-FREE:
#   * no wifi.conf, no authorized_keys, no keys of any kind. Wi-Fi
#     credentials are collected at INSTALL time on the device itself and
#     provisioned into the installed rootfs.
#   * the MT7902 firmware + regulatory.db ARE included (the on-device
#     installer downloads the rootfs over Wi-Fi), but they come from
#     upstream linux-firmware / wireless-regdb only, pinned by exact size
#     and SHA-256. The stock Android blobs have the same file names and
#     even pass the legacy firmware handshake, then fail mainline mt76's
#     UNI commands -- a same-named file with the wrong hash FAILS the build.
#   * userland beyond busybox (curl, zstd, wpa_supplicant + libraries, the
#     musl loader) is extracted from Alpine edge apks pinned by exact
#     version and SHA-256 below. These are public binaries fetched from the
#     official mirror; a replaced file under the same version fails closed.
#
# Facts this build depends on (measured during bring-up; see also the
# comments in src/init.c):
#   * ramdisk_execute_command defaults to "/init" and the kernel SILENTLY
#     falls back to prepare_namespace() if it is not executable. Hence 0755.
#   * console_on_rootfs() opens /dev/console from the *cpio* before /init
#     runs; without the node there is no fd 0/1/2.
#   * devtmpfs is NOT auto-mounted on an initramfs boot; /init mounts it.
#   * the boot chain requires a LEGACY-frame LZ4 cpio (magic 02 21 4c 18).
#     The lz4 CLI default is the modern frame, which the kernel's initramfs
#     path rejects when concatenated after a legacy vendor ramdisk. lz4 -l.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/src"
OUT="$HERE/out"
ROOT="$HERE/root"
DL="$HERE/dl"
CC=${CC:-gcc}
STRIP=${STRIP:-strip}
MODDIR=${MODDIR:-}
KERNEL_IMAGE=${KERNEL_IMAGE:-}
. "$HERE/../scripts/versions.env"

fatal() {
	echo "FATAL: $*" >&2
	exit 1
}

command -v "$CC" >/dev/null || fatal "no compiler: $CC"
command -v lz4 >/dev/null || fatal "need lz4 (legacy-frame ramdisk is mandatory)"
command -v cpio >/dev/null || fatal "need cpio"
command -v curl >/dev/null || fatal "need curl (build-time downloads)"
command -v xz >/dev/null || fatal "need xz (wireless-regdb tarball)"

# --------------------------------------------------------------- 0. downloads
# Everything fetched here is public, upstream, and verified before use.
# dl/ is a cache (gitignored); delete it to force a re-download.

# MT7902 firmware pins: the linux-firmware blobs proven on this device.
LINUX_FIRMWARE_TAG=20260622
LINUX_FIRMWARE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
WIFI_RAM_NAME="WIFI_RAM_CODE_MT7902_1.bin"
WIFI_RAM_SIZE=716944
WIFI_RAM_SHA256=b5958ac72c71fb8405e080f52d378d02b484812b9f1010c8843727056bbfc998
WIFI_PATCH_NAME="WIFI_MT7902_patch_mcu_1_1_hdr.bin"
WIFI_PATCH_SIZE=119328
WIFI_PATCH_SHA256=d73ba9e982f781221a2b9f10c42031f20a9dce046929fc0d55c791a417efe30a
# The Bluetooth half of the same chip. btmtksdio requests this one at
# t=1.75 s -- earlier than mt7921s asks for its pair, and unlike mt7921s it
# makes exactly one attempt -- so it only ever loads if it is already in the
# initramfs (see the system-initramfs staging below).
BT_RAM_NAME="BT_RAM_CODE_MT7902_1_1_hdr.bin"
BT_RAM_SIZE=509320
BT_RAM_SHA256=4f53b5e02fbd933172e18caf952bda410a877eaad00561781528cb4aff58dc38

# Signed regulatory database pair: official wireless-regdb 2026.05.30
# release (CONFIG_CFG80211_REQUIRE_SIGNED_REGDB -- never stage half a pair).
REGDB_VERSION=2026.05.30
REGDB_URL="https://mirrors.edge.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-$REGDB_VERSION.tar.xz"
REGDB_SIZE=6380
REGDB_SHA256=2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b
REGDB_SIG_SIZE=1085
REGDB_SIG_SHA256=c941c08f51c93e46722293b85631604c3740d86c3de0c75f79aef50d2e919179

# Alpine edge/main aarch64 packages, pinned by exact version AND content hash
# (resolved 2026-08-30). A filename is not a content pin: mirrors may replace
# bytes under one version, and dl/ is a persistent cache. Every cached or newly
# downloaded APK is therefore verified before extraction.
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64"
ALPINE_APKS="
busybox-static-1.38.0-r4
musl-1.2.6-r2
curl-8.21.0-r0
libcurl-8.21.0-r0
ca-certificates-bundle-20260611-r0
brotli-libs-1.2.0-r1
c-ares-1.34.8-r0
libcrypto3-3.5.7-r0
libssl3-3.5.7-r0
libidn2-2.3.8-r0
libunistring-1.4.2-r0
nghttp2-libs-1.70.0-r0
libpsl-0.21.5-r3
zlib-1.3.2-r0
zstd-1.5.7-r2
zstd-libs-1.5.7-r2
libgcc-15.2.0-r9
libstdc++-15.2.0-r9
wpa_supplicant-2.11-r4
dbus-libs-1.16.2-r2
libnl3-3.11.0-r0
pcsc-lite-libs-2.5.1-r0
dropbear-2026.94-r0
utmps-libs-0.1.3.4-r0
skalibs-libs-2.15.1.0-r0
e2fsprogs-1.47.4-r0
e2fsprogs-extra-1.47.4-r0
e2fsprogs-libs-1.47.4-r0
libcom_err-1.47.4-r0
libblkid-2.42.2-r1
libuuid-2.42.2-r1
libeconf-0.8.4-r0
"
ALPINE_APK_SHA256S="
652bfd6acbc073a6a6ae9defe6e490fc80bcd107a820ee40db75aefb98439cb6 busybox-static-1.38.0-r4
c6e74d765f7029fdc4389340181616eb834a6e692b16144c0ca8f8d0662578b3 musl-1.2.6-r2
e1f53173f2ee16013e8b88cea2f57e6c6c9e35b9ae02dd5cc36802f9ce7998dc curl-8.21.0-r0
44c388db3ab087d81b093dcab9dff6444d8aade5f9210bc7c0bc3270f6bd037a libcurl-8.21.0-r0
b6263f8453b37537725a17bdfdcecdf7f6cd016b3421d3238e36f1005776e332 ca-certificates-bundle-20260611-r0
1d355054e19b7dd843d225c878a8e92b205270f4f7c89fb218151d21c9ae87e0 brotli-libs-1.2.0-r1
b16ca578a8718851e2d3068120c0e60753a66f2df1fe44c530198b3ef5882b67 c-ares-1.34.8-r0
0b101a0db4509872143cc46f9bf7d27f1a484c7f935f31e957630d20026958cd libcrypto3-3.5.7-r0
1269473ad8e7c09f00c164efb761840eaef348b4b3f39f242f6cd4155b049086 libssl3-3.5.7-r0
3c6f9af20e672e880e2d719445750ad5ba41dceb53158fef9f256f17dc828f09 libidn2-2.3.8-r0
2c2a871d7cf19eae35e3a6a57d74fd194bd3d68742d78d7b54b698f62fcdde0e libunistring-1.4.2-r0
a552fb542888b300e353c960be884d448e789e8fb96be5e12873f0102540c363 nghttp2-libs-1.70.0-r0
6758fc2b54987b260855e95ede93e7a5aefdf5955a5915aba25ea172fbc301ca libpsl-0.21.5-r3
1d354ed1ef4e7bd9f6459b56a5e0d5c81ec78788d165b6a459f0b41ff3f4c037 zlib-1.3.2-r0
5ddea5d959e1ec4464042fa6c58bf10cfaf9212d634a7540d7c4f96251ccbd1d zstd-1.5.7-r2
67f0803cc07bad0dd866d21fdaca1fa742b541a4e5e96e0159bd8b0054d348ac zstd-libs-1.5.7-r2
23653103b2adf85dab73e4e35047f64b8671cd654e2d0291f44bec549084afd1 libgcc-15.2.0-r9
36e8a2cee1ee14df5180c1f5737f0ffb59004ef92dd4f0bedff425968c4855ae libstdc++-15.2.0-r9
7060615b397fd9ddca3b430fe98b6dd50494e09a6d7275a8fd0b255c0cd04a3e wpa_supplicant-2.11-r4
97b0eb3ddbae79c151320f0c48762ffc5ef675379bf61363a34a373c354ad774 dbus-libs-1.16.2-r2
49d92bf6e6c55da94fdd0dde05a66af761258458e6db3c7b87d773c4517a50e1 libnl3-3.11.0-r0
a5cd0931a100efd4eeedb1ab54443f67fdb7341060463e64017d0de6986b54fd pcsc-lite-libs-2.5.1-r0
445c25a5cbd99ce1881df61fd1a191705e937e0c6e9963cbb8b04f2acf3541ac dropbear-2026.94-r0
230e4a1749df6ece26852f552e84789fac750eef613e6f9cca0c5aedcd75514a utmps-libs-0.1.3.4-r0
f14960b7a1d40c20d6c045874682f73c0aa4e8f36bae11583d3b860fb10b6764 skalibs-libs-2.15.1.0-r0
7071d075262b1fdd3996e86c7955f219e00ce55e0774e54a62566c2bd11c493f e2fsprogs-1.47.4-r0
44096fa251d7cf4a5d8c6c1ffb4014e28fc63ccd4e02534d0e2908fc5e7bc850 e2fsprogs-extra-1.47.4-r0
476555b7a8178a8acf7cd94e0b3d10deb12ac236b9e78e04fc1648f0a29e3ea5 e2fsprogs-libs-1.47.4-r0
b8d23585a851bfc732cfb39638b5d92c88a309ba1eb52243796c69c18a978b10 libcom_err-1.47.4-r0
33f45bb795525b207a6786c85cc8a9d6211f3b854b285d7e3fb7a0b7b8cde7dc libblkid-2.42.2-r1
fe30d437021b58332454aa0a066fef98c90388717d17851aaaa3c9c9fdab7e67 libuuid-2.42.2-r1
dd863710179743e49a6f2d446576aec31dbc5ab61f88da254e054f530b99cdb1 libeconf-0.8.4-r0
"

set -- $ALPINE_APKS
alpine_apk_count=$#
alpine_pin_count=$(printf '%s\n' "$ALPINE_APK_SHA256S" |
	awk 'NF == 2 { n++ } END { print n + 0 }')
[ "$alpine_pin_count" -eq "$alpine_apk_count" ] ||
	fatal "Alpine package/pin count mismatch ($alpine_apk_count packages, $alpine_pin_count pins)"
printf '%s\n' "$ALPINE_APK_SHA256S" | awk '
	NF == 0 { next }
	NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ { exit 1 }
	seen[$2]++ { exit 1 }
' || fatal "malformed or duplicate Alpine package SHA-256 pin"

verify_blob() {
	vb_label=$1 vb_path=$2 vb_size=$3 vb_sha=$4
	[ -f "$vb_path" ] || fatal "$vb_label missing: $vb_path"
	vb_actual_size=$(wc -c < "$vb_path" | tr -d ' ')
	[ "$vb_actual_size" = "$vb_size" ] || \
		fatal "$vb_label has size $vb_actual_size, expected $vb_size: $vb_path"
	vb_actual_sha=$(sha256sum "$vb_path")
	vb_actual_sha=${vb_actual_sha%% *}
	[ "$vb_actual_sha" = "$vb_sha" ] || \
		fatal "$vb_label has unexpected SHA-256 $vb_actual_sha: $vb_path (stock Android blob? see header comment)"
	echo "  verified $vb_label: $vb_actual_size bytes"
}

fetch() {   # fetch URL OUT -- cache-aware, fail-closed
	[ -s "$2" ] && return 0
	echo "  fetching $(basename "$2")"
	# --retry alone does not cover TLS/TCP transport errors such as "Recv
	# failure: Connection reset by peer" (curl 35), which killed a CI run
	# mid-download from mirrors.edge.kernel.org; --retry-all-errors makes
	# the retries apply to those too (needs curl >= 7.71). An outer loop
	# remains because curl can still exit 22/56 after those retries
	# (Alpine CDN 2026-08-27, libstdc++-15.2.0-r8.apk).
	fetch_n=1
	fetch_max=${DC1_FETCH_RETRIES:-5}
	while [ "$fetch_n" -le "$fetch_max" ]; do
		if curl -fsSL --retry 3 --retry-all-errors -o "$2.part" "$1"; then
			mv "$2.part" "$2"
			return 0
		fi
		echo "  fetch attempt $fetch_n/$fetch_max failed: $(basename "$2")" >&2
		rm -f "$2.part"
		fetch_n=$((fetch_n + 1))
		[ "$fetch_n" -le "$fetch_max" ] || break
		sleep $((fetch_n * 2))
	done
	fatal "download failed: $1"
}

mkdir -p "$DL/firmware" "$DL/apk" "$DL/apkroot"

fetch "$LINUX_FIRMWARE_URL/mediatek/$WIFI_RAM_NAME?h=$LINUX_FIRMWARE_TAG" \
	"$DL/firmware/$WIFI_RAM_NAME"
fetch "$LINUX_FIRMWARE_URL/mediatek/$WIFI_PATCH_NAME?h=$LINUX_FIRMWARE_TAG" \
	"$DL/firmware/$WIFI_PATCH_NAME"
fetch "$LINUX_FIRMWARE_URL/mediatek/$BT_RAM_NAME?h=$LINUX_FIRMWARE_TAG" \
	"$DL/firmware/$BT_RAM_NAME"
verify_blob "MT7902 RAM firmware" "$DL/firmware/$WIFI_RAM_NAME" \
	"$WIFI_RAM_SIZE" "$WIFI_RAM_SHA256"
verify_blob "MT7902 ROM patch" "$DL/firmware/$WIFI_PATCH_NAME" \
	"$WIFI_PATCH_SIZE" "$WIFI_PATCH_SHA256"
verify_blob "MT7902 Bluetooth firmware" "$DL/firmware/$BT_RAM_NAME" \
	"$BT_RAM_SIZE" "$BT_RAM_SHA256"

if [ ! -f "$DL/firmware/regulatory.db" ] || [ ! -f "$DL/firmware/regulatory.db.p7s" ]; then
	fetch "$REGDB_URL" "$DL/firmware/wireless-regdb.tar.xz"
	tar -xJf "$DL/firmware/wireless-regdb.tar.xz" -C "$DL/firmware" \
		--strip-components=1 \
		"wireless-regdb-$REGDB_VERSION/regulatory.db" \
		"wireless-regdb-$REGDB_VERSION/regulatory.db.p7s" \
		|| fatal "cannot extract regulatory.db pair"
fi
verify_blob "wireless-regdb $REGDB_VERSION database" \
	"$DL/firmware/regulatory.db" "$REGDB_SIZE" "$REGDB_SHA256"
verify_blob "wireless-regdb $REGDB_VERSION signature" \
	"$DL/firmware/regulatory.db.p7s" "$REGDB_SIG_SIZE" "$REGDB_SIG_SHA256"
regdb_magic=$(od -An -tx1 -N4 "$DL/firmware/regulatory.db" | tr -d ' \n')
[ "$regdb_magic" = 52474442 ] || fatal "regulatory.db has invalid magic $regdb_magic"

# Fetch + unpack the pinned Alpine packages into one merged tree. An .apk is
# concatenated gzip/tar segments; tar extracts all of them (the signature
# segment yields dot-files we ignore). Every file we STAGE from the tree is
# checked to exist afterwards, so a bad extraction fails closed.
for pkg in $ALPINE_APKS; do
	fetch "$ALPINE_MIRROR/$pkg.apk" "$DL/apk/$pkg.apk"
	want=$(printf '%s\n' "$ALPINE_APK_SHA256S" |
		awk -v pkg="$pkg" '$2 == pkg { print $1; exit }')
	[ -n "$want" ] || fatal "no SHA-256 pin for Alpine package $pkg"
	got=$(sha256sum "$DL/apk/$pkg.apk" | cut -d' ' -f1)
	[ "$got" = "$want" ] ||
		fatal "Alpine package $pkg has SHA-256 $got, expected $want"
	echo "  verified Alpine package $pkg"
done
rm -rf "$DL/apkroot"
mkdir -p "$DL/apkroot"
for pkg in $ALPINE_APKS; do
	tar -xzf "$DL/apk/$pkg.apk" -C "$DL/apkroot" 2>/dev/null ||
		fatal "cannot extract verified Alpine package $pkg"
done
rm -rf "$DL/apkroot/.SIGN"* 2>/dev/null || true

BUSYBOX=${BUSYBOX:-"$DL/apkroot/bin/busybox.static"}

[ -x "$BUSYBOX" ] || fatal "static busybox missing at $BUSYBOX (set BUSYBOX=)"
# Must be the *static* build (Alpine's is static-PIE: self-relocating, no
# interpreter -- equally fine). A dynamically linked busybox would need the
# musl loader before /usr/lib exists, which init never guarantees.
if command -v file >/dev/null; then
	file -b "$BUSYBOX" | grep -Eq "statically linked|static-pie linked" || \
		fatal "$BUSYBOX is not statically linked"
fi
# If the busybox binary runs on this build host (native aarch64 CI), verify
# the applets the installer scripts depend on actually exist. Cross builds
# skip this check and find out on device -- prefer native CI.
if "$BUSYBOX" true 2>/dev/null; then
	applets=$("$BUSYBOX" --list)
	for a in nc sha256sum base64 blkid awk mkfifo tee head dd chroot \
	         switch_root cryptpw udhcpc rmdir df pidof gunzip; do
		echo "$applets" | grep -qx "$a" || \
			fatal "busybox at $BUSYBOX lacks required applet: $a"
	done
	echo "  busybox applet check: OK"
else
	echo "  NOTE: $BUSYBOX not runnable on this host; applet check skipped"
fi

rm -rf "$ROOT"
mkdir -p "$OUT" "$ROOT"

# ---------------------------------------------------------------- 1. compile
# -static: no ld-musl in the image, so nothing to get wrong. -Os: small and
# boring.
#
# init.c talks to DRM with raw ioctls against the kernel UAPI headers, which
# are vendored under src/uapi/ (drm/{drm,drm_mode,drm_fourcc}.h plus the two
# linux/ headers they pull in that not every libc ships -- bits.h, const.h).
# Raw UAPI headers annotate pointer arguments with __user, so define it empty
# exactly as the bring-up build did; and the -I pins to our vendored copy
# rather than whichever kernel headers the CI image happens to carry.
"$CC" -static -Os -Wall -Wextra -D__user= -I "$SRC/uapi" \
	-o "$OUT/installer-init" "$SRC/init.c"
"$STRIP" "$OUT/installer-init"

# dc1tools: the multi-call Go userland. Currently dc1-reboot-fastboot (the
# boot-mode nibble LK reads on the way up -- busybox `reboot` only does
# RB_AUTOBOOT, which LK answers by booting the same slot again) and bootctl
# (read-only A/B bootloader_control dump; all mutations refused by design),
# plus dc1-installd (the USB byte path), dc1-ask (the touch prompt client
# tui.sh drives -- it forwards each prompt to PID 1's in-process dialog
# server, which draws into the panel PID 1 owns), and dc1-debug (the
# read-only debugging toolkit: device info, partition checksums, log
# collection; screen-first via the same dialog server).
#
# One binary with argv[0] dispatch, because the Go runtime is ~1.2 MB and this
# initramfs is loaded into RAM: five separate binaries would pay for it five
# times. CGO_ENABLED=0 means no libc at all, a stronger guarantee than -static
# against musl, and it cross-compiles without a toolchain.
GOTOOLS_SRC="$HERE/gotools"
[ -f "$GOTOOLS_SRC/go.mod" ] || fatal "missing $GOTOOLS_SRC/go.mod"

# Stamp the installer identity into dc1tools (-ldflags -X): this is what
# `dc1-debug version` and the on-screen debug report show, so a device can
# answer "what is running on me". Short SHA, -dirty on an unclean tree,
# "unknown" when git is not there (tarball builds).
DC1_VER=${DC1_SOURCE_VERSION:-}
if [ -z "$DC1_VER" ]; then
	DC1_VER=$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || true)
	[ -n "$DC1_VER" ] || DC1_VER=unknown
	if [ -n "$(git -C "$HERE/.." status --porcelain 2>/dev/null)" ]; then
		DC1_VER="${DC1_VER}-dirty"
	fi
fi

( cd "$GOTOOLS_SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
	go build -trimpath \
	-ldflags="-s -w -X github.com/denysvitali/dc-1-pmos/installer/gotools/internal/debugtools.Version=$DC1_VER" \
	-o "$OUT/dc1tools" . ) \
	|| fatal "dc1tools build failed"

# system-init: PID 1 of the SYSTEM boot initramfs (jagar-boot.img). Owns the
# watchdog across switch_root; see src/system/init.c.
"$CC" -static -Os -Wall -Wextra -o "$OUT/system-init" "$SRC/system/init.c"
"$STRIP" "$OUT/system-init"


# ---------------------------------------------------------------- 2. skeleton
d="$ROOT/installer"
mkdir -p "$d"/dev "$d"/proc "$d"/sys "$d"/tmp "$d"/etc/installer "$d"/bin \
         "$d"/sbin "$d"/lib "$d"/root "$d"/mnt/root "$d"/usr/bin "$d"/usr/sbin \
         "$d"/sys/kernel/config

# Static device nodes. /dev/console must be in the cpio (the kernel itself
# opens it before /init runs); the rest are insurance in case devtmpfs fails.
mknod -m 600 "$d/dev/console" c 5 1
mknod -m 666 "$d/dev/null"    c 1 3
mknod -m 660 "$d/dev/kmsg"    c 1 11
mknod -m 600 "$d/dev/mem"     c 1 1
mknod -m 620 "$d/dev/tty0"    c 4 0
mknod -m 620 "$d/dev/tty1"    c 4 1
mknod -m 660 "$d/dev/ttyS0"   c 4 64
mknod -m 666 "$d/dev/tty"     c 5 0

# The installer PID 1 is the Go dc1tools binary, reached as /init via argv[0]
# dispatch ("init" -> installerinit). The kernel execs ramdisk_execute_command
# "/init" with argv[0] "/init", so filepath.Base == "init". The C installer-init
# is still compiled above as the boot-proven reference, but is no longer staged.
ln -sf /bin/dc1tools "$d/init"
install -m 0755 "$OUT/dc1tools" "$d/bin/dc1tools"
# argv[0] dispatch: these are the names the rest of the image (and the
# recovery notes) already call, so they stay callable without knowing that one
# binary now serves them all.
ln -sf dc1tools "$d/bin/dc1-reboot-fastboot"
ln -sf dc1tools "$d/bin/bootctl"
ln -sf dc1tools "$d/bin/dc1-installd"
ln -sf dc1tools "$d/bin/dc1-ask"
ln -sf dc1tools "$d/bin/dc1-debug"
install -m 0755 "$BUSYBOX" "$d/bin/busybox"
install -m 0755 "$SRC/rc.sh" "$d/etc/rc.sh"
install -m 0755 "$SRC/finalize.sh" "$d/etc/installer/finalize.sh"
install -m 0755 "$SRC/provision.sh" "$d/etc/installer/provision.sh"
install -m 0755 "$SRC/netinstall.sh" "$d/etc/installer/netinstall.sh"
install -m 0755 "$SRC/tui.sh" "$d/etc/installer/tui.sh"
install -m 0644 "$SRC/partlib.sh" "$d/etc/installer/partlib.sh"
install -m 0644 "$SRC/writelib.sh" "$d/etc/installer/writelib.sh"
install -m 0644 "$SRC/wifi.sh" "$d/etc/installer/wifi.sh"
install -m 0755 "$SRC/udhcpc.script" "$d/etc/udhcpc.script"

# rc.sh runs "/bin/busybox --install -s /bin", but every applet the scripts
# reference is also symlinked here: a missing `tr` or `head` does not error,
# it makes $(...) expand to nothing and the failure is silent.
for a in sh ash cat ls ln mount mountpoint umount insmod lsmod modprobe ip \
         dmesg setsid echo sleep mkdir rm cp mv chmod chown touch chroot tr \
         head tail wc grep sed cut sort od dd find blkid seq date uname sync \
         poweroff reboot cmp pidof ps basename readlink printf nc mkfifo \
         sha256sum base64 awk tee stat cryptpw udhcpc rmdir df kill gunzip; do
	ln -sf busybox "$d/bin/$a"
done

# ------------------------------------------- 2b. network userland + firmware
# Binaries and libraries from the pinned Alpine apks (see stage 0). Only the
# named files are taken -- never a recursive copy of the apk tree.
AR="$DL/apkroot"
stage() {   # stage MODE SRC DEST -- fail closed on anything missing
	[ -e "$AR/$2" ] || [ -L "$AR/$2" ] || fatal "apk did not provide $2"
	mkdir -p "$d/$(dirname "$3")"
	cp -a "$AR/$2" "$d/$3"
	[ "$1" = lib ] || chmod 0755 "$d/$3"
}
stage bin sbin/wpa_supplicant       sbin/wpa_supplicant
stage bin sbin/wpa_cli              sbin/wpa_cli
stage bin usr/bin/curl              usr/bin/curl
stage bin usr/bin/zstd              usr/bin/zstd
# Offline rootfs grow (wr_finalize) and the optional fsck: resize2fs lives in
# e2fsprogs-extra, e2fsck in e2fsprogs. Their DT_NEEDED libs (libext2fs,
# libe2p, libcom_err, libblkid, libuuid, and libblkid's own libeconf) land in
# /usr/lib via the apk list and the closure check below.
stage bin sbin/e2fsck                sbin/e2fsck
stage bin usr/sbin/resize2fs         usr/sbin/resize2fs
stage lib etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ca-certificates.crt
# dropbear: SSH into the recovery environment (a real PTY, port forwarding;
# no scp -- busybox has no scp applet and there is no sftp-server, so files
# leave the device as `ssh ... cat`) -- rc.sh binds it to the USB link only,
# never the LAN.
stage bin usr/sbin/dropbear         usr/sbin/dropbear
stage bin usr/bin/dropbearkey       usr/bin/dropbearkey
# The musl loader plus every DT_NEEDED of the binaries above. Alpine keeps
# musl in /lib and the rest in /usr/lib; preserve both (symlinks included).
mkdir -p "$d/lib" "$d/usr/lib"
for so in lib/ld-musl-aarch64.so.1 lib/libc.musl-aarch64.so.1; do
	[ -e "$AR/$so" ] || [ -L "$AR/$so" ] || fatal "apk did not provide $so"
	cp -a "$AR/$so" "$d/$so"
done
find "$AR/usr/lib" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) \
	-exec cp -a -t "$d/usr/lib" {} + \
	|| fatal "staging Alpine shared libraries failed"

# Every staged ELF must resolve its DT_NEEDED inside the image, or Wi-Fi /
# download would fail at first boot on hardware instead of failing the build.
if command -v readelf >/dev/null 2>&1; then
	for bin in "$d/sbin/wpa_supplicant" "$d/sbin/wpa_cli" \
	           "$d/usr/bin/curl" "$d/usr/bin/zstd" \
	           "$d/sbin/e2fsck" "$d/usr/sbin/resize2fs" "$d"/usr/lib/*.so*; do
		[ -f "$bin" ] || continue
		readelf -d "$bin" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' \
		| while read -r need; do
			[ -e "$d/usr/lib/$need" ] || [ -e "$d/lib/$need" ] || \
				fatal "$(basename "$bin") needs $need, not staged (Alpine dep drift -- update the apk pin list)"
		done || exit 1
	done
	echo "  shared-library closure check: OK"
else
	echo "  NOTE: readelf unavailable; shared-library closure check skipped"
fi

# Pinned upstream firmware (verified in stage 0). Exactly these four files;
# never a recursive copy, so a stray same-named vendor blob cannot ride in.
mkdir -p "$d/lib/firmware/mediatek"
install -m 0644 "$DL/firmware/$WIFI_RAM_NAME" "$d/lib/firmware/mediatek/$WIFI_RAM_NAME"
install -m 0644 "$DL/firmware/$WIFI_PATCH_NAME" "$d/lib/firmware/mediatek/$WIFI_PATCH_NAME"
install -m 0644 "$DL/firmware/regulatory.db" "$d/lib/firmware/regulatory.db"
install -m 0644 "$DL/firmware/regulatory.db.p7s" "$d/lib/firmware/regulatory.db.p7s"

# Runtime directories the network stack expects.
mkdir -p "$d/run" "$d/tmp"
: > "$d/etc/resolv.conf"
chmod 0644 "$d/etc/resolv.conf"

# Account database + PTY mount point for dropbear. The installer initramfs had
# neither: SSH cannot resolve a user without passwd/shadow, and cannot allocate
# an interactive terminal without devpts.
#
# root has a BLANK password on purpose, and this is NOT a secret leak: an
# empty password field is the absence of a credential, so nothing sensitive is
# published. It is also not a new exposure -- this image already serves an
# unauthenticated root shell on TCP 4444 over the same cable. Both are bound to
# the USB link only (see rc.sh); the installer brings Wi-Fi up during a network
# install, so binding is what keeps a root shell off the user's LAN.
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$d/etc/passwd"
chmod 0644 "$d/etc/passwd"
printf 'root::19000:0:99999:7:::\n' > "$d/etc/shadow"
chmod 0640 "$d/etc/shadow"
printf 'root:x:0:\n' > "$d/etc/group"
chmod 0644 "$d/etc/group"
mkdir -p "$d/dev/pts" "$d/etc/dropbear"

if [ -n "$MODDIR" ] && [ -d "$MODDIR" ]; then
	mkdir -p "$d/lib/modules"
	find "$MODDIR" -name '*.ko' -exec cp -t "$d/lib/modules" {} +
	echo "  staged $(ls "$d/lib/modules" | wc -l) modules from $MODDIR"
fi

# --------------------------------------------------------- 3. system skeleton
# The SYSTEM boot initramfs (goes into jagar-boot.img): expose the bounded
# ACM+ECM recovery gadget, verify the installed jagar-root filesystem, then
# switch_root into it. It carries no credentials: the raw USB debug transports
# are the recovery channel before the provisioned rootfs takes over.
s="$ROOT/system"
mkdir -p "$s"/dev "$s"/proc "$s"/sys "$s"/tmp "$s"/etc "$s"/bin "$s"/sbin \
         "$s"/mnt/root

mknod -m 600 "$s/dev/console" c 5 1
mknod -m 666 "$s/dev/null"    c 1 3
mknod -m 660 "$s/dev/kmsg"    c 1 11
mknod -m 600 "$s/dev/mem"     c 1 1
mknod -m 620 "$s/dev/tty0"    c 4 0
mknod -m 620 "$s/dev/tty1"    c 4 1
mknod -m 660 "$s/dev/ttyS0"   c 4 64
mknod -m 666 "$s/dev/tty"     c 5 0

install -m 0755 "$OUT/system-init" "$s/init"
install -m 0755 "$BUSYBOX" "$s/bin/busybox"
install -m 0755 "$SRC/system/boot.sh" "$s/etc/boot.sh"
install -m 0644 "$SRC/partlib.sh" "$s/etc/partlib.sh"
# The rescue path back to fastboot. dc1tools costs this small image ~2.5 MB
# for one applet, but the alternative is keeping a second implementation of
# the boot-mode nibble alive, and a bootloader we cannot debug is the worst
# place to run two versions of anything.
install -m 0755 "$OUT/dc1tools" "$s/bin/dc1tools"
ln -sf dc1tools "$s/bin/dc1-reboot-fastboot"
ln -sf dc1tools "$s/bin/dc1-debug"

# MT7902 firmware + regulatory.db, same pinned set as the installer image.
# The Wi-Fi driver is built in and its firmware request fires at ~2.8s --
# while THIS initramfs is still the root filesystem, seconds before
# jagar-root is mounted -- so the blobs must exist here or the request
# fails -2 nine times and mt7921s gives up with "hardware init failed"
# (measured 2026-08-19 on the first mainline-DT boot with a working SDIO
# host; a manual driver rebind after boot then succeeded from the rootfs
# copy). The kernel's zstd loader accepts them; ~500 KB well spent.
mkdir -p "$s/lib/firmware/mediatek"
install -m 0644 "$DL/firmware/$WIFI_RAM_NAME" "$s/lib/firmware/mediatek/$WIFI_RAM_NAME"
install -m 0644 "$DL/firmware/$WIFI_PATCH_NAME" "$s/lib/firmware/mediatek/$WIFI_PATCH_NAME"
# Bluetooth loses the same race harder: btmtksdio is built in too and asks for
# its blob at t=1.75 s, a full second earlier than mt7921s, and it makes ONE
# attempt -- no retry, so on every boot without this file hci0 registers,
# "Failed to setup 79xx firmware (-2)" lands in dmesg, and the controller stays
# half-initialised (bluetoothctl: "No default controller available"). Staging
# it here is what dc1-bluetooth's unbind/bind was working around; that service
# stays as a repair path, now gated on the failure signature.
install -m 0644 "$DL/firmware/$BT_RAM_NAME" "$s/lib/firmware/mediatek/$BT_RAM_NAME"
install -m 0644 "$DL/firmware/regulatory.db" "$s/lib/firmware/regulatory.db"
install -m 0644 "$DL/firmware/regulatory.db.p7s" "$s/lib/firmware/regulatory.db.p7s"

# The reachability watchdog for the INSTALLED system. boot.sh copies these
# into the verified rootfs on every boot (self-heal): the boot image is the
# only artifact fastboot can update without a running system, so the
# initramfs is the carrier -- deliberately not the device package, since
# "reboot to fastboot when nobody can reach you" is bench policy, not
# something upstream ships to end users.
mkdir -p "$s/etc/deploy"
install -m 0755 "$SRC/system/boot-watchdog.sh" "$s/etc/deploy/dc1-boot-watchdog"
install -m 0644 "$SRC/system/dc1-boot-watchdog.service" \
	"$s/etc/deploy/dc1-boot-watchdog.service"

# Offline rootfs grow (boot.sh) + optional fsck: resize2fs and e2fsck plus
# their musl libs, the same pinned set the installer stages. The apk ships each
# lib as a real file (libX.so.1.2.3) plus a symlink (libX.so.1); copy both.
mkdir -p "$s/sbin" "$s/usr/sbin" "$s/usr/lib" "$s/lib"
install -m 0755 "$AR/sbin/e2fsck" "$s/sbin/e2fsck"
install -m 0755 "$AR/usr/sbin/resize2fs" "$s/usr/sbin/resize2fs"
for base in libe2p libext2fs libcom_err libblkid libuuid libeconf; do
	for f in "$AR/usr/lib/$base".so*; do
		[ -e "$f" ] || continue
		cp -a "$f" "$s/usr/lib/"
	done
done
for f in "$AR/lib/ld-musl-aarch64.so.1" "$AR/lib/libc.musl-aarch64.so.1"; do
	[ -e "$f" ] || fatal "apk did not provide $f"
	cp -a "$f" "$s/lib/"
done
# The same fail-closed closure check the installer gets: every NEEDED of the
# staged e2fs binaries must resolve inside the image, or a missing lib fails
# the build rather than silently stranding a boot that cannot resize its root.
if command -v readelf >/dev/null 2>&1; then
	for bin in "$s/sbin/e2fsck" "$s/usr/sbin/resize2fs"; do
		readelf -d "$bin" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' \
		| while read -r need; do
			[ -e "$s/usr/lib/$need" ] || [ -e "$s/lib/$need" ] || \
				fatal "$(basename "$bin") needs $need, not staged in the system initramfs"
		done || exit 1
	done
	echo "  system initramfs shared-library closure: OK"
fi

for a in sh ash cat ls ln mount mountpoint umount echo sleep mkdir rm cp \
         chmod tr head tail wc grep sed cut od dd find blkid seq date sync \
         reboot basename dirname readlink printf stat switch_root dmesg setsid \
         cmp mv; do
	ln -sf busybox "$s/bin/$a"
done

# The SYSTEM image never runs `busybox --install`, so an applet that is not
# symlinked above simply does not exist -- and a missing one fails SILENTLY:
# $(missing_cmd) expands to the empty string, so resolution "succeeds" with an
# empty device name. That exact bug (a missing `dirname`) made boot.sh time out
# on "userdata partition not found", dropped PID 1 to a rescue shell on an
# invisible tty, and left the device dark on every boot. Fail the BUILD instead:
# every bare word that the staged scripts invoke must resolve to a symlink here.
for a in $(sed -n -e 's/^[[:space:]]*#.*//' \
                  -e 's/.*\$(\([a-z0-9_]*\)[ )].*/\1/p' \
                  "$SRC/system/boot.sh" "$SRC/partlib.sh" | sort -u); do
	case "$a" in
		# locally-defined functions, not applets
		resolve_userdata|resolve_named_part|sysfs_dev_name|log|fail) continue ;;
	esac
	[ -e "$s/bin/$a" ] || fatal "system initramfs scripts call '$a' but it is not staged in /bin"
done
echo "  system initramfs applet closure: OK"

# Belt and braces: nothing secret-shaped may enter either image. The CA
# bundle (public certificates, .crt) is expected; anything key-like is not.
if find "$ROOT" -name 'authorized_keys' -o -name 'wifi.conf' -o -name '*.pem' \
	-o -name 'wpa_supplicant.conf' -o -name '*.psk' \
	-o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' \
	| grep -q .; then
	fatal "credential-like file staged into an initramfs image"
fi

# ------------------------------------------------------------------- 4. pack
# newc is the only format the kernel's unpacker accepts. Reproducible: normalize
# every staged mtime to SOURCE_DATE_EPOCH, sort the file list, renumber cpio
# inodes, force root:root ownership, and use gzip -n for no wrapper timestamp.
# lz4 -l = LEGACY frame (magic 02 21 4c 18): the modern frame (04 22 4d 18)
# is rejected by the kernel's initramfs path on this boot chain.
pack() {
	pd=$1; base=$2
	find "$pd" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
	( cd "$pd" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
	    | cpio -o -H newc -R 0:0 --renumber-inodes --quiet ) > "$base.cpio"
	gzip -9 -n < "$base.cpio" > "$base.cpio.gz"
	lz4 -l -9 -f "$base.cpio" "$base.cpio.lz4" >/dev/null
	rm -f "$base.cpio"
	[ "$(od -An -v -tx1 -N4 "$base.cpio.lz4" | tr -d ' \n')" = 02214c18 ] || \
		fatal "packed ramdisk is not legacy-frame LZ4: $base"
}
pack "$d" "$OUT/installer-initramfs"
pack "$s" "$OUT/system-initramfs"

# ------------------------------------------------ 5. boot images (optional)
# Artifact names are load-bearing: the host installer and CI expect exactly
# installer-boot.img (flashed to enter installation mode) and jagar-boot.img
# (the real boot image flashed after install).
if [ -n "$KERNEL_IMAGE" ]; then
	[ -s "$KERNEL_IMAGE" ] || fatal "KERNEL_IMAGE missing: $KERNEL_IMAGE"
	repack="$HERE/../boot/repack-boot.sh"
	[ -x "$repack" ] || fatal "missing $repack"
	# BOTH images boot the MAINLINE device tree: the kernel slot becomes
	# gzip([dtbswap stub | dtb | Image]) -- see boot/dtbswap/README.md.
	# LK's merged signed tree cannot be replaced, so the stub is the only
	# route; hardware-proven 2026-08-19 (system image) and 2026-08-24
	# (installation mode, issue #1: on at least one unit the stock-DT
	# installer black-screens with no USB gadget, while a dtbswap installer
	# brings up the touch installer and USB Ethernet -- the initramfs GCE
	# gate accepts both DT node names). There is deliberately NO plain
	# (stock-DT) image path: KERNEL_DTB is required, and every jagar-boot.img
	# flash path (netinstall.sh, dc1-boot-sync, dc1-install.sh) structurally
	# REFUSES a plain image anyway.
	[ -n "${KERNEL_DTB:-}" ] || \
		fatal "KERNEL_DTB is required with KERNEL_IMAGE: boot images are dtbswap-only"
	[ -s "$KERNEL_DTB" ] || fatal "KERNEL_DTB missing: $KERNEL_DTB"
	dtbswap="$HERE/../boot/dtbswap"
	make -C "$dtbswap" ${DTBSWAP_LLVM:+LLVM="$DTBSWAP_LLVM"} \
		${DTBSWAP_LLD:+LLD="$DTBSWAP_LLD"} \
		|| fatal "dtbswap stub build failed"
	# pack.sh needs the raw Image; accept a gzipped KERNEL_IMAGE.
	if [ "$(od -An -N2 -tx1 "$KERNEL_IMAGE" | tr -d ' \n')" = "1f8b" ]; then
		gunzip -c "$KERNEL_IMAGE" > "$OUT/Image.raw"
	else
		cp "$KERNEL_IMAGE" "$OUT/Image.raw"
	fi
	sh "$dtbswap/pack.sh" "$dtbswap/dtbswap.bin" "$KERNEL_DTB" \
		"$OUT/Image.raw" "$OUT/dtbswap-kernel.gz" \
		|| fatal "dtbswap pack failed"
	rm -f "$OUT/Image.raw"
	boot_kernel="$OUT/dtbswap-kernel.gz"
	sh "$repack" "$boot_kernel" "$OUT/installer-initramfs.cpio.lz4" \
		"$OUT/installer-boot.img"
	sh "$repack" "$boot_kernel" "$OUT/system-initramfs.cpio.lz4" \
		"$OUT/jagar-boot.img"
fi

# ------------------------------------------------------------------ 6. report
echo
echo "== results =="
for f in "$OUT/installer-initramfs.cpio.gz" "$OUT/installer-initramfs.cpio.lz4" \
         "$OUT/system-initramfs.cpio.gz" "$OUT/system-initramfs.cpio.lz4" \
         "$OUT/installer-boot.img" "$OUT/jagar-boot.img"; do
	[ -f "$f" ] || continue
	printf '%-40s %10s bytes\n' "$(basename "$f")" "$(stat -c %s "$f")"
done
