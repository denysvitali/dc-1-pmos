#!/bin/sh
# Explicit, one-shot local build. No install, shutdown or service operations.
set -eu
[ "$#" -eq 2 ] && [ "$1" = --build ] || {
	printf 'usage: %s --build STAGE\nRun only after the kernel build finishes.\n' "$0" >&2
	exit 2
}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(CDPATH= cd -- "$2" && pwd)
python3 "$repo/scripts/mutter-profile-stage.py" --check "$stage"
# Never accept a caller-selected existing work/cache or follow a symlink there.
mkdir -m 700 "$stage/build"
work="$stage/build"
mkdir "$work/validation"
sh "$repo/scripts/build-rootfs.sh" --validate-only "$work" "$work/validation"
# prepare.sh places Mutter here, not in device/testing. Override only our copy,
# AFTER production preparation; never run prepare again on a profiler stage.
cp "$stage/overlay/"* "$work/pmaports/extra-repos/systemd/mutter-mobile/"
mkdir -p "$work/pmbootstrap-work/cache_distfiles"
cp "$stage/distfiles/"* "$work/pmbootstrap-work/cache_distfiles/"
sh "$repo/scripts/restore-local-apk-key.sh" "$work/pmbootstrap-work"
# Native chroot creation/dependencies may request interactive sudo. Distinct
# work, config, compiler cache, signing key and APK output stay below STAGE.
python3 "$work/pmbootstrap/pmbootstrap.py" --config "$work/pmbootstrap.cfg" \
	--aports "$work/pmaports" build --arch=aarch64 --lax mutter-mobile
printf 'Build finished; local APKs (not installed): %s\n' \
	"$work/pmbootstrap-work/packages/edge/aarch64/"
