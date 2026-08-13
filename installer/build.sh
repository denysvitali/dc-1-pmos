#!/bin/sh
# Build BOTH DC-1 initramfs images:
#   installer  -- "installation mode" (USB gadget net + installd), flashed
#                 temporarily to boot_a during installation
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
#
# The installer image is deliberately minimal and SECRET-FREE:
#   * no Wi-Fi firmware: the install transfer runs over USB gadget
#     networking on the same cable fastboot used, so the MT7902 blobs are
#     not needed here. Wi-Fi credentials collected during install are
#     provisioned into the INSTALLED rootfs, which carries its own firmware.
#   * no wifi.conf, no authorized_keys, no keys of any kind.
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
BUSYBOX=${BUSYBOX:-/bin/busybox.static}
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

[ -x "$BUSYBOX" ] || fatal "static busybox missing at $BUSYBOX (set BUSYBOX=)"
# Must be the *static* build. A dynamically linked busybox would need the musl
# loader, which we deliberately do not ship.
if command -v file >/dev/null; then
	file -b "$BUSYBOX" | grep -q "statically linked" || \
		fatal "$BUSYBOX is not statically linked"
fi
# If the busybox binary runs on this build host (native aarch64 CI), verify
# the applets the installer scripts depend on actually exist. Cross builds
# skip this check and find out on device -- prefer native CI.
if "$BUSYBOX" true 2>/dev/null; then
	applets=$("$BUSYBOX" --list)
	for a in nc sha256sum base64 blkid awk mkfifo tee head dd chroot switch_root; do
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
"$CC" -static -Os -Wall -Wextra -o "$OUT/installer-init" "$SRC/init.c"
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
install -m 0755 "$BUSYBOX" "$d/bin/busybox"
install -m 0755 "$SRC/rc.sh" "$d/etc/rc.sh"
install -m 0755 "$SRC/receive.sh" "$d/etc/installer/receive.sh"
install -m 0755 "$SRC/provision.sh" "$d/etc/installer/provision.sh"
install -m 0644 "$SRC/partlib.sh" "$d/etc/installer/partlib.sh"

# rc.sh runs "/bin/busybox --install -s /bin", but every applet the scripts
# reference is also symlinked here: a missing `tr` or `head` does not error,
# it makes $(...) expand to nothing and the failure is silent.
for a in sh ash cat ls ln mount mountpoint umount insmod lsmod modprobe ip \
         dmesg setsid echo sleep mkdir rm cp mv chmod chown touch chroot tr \
         head tail wc grep sed cut sort od dd find blkid seq date uname sync \
         poweroff reboot cmp pidof ps basename readlink printf nc mkfifo \
         sha256sum base64 awk tee stat; do
	ln -sf busybox "$d/bin/$a"
done

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
         reboot basename readlink printf stat switch_root dmesg setsid; do
	ln -sf busybox "$s/bin/$a"
done

# Belt and braces: nothing secret-shaped may enter either image.
if find "$ROOT" -name 'authorized_keys' -o -name 'wifi.conf' -o -name '*.pem' \
	-o -name 'id_rsa*' -o -name 'id_ed25519*' | grep -q .; then
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
