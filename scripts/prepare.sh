#!/bin/sh
set -eu

usage() {
	echo "usage: $0 WORK_DIRECTORY" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
	""|/|/dev|/dev/*) echo "refusing unsafe work directory: $1" >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay_dir=$(CDPATH= cd -- "$script_dir/../pmaports" && pwd)
. "$script_dir/versions.env"
work_dir=$(mkdir -p -- "$1" && CDPATH= cd -- "$1" && pwd)
pmaports_dir="$work_dir/pmaports"
pmbootstrap_dir="$work_dir/pmbootstrap"

prepare_checkout() {
	directory=$1
	url=$2
	commit=$3
	allow_overlay=${4:-no}
	if [ ! -d "$directory/.git" ]; then
		git clone --filter=blob:none "$url" "$directory"
	fi
	actual_url=$(git -C "$directory" remote get-url origin)
	[ "$actual_url" = "$url" ] || {
		echo "$directory has unexpected origin: $actual_url" >&2
		exit 1
	}
	if [ "$allow_overlay" = yes ]; then
		git -C "$directory" status --porcelain | while IFS= read -r line; do
			path=${line#???}
			case "$path" in
				device/testing/dc1-ui/*|\
				device/testing/device-daylight-jagar/*|\
				device/testing/linux-postmarketos-mediatek-mt6789/*) ;;
				*) echo "$directory has unrelated local change: $path" >&2; exit 1 ;;
			esac
		done
	else
		[ -z "$(git -C "$directory" status --porcelain)" ] || {
			echo "$directory has local changes; refusing to overwrite them" >&2
			exit 1
		}
	fi
	git -C "$directory" fetch --depth=1 origin "$commit"
	git -C "$directory" checkout --detach "$commit"
	[ "$(git -C "$directory" rev-parse HEAD)" = "$commit" ]
}

prepare_checkout "$pmaports_dir" \
	https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS_COMMIT" yes
prepare_checkout "$pmbootstrap_dir" \
	https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git "$PMBOOTSTRAP_COMMIT"

# The upstream checkout is pinned and disposable. Copy only this tracked overlay.
# dc1-ui is copied the same way, but note that its payload/ (the Flutter
# bundle and dc1-backend) is staged into the checkout AFTERWARDS by
# scripts/build-ui-payload.sh -- this rm -rf is what keeps a stale payload
# from a previous run out of the package.
rm -rf -- \
	"$pmaports_dir/device/testing/dc1-ui" \
	"$pmaports_dir/device/testing/device-daylight-jagar" \
	"$pmaports_dir/device/testing/linux-postmarketos-mediatek-mt6789"
cp -R "$overlay_dir/device/testing/dc1-ui" \
	"$pmaports_dir/device/testing/"
cp -R "$overlay_dir/device/testing/device-daylight-jagar" \
	"$pmaports_dir/device/testing/"
cp -R "$overlay_dir/device/testing/linux-postmarketos-mediatek-mt6789" \
	"$pmaports_dir/device/testing/"

printf 'pmaports=%s\npmbootstrap=%s\nkernel=%s\n' \
	"$PMAPORTS_COMMIT" "$PMBOOTSTRAP_COMMIT" "$KERNEL_COMMIT" \
	>"$work_dir/SOURCES"
echo "prepared pinned postmarketOS sources in $work_dir"
