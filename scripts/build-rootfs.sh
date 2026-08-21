#!/bin/sh
set -eu

usage() {
	echo "usage: $0 [--validate-only] [--verify-sources] WORK_DIRECTORY OUTPUT_DIRECTORY" >&2
	exit 2
}

validate_only=no
verify_sources=no
while [ "$#" -gt 0 ]; do
	case "$1" in
		--validate-only) validate_only=yes; shift ;;
		--verify-sources) verify_sources=yes; shift ;;
		*) break ;;
	esac
done
[ "$#" -eq 2 ] || usage
case "$1:$2" in
	*:/|*:/dev|*:/dev/*|/:*|/dev:*|/dev/*:*) echo "refusing unsafe path" >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/versions.env"
work_dir=$(mkdir -p -- "$1" && CDPATH= cd -- "$1" && pwd)
output_dir=$(mkdir -p -- "$2" && CDPATH= cd -- "$2" && pwd)
[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
	echo "output directory must be empty: $output_dir" >&2
	exit 1
}

if [ "$validate_only" = no ]; then
	for tool in python3 zstd sha256sum od find awk; do
		command -v "$tool" >/dev/null || {
			echo "missing required tool: $tool" >&2
			exit 1
		}
	done
fi

for forbidden in wifi.conf wifi.txt authorized_keys id_rsa id_ed25519; do
	if find "$script_dir" "$script_dir/../pmaports" -name "$forbidden" \
		-print -quit | grep -q .; then
		echo "refusing credential-like packaging input: $forbidden" >&2
		exit 1
	fi
done

"$script_dir/prepare.sh" "$work_dir"
pmaports_dir="$work_dir/pmaports"
pmbootstrap="$work_dir/pmbootstrap/pmbootstrap.py"
pmb_work="$work_dir/pmbootstrap-work"
pmb_config="$work_dir/pmbootstrap.cfg"
mkdir -p "$pmb_work"
work_version=$(awk '/^work_version = [0-9]+$/ { print $3 }' \
	"$work_dir/pmbootstrap/pmb/config/__init__.py")
case "$work_version" in
	""|*[!0-9]*) echo "could not read pinned pmbootstrap work version" >&2; exit 1 ;;
esac
printf '%s\n' "$work_version" >"$pmb_work/version"

# ccache_size is 2G, not 5G: CI carries this cache between runs as a single
# archive, and restoring/saving the extra gigabytes costs more wall clock than
# the extra hits buy. One kernel build's objects are a few hundred MB, so 2G
# still holds several generations and ccache's LRU keeps the newest.
#
# accountsservice<999 / libaccountsservice<999: TEMPORARY pin. The pmOS
# systemd repo's accountsservice fork (999923.13.9) ships a typelib that
# references libaccountsservice.so.0 while the gdm/gnome-shell-mobile
# consumers link .so.1, so gnome-shell's JS init throws on a fresh install.
# Alpine edge's accountsservice (26.27.3) is the hardware-verified fix
# (2026-08-19). apk always prefers the highest version across repos, and the
# fork's 9999-prefixed version outranks Alpine's, so an unpinned world would
# silently take the fork; the <999 constraint excludes every 9999-fork
# version while letting Alpine's own upgrades through. pmbootstrap passes
# extra_packages verbatim to `apk add` inside the rootfs chroot, and apk
# writes the constraint string into /etc/apk/world, where it also survives
# on-device `apk upgrade` (world constraints are sticky). Drop both entries
# once the pmOS fork ships a typelib matching its library soname.
cat >"$pmb_config" <<EOF
[pmbootstrap]
aports = $pmaports_dir
boot_size = 512
build_default_device_arch = True
ccache_size = 2G
device = daylight-jagar
extra_packages = e2fsprogs-extra,mesa-dri-gallium,font-dejavu,accountsservice<999,libaccountsservice<999
is_default_channel = False
jobs = 4
kernel = edge
keymap =
locale = en_US.UTF-8
mirror_alpine = http://dl-cdn.alpinelinux.org/alpine/
mirror_postmarketos = http://mirror.postmarketos.org/postmarketos/
nonfree_firmware = False
qemu_size = 1024M
ssh_keys = False
timezone = UTC
ui = gnome-mobile
user = dc1
work = $pmb_work
EOF

pmb() {
	if [ "$(id -u)" -eq 0 ]; then
		python3 "$pmbootstrap" --as-root --config "$pmb_config" \
			--aports "$pmaports_dir" "$@"
	else
		python3 "$pmbootstrap" --config "$pmb_config" \
			--aports "$pmaports_dir" "$@"
	fi
}

# This command allowlist is intentionally incapable of deploying an artifact.
pmb apkbuild_parse device-daylight-jagar >/dev/null
pmb apkbuild_parse linux-postmarketos-mediatek-mt6789 >/dev/null
pmb apkbuild_parse mutter-mobile >/dev/null
if [ "$verify_sources" = yes ]; then
	pmb checksum --verify device-daylight-jagar \
		linux-postmarketos-mediatek-mt6789 mutter-mobile
fi
if [ "$validate_only" = yes ]; then
	echo "validated pinned postmarketOS package metadata"
	exit 0
fi

pmb build --arch=aarch64 mutter-mobile
pmb build --arch=aarch64 linux-postmarketos-mediatek-mt6789
pmb build --arch=aarch64 device-daylight-jagar

# --password is not optional in an automated build: without it, pmbootstrap
# calls getpass() and an unattended run stops at a prompt nobody can answer.
# The value is a build placeholder, recorded in PROVENANCE and meant to be
# changed on first boot. The image ships with sshd disabled (--no-sshd writes
# a "disable sshd.service" preset that overrides the base enable) and a locked
# root account, so it is not a remotely reachable credential. The installer's
# provision.sh enables sshd -- unconditionally, it is the recovery channel when
# the desktop fails -- only after a real password hash replaces this
# placeholder; keep that ordering if either side changes.
pmb install --no-image --no-sshd --no-firewall --no-recommends \
	--password "${PMOS_BUILD_PASSWORD:-postmarketos}"

# install leaves the chroot active, with pmbootstrap's own state (including
# the local abuild signing key) bind-mounted under mnt/pmbootstrap. Unmount
# it all before the export stage reads the tree; the exporter's credential
# tripwire rejects the tree otherwise, and rightly so.
pmb shutdown

rootfs_dir="$pmb_work/chroot_rootfs_daylight-jagar"
[ -d "$rootfs_dir" ] || {
	echo "pmbootstrap rootfs not found at pinned layout: $rootfs_dir" >&2
	exit 1
}
# The chroot pmbootstrap installs into contains root-owned mode-0600 files
# (e.g. /etc/.pwd.lock), so a rootless build still needs privilege to read
# the tree back out. Elevate only the export stage and return ownership of
# the outputs to the invoking user.
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null; then
	sudo sh "$script_dir/export-artifacts.sh" \
		"$rootfs_dir" "$pmb_work/packages" "$work_dir/SOURCES" "$output_dir"
	sudo chown -R "$(id -u):$(id -g)" "$output_dir"
else
	sh "$script_dir/export-artifacts.sh" \
		"$rootfs_dir" "$pmb_work/packages" "$work_dir/SOURCES" "$output_dir"
fi

echo "wrote non-deployable rootfs, packages, and manifests to $output_dir"
