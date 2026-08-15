#!/bin/sh
# build-ui-payload.sh -- produce everything the dc1-ui package installs and
# stage it into the pinned pmaports checkout, ready for `pmb build dc1-ui`.
#
#   sh scripts/build-ui-payload.sh WORK_DIRECTORY
#   sh scripts/build-ui-payload.sh --check-payload PAYLOAD_DIRECTORY
#
# WORK_DIRECTORY is the one build-rootfs.sh already prepared: it must hold
# the pinned pmaports/ and pmbootstrap/ checkouts and the generated
# pmbootstrap.cfg.
#
# Two payload members, built two different ways for two different reasons:
#
#   payload/dc1-backend   a static aarch64 Go binary, cross-built on the
#                         runner (no libc to get wrong).
#   payload/bundle/       the Flutter release bundle, built INSIDE the
#                         pmbootstrap aarch64 chroot, because a glibc-hosted
#                         `flutter build` emits a runner that cannot load
#                         Alpine's musl libflutter_linux_gtk.so.
#
# The staged payload lives in the pinned, disposable upstream checkout and
# never in this repository's own pmaports/ overlay: the bundle contains
# data/flutter_assets/AssetManifest.bin, and a committed *.bin under
# pmaports/ is exactly what scripts/verify.sh refuses (it is how a firmware
# blob would sneak in).
set -eu

fatal() {
	echo "build-ui-payload: $*" >&2
	exit 1
}

# Assert that a directory is a complete dc1-ui payload. Split out and
# reachable on its own so the offline test can drive it over synthetic trees:
# every one of these members is something whose absence produces a package
# that installs cleanly and then shows nothing on the panel.
check_payload() {
	cp_dir=$1
	[ -d "$cp_dir" ] || fatal "payload directory missing: $cp_dir"
	for cp_member in dc1-backend version bundle/dc1_shell bundle/lib/libapp.so \
			bundle/lib/libflutter_linux_gtk.so bundle/data/icudtl.dat; do
		[ -f "$cp_dir/$cp_member" ] || fatal "payload is missing $cp_member"
		[ -s "$cp_dir/$cp_member" ] || fatal "payload member is empty: $cp_member"
	done
	[ -x "$cp_dir/bundle/dc1_shell" ] || fatal "payload runner is not executable"
	[ -x "$cp_dir/dc1-backend" ] || fatal "payload dc1-backend is not executable"
	[ -d "$cp_dir/bundle/data/flutter_assets" ] ||
		fatal "payload is missing bundle/data/flutter_assets/"
	[ -n "$(find "$cp_dir/bundle/data/flutter_assets" -type f -print -quit)" ] ||
		fatal "payload bundle/data/flutter_assets/ is empty"
	for cp_elf in dc1-backend bundle/dc1_shell bundle/lib/libapp.so; do
		cp_machine=$(od -An -tx1 -j18 -N2 "$cp_dir/$cp_elf" | tr -d ' \n')
		[ "$cp_machine" = b700 ] ||
			fatal "$cp_elf is not aarch64 (e_machine=$cp_machine)"
	done
	echo "payload verified: $cp_dir"
}

if [ "${1:-}" = --check-payload ]; then
	[ "$#" -eq 2 ] || { echo "usage: $0 --check-payload PAYLOAD_DIRECTORY" >&2; exit 2; }
	check_payload "$2"
	exit 0
fi

[ "$#" -eq 1 ] || { echo "usage: $0 WORK_DIRECTORY" >&2; exit 2; }
case "$1" in
	""|/|/dev|/dev/*) echo "refusing unsafe work directory: $1" >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
work_dir=$(CDPATH= cd -- "$1" && pwd)
pmaports_dir="$work_dir/pmaports"
pmbootstrap="$work_dir/pmbootstrap/pmbootstrap.py"
pmb_work="$work_dir/pmbootstrap-work"
pmb_config="$work_dir/pmbootstrap.cfg"
aport_dir="$pmaports_dir/device/testing/dc1-ui"

for path in "$pmbootstrap" "$pmb_config" "$aport_dir/APKBUILD"; do
	[ -e "$path" ] || fatal "run scripts/prepare.sh first: missing $path"
done

pmb() {
	if [ "$(id -u)" -eq 0 ]; then
		python3 "$pmbootstrap" --as-root --config "$pmb_config" \
			--aports "$pmaports_dir" "$@"
	else
		python3 "$pmbootstrap" --config "$pmb_config" \
			--aports "$pmaports_dir" "$@"
	fi
}

# pmbootstrap builds its chroots as root even from an unprivileged invocation,
# so staging files in and out of one needs privilege. Same escalation shape as
# export-artifacts.sh: elevate only when the tree is genuinely unreadable.
as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null; then
		sudo -n "$@"
	else
		fatal "staging into the chroot needs root and no non-interactive sudo is available"
	fi
}

# Cheap and first: a five megabyte download that fails the whole run in
# seconds if the embedder the bundle is built against has moved, rather than
# after a chroot Flutter build.
sh "$script_dir/verify-flutter-gtk.sh" "$work_dir/cache_ui"

payload_dir="$aport_dir/payload"
as_root rm -rf -- "$payload_dir"
mkdir -p "$payload_dir"

sh "$script_dir/build-backend.sh" "$payload_dir/dc1-backend"

# The commit this UI was built from, shown in the onboarding footer so a
# photograph of a device is enough to identify the build on it. dc1-backend
# reads it from usr/share/dc1-ui/version and serves it on GET /status.
#
# Determined, never guessed: an unknown commit is a build fault, not a value
# to invent. Writing a placeholder would be indistinguishable, on the panel,
# from a real build that recorded that placeholder. GITHUB_SHA covers CI,
# where the checkout is detached and `git rev-parse HEAD` would name the
# merge commit rather than the pushed one.
version=${DC1_VERSION:-${GITHUB_SHA:-}}
if [ -z "$version" ]; then
	version=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
	# A local build with edits in the tree is not the commit it names.
	[ -z "$version" ] ||
		git -C "$repo_dir" diff --quiet HEAD 2>/dev/null ||
		version="$version-dirty"
fi
[ -n "$version" ] ||
	fatal "cannot determine the commit to record as the UI version: set
	DC1_VERSION, or build from a git checkout"
printf '%s\n' "$version" >"$payload_dir/version"

# `pmb chroot -b aarch64` resolves to the native chroot on an aarch64 host --
# pmb.core.chroot.Chroot collapses a buildroot whose arch is the host arch --
# and to chroot_buildroot_aarch64 (qemu) elsewhere. Derive the same path so
# sources can be staged in and the bundle read back out; assert it exists
# rather than trusting the derivation.
pmb build_init -b aarch64
case "$(uname -m)" in
	aarch64) chroot_dir="$pmb_work/chroot_native" ;;
	*) chroot_dir="$pmb_work/chroot_buildroot_aarch64" ;;
esac
# /bin/sh as a symlink is pmbootstrap's own Chroot.exists() invariant
# (pmb/core/chroot.py); /etc/alpine-release is NOT present, because build
# chroots never install the alpine-release package (broke CI run 31824170263).
[ -h "$chroot_dir/bin/sh" ] ||
	fatal "no initialised aarch64 chroot at $chroot_dir (pmbootstrap layout changed?)"

# build-flutter-ui.sh resolves the app sources relative to itself, so the
# scripts/ and ui/ layout has to be preserved inside the chroot. Copy only
# those two paths -- never the whole checkout, which carries the pmaports
# overlay and the work directory.
chroot_src=/tmp/dc1-ui-src
chroot_out=/tmp/dc1-ui-bundle
as_root rm -rf -- "$chroot_dir$chroot_src" "$chroot_dir$chroot_out"
as_root mkdir -p -- "$chroot_dir$chroot_src/scripts" "$chroot_dir$chroot_src/ui"
as_root cp "$repo_dir/scripts/build-flutter-ui.sh" "$chroot_dir$chroot_src/scripts/"
as_root cp -R "$repo_dir/ui/flutter" "$chroot_dir$chroot_src/ui/flutter"

# --output=stdout: the default is a TUI renderer, and a hosted runner has no
# terminal to render into.
pmb chroot -b aarch64 --output=stdout -- \
	sh "$chroot_src/scripts/build-flutter-ui.sh" "$chroot_out"

[ -d "$chroot_dir$chroot_out" ] || fatal "the chroot build produced no bundle"

# Give the ~2 GB Flutter toolchain back. This is the same chroot the kernel
# and the device package are built in, so leaving dart-sdk, clang21 and cmake
# installed there costs disk on a hosted runner and puts an unexpected
# toolchain in front of the kernel build. Best effort: a failure here is
# housekeeping, not a broken bundle, and must not fail the run.
pmb chroot -b aarch64 --output=stdout -- \
	apk del flutter-desktop binutils musl-dev ||
	echo "build-ui-payload: warning: could not remove the build toolchain" >&2
mkdir -p "$payload_dir/bundle"
as_root cp -R "$chroot_dir$chroot_out/." "$payload_dir/bundle/"
if [ "$(id -u)" -ne 0 ]; then
	as_root chown -R "$(id -u):$(id -g)" "$payload_dir"
fi
as_root rm -rf -- "$chroot_dir$chroot_src" "$chroot_dir$chroot_out"

check_payload "$payload_dir"
echo "staged dc1-ui payload in $payload_dir"
