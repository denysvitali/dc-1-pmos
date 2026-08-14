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
#   KERNEL_IMAGE=path/Image.gz ./build.sh
#                                       -> also out/installer-boot.img and
#                                          out/jagar-boot.img via
#                                          ../boot/repack-boot.sh
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
#     version below. These are public binaries fetched from the official
#     mirror; when Alpine bumps a version the URL 404s and the build fails
#     closed -- bump the pin deliberately.
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

# Signed regulatory database pair: official wireless-regdb 2026.05.30
# release (CONFIG_CFG80211_REQUIRE_SIGNED_REGDB -- never stage half a pair).
REGDB_VERSION=2026.05.30
REGDB_URL="https://mirrors.edge.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-$REGDB_VERSION.tar.xz"
REGDB_SIZE=6380
REGDB_SHA256=2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b
REGDB_SIG_SIZE=1085
REGDB_SIG_SHA256=c941c08f51c93e46722293b85631604c3740d86c3de0c75f79aef50d2e919179

# Alpine edge/main aarch64 packages, pinned by exact version (resolved
# 2026-08-14). The mirror serves exactly one file per version, so a version
# pin IS the content pin for build reproducibility purposes; when edge moves
# on, the URL 404s and the build fails closed.
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
libgcc-15.2.0-r8
libstdc++-15.2.0-r8
wpa_supplicant-2.11-r4
dbus-libs-1.16.2-r2
libnl3-3.11.0-r0
pcsc-lite-libs-2.5.1-r0
dropbear-2026.94-r0
utmps-libs-0.1.3.4-r0
skalibs-libs-2.15.1.0-r0
"

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
	curl -fsSL --retry 3 -o "$2.part" "$1" || fatal "download failed: $1"
	mv "$2.part" "$2"
}

mkdir -p "$DL/firmware" "$DL/apk" "$DL/apkroot"

fetch "$LINUX_FIRMWARE_URL/mediatek/$WIFI_RAM_NAME?h=$LINUX_FIRMWARE_TAG" \
	"$DL/firmware/$WIFI_RAM_NAME"
fetch "$LINUX_FIRMWARE_URL/mediatek/$WIFI_PATCH_NAME?h=$LINUX_FIRMWARE_TAG" \
	"$DL/firmware/$WIFI_PATCH_NAME"
verify_blob "MT7902 RAM firmware" "$DL/firmware/$WIFI_RAM_NAME" \
	"$WIFI_RAM_SIZE" "$WIFI_RAM_SHA256"
verify_blob "MT7902 ROM patch" "$DL/firmware/$WIFI_PATCH_NAME" \
	"$WIFI_PATCH_SIZE" "$WIFI_PATCH_SHA256"

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
done
rm -rf "$DL/apkroot"
mkdir -p "$DL/apkroot"
for pkg in $ALPINE_APKS; do
	tar -xzf "$DL/apk/$pkg.apk" -C "$DL/apkroot" 2>/dev/null || true
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
	         switch_root cryptpw udhcpc rmdir df pidof; do
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

# rebootbl: busybox `reboot` only does RB_AUTOBOOT, which LK treats as an
# ordinary reboot. Ending the install in LK fastboot (so the host can flash
# the real boot image over the installer) needs the BCB "boot-fastboot"
# write, which is what rebootbl does.
"$CC" -static -Os -Wall -Wextra -o "$OUT/rebootbl" "$SRC/rebootbl.c"
"$STRIP" "$OUT/rebootbl"

# bootctl: read-only A/B bootloader_control dump, for diagnostics over the
# debug shell. All mutations are refused by design.
"$CC" -static -Os -Wall -Wextra -o "$OUT/bootctl" "$SRC/bootctl.c"
"$STRIP" "$OUT/bootctl"

# system-init: PID 1 of the SYSTEM boot initramfs (jagar-boot.img). Owns the
# watchdog across switch_root; see src/system/init.c.
"$CC" -static -Os -Wall -Wextra -o "$OUT/system-init" "$SRC/system/init.c"
"$STRIP" "$OUT/system-init"

# dc1-ask: the touch prompt screen (framebuffer + evdev, no dependencies).
"$CC" -static -Os -Wall -Wextra -o "$OUT/dc1-ask" "$SRC/ask.c"
"$STRIP" "$OUT/dc1-ask"

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
mknod -m 620 "$d/dev/tty0"    c 4 0
mknod -m 620 "$d/dev/tty1"    c 4 1
mknod -m 660 "$d/dev/ttyS0"   c 4 64
mknod -m 666 "$d/dev/tty"     c 5 0

install -m 0755 "$OUT/installer-init" "$d/init"
install -m 0755 "$OUT/rebootbl" "$d/bin/rebootbl"
install -m 0755 "$OUT/bootctl"  "$d/bin/bootctl"
install -m 0755 "$OUT/dc1-ask"  "$d/bin/dc1-ask"
install -m 0755 "$BUSYBOX" "$d/bin/busybox"
install -m 0755 "$SRC/rc.sh" "$d/etc/rc.sh"
install -m 0755 "$SRC/receive.sh" "$d/etc/installer/receive.sh"
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
         sha256sum base64 awk tee stat cryptpw udhcpc rmdir df kill; do
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
stage lib etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ca-certificates.crt
# dropbear: SSH into the recovery environment (scp for pulling logs, a real
# PTY, port forwarding) -- rc.sh binds it to the USB link only, never the LAN.
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
	           "$d/usr/bin/curl" "$d/usr/bin/zstd" "$d"/usr/lib/*.so*; do
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
# The SYSTEM boot initramfs (goes into jagar-boot.img): verify the installed
# jagar-root filesystem and switch_root into it. No gadget, no daemon, no
# secrets -- just busybox, the shared partition resolver, and rebootbl so a
# rescue shell can get back to fastboot.
s="$ROOT/system"
mkdir -p "$s"/dev "$s"/proc "$s"/sys "$s"/tmp "$s"/etc "$s"/bin "$s"/sbin \
         "$s"/mnt/root

mknod -m 600 "$s/dev/console" c 5 1
mknod -m 666 "$s/dev/null"    c 1 3
mknod -m 660 "$s/dev/kmsg"    c 1 11
mknod -m 620 "$s/dev/tty0"    c 4 0
mknod -m 620 "$s/dev/tty1"    c 4 1
mknod -m 660 "$s/dev/ttyS0"   c 4 64
mknod -m 666 "$s/dev/tty"     c 5 0

install -m 0755 "$OUT/system-init" "$s/init"
install -m 0755 "$BUSYBOX" "$s/bin/busybox"
install -m 0755 "$SRC/system/boot.sh" "$s/etc/boot.sh"
install -m 0644 "$SRC/partlib.sh" "$s/etc/partlib.sh"
install -m 0755 "$OUT/rebootbl" "$s/bin/rebootbl"
for a in sh ash cat ls ln mount mountpoint umount echo sleep mkdir rm cp \
         chmod tr head tail wc grep sed cut od dd find blkid seq date sync \
         reboot basename dirname readlink printf stat switch_root dmesg setsid; do
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
# newc is the only format the kernel's unpacker accepts. Reproducible: sorted
# file list, everything root:root via -R, gzip -n for no timestamp.
# lz4 -l = LEGACY frame (magic 02 21 4c 18): the modern frame (04 22 4d 18)
# is rejected by the kernel's initramfs path on this boot chain.
pack() {
	pd=$1; base=$2
	( cd "$pd" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
	    | cpio -o -H newc -R 0:0 --quiet ) > "$base.cpio"
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
	sh "$repack" "$KERNEL_IMAGE" "$OUT/installer-initramfs.cpio.lz4" \
		"$OUT/installer-boot.img"
	sh "$repack" "$KERNEL_IMAGE" "$OUT/system-initramfs.cpio.lz4" \
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
