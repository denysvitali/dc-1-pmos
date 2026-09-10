#!/bin/sh
# Build a pinned kernel package; optionally install locally and reboot.
set -eu
usage() {
	echo "usage: $0 build|install|build-install [--reboot]" >&2
	exit 2
}
action=${1:-build}
[ "$#" -eq 0 ] || shift
reboot=no
if [ "${1:-}" = --reboot ]; then reboot=yes; shift; fi
[ "$#" -eq 0 ] || usage
case "$action" in build|install|build-install) ;; *) usage ;; esac
[ "$action:$reboot" != build:yes ] || usage
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${DC1_KERNEL_WORK:-$repo/work}
mkdir -p "$work"
work=$(CDPATH= cd -- "$work" && pwd)
package=linux-postmarketos-mediatek-mt6789
recipe="$repo/pmaports/device/testing/$package/APKBUILD"
version=$(awk -F= '$1=="pkgver" {print $2}' "$recipe")
release=$(awk -F= '$1=="pkgrel" {print $2}' "$recipe")
apk="$work/pmbootstrap-work/packages/edge/aarch64/$package-$version-r$release.apk"

if [ "$action" != install ]; then
	# The rootfs script's validation mode initializes pinned sources and the
	# pmbootstrap config, without building a rootfs or touching the device.
	validation=$(mktemp -d "$work/kernel-validation.XXXXXX")
	trap 'rmdir "$validation"' EXIT
	sh "$repo/scripts/build-rootfs.sh" --validate-only "$work" "$validation"
	sh "$repo/scripts/restore-local-apk-key.sh" "$work/pmbootstrap-work"
	# Copied caches may belong to the host user; compiles run as pmbootstrap's
	# fixed pmos uid/gid 12345 inside the chroot.
	if [ -d "$work/pmbootstrap-work/cache_ccache_aarch64" ]; then
		sudo chown -R 12345:12345 "$work/pmbootstrap-work/cache_ccache_aarch64"
	fi
	mkdir -p "$work/pmbootstrap-work/cache_distfiles"
	if [ -w "$work/pmbootstrap-work/cache_distfiles" ]; then
		sh "$repo/scripts/prefetch-kernel-distfile.sh" "$work/pmbootstrap-work/cache_distfiles"
	else
		sudo sh "$repo/scripts/prefetch-kernel-distfile.sh" "$work/pmbootstrap-work/cache_distfiles"
	fi
	# --lax keeps the toolchain chroot; ccache and distfiles persist too.
	# Increment pkgrel after changing inputs: unchanged packages are reused.
	python3 "$work/pmbootstrap/pmbootstrap.py" --config "$work/pmbootstrap.cfg" \
		--aports "$work/pmaports" build --lax "$package"
fi
[ -f "$apk" ] || { echo "missing package: $apk" >&2; exit 1; }
echo "Kernel package: $apk"
if [ "$action" != build ]; then
	python3 "$work/pmbootstrap/pmbootstrap.py" --config "$work/pmbootstrap.cfg" \
		--aports "$work/pmaports" shutdown
	(cd "$repo/boot/mkboot" && go build -o mkboot .)
	# Inhibit shutdown only during the transaction; reboot happens afterwards.
	sudo systemd-inhibit --what=shutdown:sleep --mode=block \
		--why="Installing and verifying local DC-1 kernel" \
		python3 "$repo/scripts/kernel-local-install.py" install "$repo" "$apk" \
		"$work/pmbootstrap-work/config_apk_keys"
	if [ "$reboot" = yes ]; then
		echo "Verified local kernel staged; rebooting."
		sudo systemctl reboot
	fi
fi
