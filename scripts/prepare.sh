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
	# Only the pinned commit is ever checked out, so never fetch the history
	# that leads to it: init an empty repository and let the depth-1 fetch
	# below bring in that one commit. A blobless clone of pmaports still
	# walks every commit and tree it ever had, which is most of this step.
	if [ ! -d "$directory/.git" ]; then
		git init -q "$directory"
		git -C "$directory" remote add origin "$url"
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
				device/testing/device-daylight-jagar/*|\
				device/testing/linux-postmarketos-mediatek-mt6789/*|\
				device/testing/mutter-mobile/*) ;;
				*) echo "$directory has unrelated local change: $path" >&2; exit 1 ;;
			esac
		done
	else
		[ -z "$(git -C "$directory" status --porcelain)" ] || {
			echo "$directory has local changes; refusing to overwrite them" >&2
			exit 1
		}
	fi
	# Fetch both the pinned commit and the main branch tip. The commit fetch
	# brings in the exact tree we need; the main fetch makes origin/main exist
	# so that pmbootstrap's init can read channels.cfg from it.
	git -C "$directory" fetch --depth=1 origin "$commit" main
	git -C "$directory" checkout --detach "$commit"
	[ "$(git -C "$directory" rev-parse HEAD)" = "$commit" ]
}

prepare_checkout "$pmaports_dir" \
	https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS_COMMIT" yes
prepare_checkout "$pmbootstrap_dir" \
	https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git "$PMBOOTSTRAP_COMMIT"

# The upstream checkout is pinned and disposable. Copy only this tracked overlay.
rm -rf -- \
	"$pmaports_dir/device/testing/device-daylight-jagar" \
	"$pmaports_dir/device/testing/linux-postmarketos-mediatek-mt6789"
rm -rf -- \
	"$pmaports_dir/temp/mutter-mobile" \
	"$pmaports_dir/extra-repos/systemd/mutter-mobile"
cp -R "$overlay_dir/device/testing/device-daylight-jagar" \
	"$pmaports_dir/device/testing/"
cp -R "$overlay_dir/device/testing/linux-postmarketos-mediatek-mt6789" \
	"$pmaports_dir/device/testing/"
mkdir -p "$pmaports_dir/extra-repos/systemd"
cp -R "$overlay_dir/device/testing/mutter-mobile" \
	"$pmaports_dir/extra-repos/systemd/"

printf 'pmaports=%s\npmbootstrap=%s\nkernel=%s\n' \
	"$PMAPORTS_COMMIT" "$PMBOOTSTRAP_COMMIT" "$KERNEL_COMMIT" \
	>"$work_dir/SOURCES"
echo "prepared pinned postmarketOS sources in $work_dir"
