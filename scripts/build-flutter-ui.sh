#!/bin/sh
# build-flutter-ui.sh -- compile the DC-1 Flutter shell (ui/flutter/dc1_shell)
# into a release bundle.
#
#   sh scripts/build-flutter-ui.sh OUTPUT_DIRECTORY
#
# THIS RUNS INSIDE THE pmbootstrap ALPINE aarch64 CHROOT, e.g.
#
#   pmbootstrap chroot --arch=aarch64 -- sh /mnt/pmos/scripts/build-flutter-ui.sh /tmp/dc1-ui
#
# and NOT on the Ubuntu runner: a glibc-hosted `flutter build` produces a
# glibc-linked runner that cannot load Alpine's musl
# libflutter_linux_gtk.so. Same reason the kernel is built in the chroot.
#
# What is committed and what is generated:
#   committed  ui/flutter/dc1_shell/{lib,pubspec.yaml,analysis_options.yaml}
#   generated  the linux/ GTK runner (flutter create), the bundle
# The generated tree lives in a scratch directory; this script never writes
# into the checkout.
#
# Fail-closed: every step is checked, the toolchain is pinned to an exact apk
# version, and the produced bundle is asserted member by member (an empty or
# half-written bundle that gets packaged is a device that shows nothing).
set -eu

usage() {
	echo "usage: $0 OUTPUT_DIRECTORY" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
	""|/|/dev|/dev/*) echo "refusing unsafe output directory: $1" >&2; exit 2 ;;
esac

# Build-only toolchain: flutter-desktop pulls flutter-common, flutter-tool,
# dart-sdk, clang, cmake, samurai and gtk+3.0-dev. NONE of it is shipped --
# the rootfs gets flutter-gtk (the runtime embedder) only.
FLUTTER_DESKTOP_VERSION=3.38.4-r2
PROJECT_NAME=dc1_shell

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
src_dir=$(CDPATH= cd -- "$script_dir/../ui/flutter/$PROJECT_NAME" && pwd)

fatal() {
	echo "build-flutter-ui: $*" >&2
	exit 1
}

for file in pubspec.yaml analysis_options.yaml lib/main.dart; do
	[ -f "$src_dir/$file" ] || fatal "missing source file: $src_dir/$file"
done

[ -f /etc/alpine-release ] || fatal "not an Alpine chroot (no /etc/alpine-release)"
command -v apk >/dev/null || fatal "apk is not available"
arch=$(uname -m)
[ "$arch" = aarch64 ] || fatal "must run in an aarch64 chroot, not $arch"

output_dir=$(mkdir -p -- "$1" && CDPATH= cd -- "$1" && pwd)
[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
	fatal "output directory must be empty: $output_dir"

# The flutter packages live in Alpine edge/testing, not community. Derive the
# URL from the community line already in the chroot so the mirror stays the
# one pmbootstrap chose; if there is no edge/community line, this chroot is
# not what we think it is and we stop.
repositories=/etc/apk/repositories
if ! grep -q '/edge/testing$' "$repositories" 2>/dev/null; then
	# '#' as the delimiter, not ',': the interval \{0,1\} contains a comma,
	# and busybox sed ends the expression at it ("bad option in
	# substitution expression").
	mirror=$(sed -n 's#^\(https\{0,1\}://[^ ]*\)/edge/community$#\1#p' \
		"$repositories" | head -1)
	[ -n "$mirror" ] ||
		fatal "no Alpine edge/community line in $repositories; cannot locate edge/testing"
	echo "$mirror/edge/testing" >>"$repositories"
	echo "added $mirror/edge/testing (flutter is in edge/testing)"
fi

apk update
apk add "flutter-desktop=$FLUTTER_DESKTOP_VERSION" ||
	fatal "flutter-desktop=$FLUTTER_DESKTOP_VERSION is not available; the pin moved"
command -v flutter >/dev/null || fatal "flutter is not on PATH after apk add"

# clang cannot link without a linker and the musl startup files, and
# flutter-common pulls neither: the CMake compiler test dies with
# "clang++: error: unable to execute command: posix_spawn failed" (that is
# clang failing to exec /usr/bin/ld). Left unpinned on purpose -- these are
# host toolchain packages that never reach the device.
apk add binutils musl-dev

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT INT TERM

# flutter_tools hardcodes CC=clang / CXX=clang++ when it invokes CMake for a
# Linux build, but Alpine's clang21 -- the package flutter-common depends on
# -- installs only the versioned clang-21 / clang++-21. With no unversioned
# names on PATH the build dies in CMake with "CMAKE_CXX_COMPILER not set,
# after EnableLanguage". Shim the two names to the exact version
# flutter-common declares instead of pulling in an unpinned `clang` meta
# package.
shim_dir="$work_dir/bin"
mkdir -p "$shim_dir"
for shim in clang:clang-21 clang++:clang++-21; do
	unversioned=${shim%:*}
	versioned=${shim#*:}
	versioned_path=$(command -v "$versioned") ||
		fatal "$versioned is missing; the clang21 dependency moved"
	ln -sf "$versioned_path" "$shim_dir/$unversioned"
done
PATH="$shim_dir:$PATH"
export PATH

HOME=${HOME:-/root}
export HOME
PUB_CACHE=${PUB_CACHE:-$work_dir/pub-cache}
export PUB_CACHE
FLUTTER_SUPPRESS_ANALYTICS=1
export FLUTTER_SUPPRESS_ANALYTICS

# Telemetry off. Not a correctness property, and the flag has been renamed
# upstream before, so a rejected flag warns instead of failing the build.
flutter config --no-analytics ||
	echo "build-flutter-ui: warning: 'flutter config --no-analytics' was rejected" >&2

project_dir="$work_dir/$PROJECT_NAME"
mkdir -p "$project_dir"
cp -R "$src_dir/lib" "$project_dir/lib"
cp "$src_dir/pubspec.yaml" "$src_dir/analysis_options.yaml" "$project_dir/"

cd "$project_dir"
# Generates the linux/ GTK runner (and its CMake glue) around the committed
# sources. It also rewrites template files, so the committed sources are put
# back afterwards -- the checkout is the source of truth, not the template.
flutter create --platforms=linux --project-name "$PROJECT_NAME" . ||
	fatal "flutter create failed"
[ -f "$project_dir/linux/CMakeLists.txt" ] ||
	fatal "flutter create produced no linux/ runner"
# Alpine's flutter-gtk installs the two runtime artifacts OUTSIDE the engine
# artifact cache (bin/cache/artifacts/engine/linux-arm64*/), so flutter's own
# unpack step never stages them into linux/flutter/ephemeral/ and the build
# dies at install time with "file INSTALL cannot find
# .../linux/flutter/ephemeral/<name>". Seed them by hand -- the unpack step
# adds to that directory, it does not wipe it. Both files are asserted in the
# finished bundle below; the app cannot start without either.
ephemeral="$project_dir/linux/flutter/ephemeral"
mkdir -p "$ephemeral"
for artifact in /usr/lib/flutter/icudtl.dat /usr/lib/libflutter_linux_gtk.so; do
	[ -f "$artifact" ] ||
		fatal "$artifact is missing; the flutter-gtk package layout changed"
	cp "$artifact" "$ephemeral/"
done

rm -rf "$project_dir/lib" "$project_dir/test"
cp -R "$src_dir/lib" "$project_dir/lib"
cp "$src_dir/pubspec.yaml" "$src_dir/analysis_options.yaml" "$project_dir/"

flutter build linux --release || fatal "flutter build linux --release failed"

bundle=
for candidate in "$project_dir"/build/linux/*/release/bundle; do
	[ -d "$candidate" ] || continue
	[ -z "$bundle" ] || fatal "more than one release bundle was produced"
	bundle=$candidate
done
[ -n "$bundle" ] || fatal "flutter build produced no release bundle"
case "$bundle" in
	*/build/linux/arm64/release/bundle) ;;
	*) fatal "bundle is not arm64: $bundle" ;;
esac

# The runner is named after the project, not "app": the Linux template does
# set(BINARY_NAME "{{projectName}}"), so `flutter create --project-name
# dc1_shell` yields bundle/dc1_shell. Whatever launches it (sway config,
# openrc service) must use this name.
for member in "$PROJECT_NAME" lib/libapp.so lib/libflutter_linux_gtk.so; do
	[ -f "$bundle/$member" ] || fatal "bundle is missing $member"
	[ -s "$bundle/$member" ] || fatal "bundle member is empty: $member"
done
[ -x "$bundle/$PROJECT_NAME" ] || fatal "bundle runner is not executable"
[ -d "$bundle/data/flutter_assets" ] ||
	fatal "bundle is missing data/flutter_assets/"
[ -s "$bundle/data/icudtl.dat" ] ||
	fatal "bundle is missing data/icudtl.dat (the app cannot start without it)"
[ -n "$(find "$bundle/data/flutter_assets" -type f -print -quit)" ] ||
	fatal "data/flutter_assets/ is empty"

# The whole point of building in the chroot is the ABI: prove it, do not
# assume it. ELF magic, then e_machine == EM_AARCH64 (0xB7, little endian).
elf_magic=$(od -An -tx1 -N4 "$bundle/$PROJECT_NAME" | tr -d ' \n')
[ "$elf_magic" = 7f454c46 ] || fatal "bundle runner is not an ELF binary"
elf_machine=$(od -An -tx1 -j18 -N2 "$bundle/$PROJECT_NAME" | tr -d ' \n')
[ "$elf_machine" = b700 ] ||
	fatal "bundle runner is not aarch64 (e_machine=$elf_machine)"
elf_machine=$(od -An -tx1 -j18 -N2 "$bundle/lib/libapp.so" | tr -d ' \n')
[ "$elf_machine" = b700 ] ||
	fatal "libapp.so is not aarch64 (e_machine=$elf_machine)"

cp -R "$bundle/." "$output_dir/"
[ -x "$output_dir/$PROJECT_NAME" ] ||
	fatal "copy did not produce $output_dir/$PROJECT_NAME"

echo "flutter bundle written to $output_dir"
ls -1 "$output_dir"
