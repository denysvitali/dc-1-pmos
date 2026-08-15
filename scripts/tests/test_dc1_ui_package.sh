#!/bin/sh
# Offline checks for the dc1-ui package and the build wiring that feeds it.
# No root, no network, no toolchain: everything here is text assertions plus
# a synthetic payload tree driven through the real assertion code.
#
# The two things this exists to stop:
#   * the shipped rootfs growing a Flutter build toolchain (flutter-desktop
#     pulls dart-sdk; it is ~2 GB on a device whose root is written over
#     fastboot), or losing the runtime embedder entirely;
#   * the flutter-gtk pin drifting between the APKBUILD, the chroot build
#     script and the size/SHA-256 record, so that "pinned" stops meaning
#     pinned in one of the three places nobody rereads.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
overlay="$root/pmaports/device/testing"
aport="$overlay/dc1-ui"
scripts="$root/scripts"

fail() { echo "dc1-ui package test failed: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# --- the package recipe --------------------------------------------------
for file in APKBUILD dc1-backend.initd dc1-backend.confd dc1-ui-session \
		dc1-ui.sway.conf dc1-ui.post-install dc1-ui.post-upgrade; do
	[ -f "$aport/$file" ] || fail "missing $aport/$file"
done
sh -n "$aport/APKBUILD" || fail "dc1-ui APKBUILD is not sh -n clean"
sh -n "$aport/dc1-ui-session" || fail "dc1-ui-session is not sh -n clean"
sh -n "$aport/dc1-ui.post-install" || fail "post-install is not sh -n clean"
sh -n "$aport/dc1-ui.post-upgrade" || fail "post-upgrade is not sh -n clean"

grep -qx 'arch="aarch64"' "$aport/APKBUILD" || fail "dc1-ui is not aarch64-only"

# --- the flutter-gtk pin, in all three places ----------------------------
pin=3.38.4-r2
grep -qF "flutter-gtk=$pin" "$aport/APKBUILD" ||
	fail "APKBUILD does not pin flutter-gtk to exactly $pin"
# A bare dependency is the failure this guards: it resolves today and
# silently follows Alpine edge onto an engine ABI the bundle is not built
# for, which is a black screen with no log line.
! grep -qE '^[[:space:]]*flutter-gtk[[:space:]]*$' "$aport/APKBUILD" ||
	fail "APKBUILD has an unpinned flutter-gtk dependency"
grep -qF "FLUTTER_GTK_VERSION=$pin" "$scripts/verify-flutter-gtk.sh" ||
	fail "verify-flutter-gtk.sh does not pin $pin"
grep -qF "FLUTTER_DESKTOP_VERSION=$pin" "$scripts/build-flutter-ui.sh" ||
	fail "build-flutter-ui.sh builds against a different version than $pin"

# The pin must be a recorded measurement, not a placeholder: a decimal size
# and 64 lowercase hex digits, in the same shape installer/build.sh uses for
# the MT7902 firmware.
size=$(sed -n 's/^FLUTTER_GTK_SIZE=\([0-9][0-9]*\)$/\1/p' "$scripts/verify-flutter-gtk.sh")
[ -n "$size" ] && [ "$size" -gt 1000000 ] ||
	fail "FLUTTER_GTK_SIZE is missing or implausible: '$size'"
sha=$(sed -n 's/^FLUTTER_GTK_SHA256=\([0-9a-f]*\)$/\1/p' "$scripts/verify-flutter-gtk.sh")
[ "${#sha}" -eq 64 ] || fail "FLUTTER_GTK_SHA256 is not 64 hex digits: '$sha'"
grep -qF 'edge/testing/aarch64' "$scripts/verify-flutter-gtk.sh" ||
	fail "flutter-gtk is not fetched from Alpine edge/testing/aarch64"
grep -qF 'sha256sum' "$scripts/verify-flutter-gtk.sh" ||
	fail "the flutter-gtk pin does not check a SHA-256"

# --- what the shipped rootfs may and may not contain ---------------------
# The installed package set is extra_packages plus every overlay package's
# depends. flutter-gtk must be in it (nothing renders otherwise) and the
# build-time-only Flutter toolchain must not be (that is the ~2 GB the
# chroot carries and the device does not).
extra=$(sed -n 's/^extra_packages = //p' "$scripts/build-rootfs.sh" | tr ',' ' ')
[ -n "$extra" ] || fail "could not read extra_packages from build-rootfs.sh"
shipped="$extra"
for package in dc1-ui device-daylight-jagar linux-postmarketos-mediatek-mt6789; do
	shipped="$shipped $(sed -n '/^depends="/,/^[[:space:]]*"/p' \
		"$overlay/$package/APKBUILD" | sed 's/depends="//; s/"//')"
done
case " $(echo "$shipped" | tr -s ' \t\n' ' ') " in
	*" dc1-ui "*) : ;;
	*) fail "dc1-ui is not installed into the rootfs (extra_packages)" ;;
esac
case " $(echo "$shipped" | tr -s ' \t\n' ' ') " in
	*" flutter-gtk=$pin "*) : ;;
	*) fail "the shipped package set does not include flutter-gtk=$pin" ;;
esac
for forbidden in flutter-desktop flutter-common flutter-tool dart-sdk; do
	case " $(echo "$shipped" | tr -s ' \t\n' ' ') " in
		*" $forbidden "*|*" $forbidden="*)
			fail "build-time-only package in the shipped rootfs: $forbidden" ;;
	esac
	grep -q "$forbidden" "$scripts/build-rootfs.sh" &&
		fail "build-rootfs.sh references the build-only package $forbidden" || :
done

# --- checksums of every local source, for all three overlay packages -----
# scripts/verify.sh only checks deviceinfo's sha512sum; every other entry is
# unverified until abuild runs an hour into the aarch64 job. Close that here.
for package in dc1-ui device-daylight-jagar linux-postmarketos-mediatek-mt6789; do
	apkbuild="$overlay/$package/APKBUILD"
	sed -n '/^sha512sums="/,/^"/p' "$apkbuild" |
		sed '1d; $d' | while read -r want name; do
			[ -n "${name:-}" ] || continue
			[ -f "$overlay/$package/$name" ] || continue
			actual=$(sha512sum "$overlay/$package/$name" | awk '{ print $1 }')
			[ "$want" = "$actual" ] || {
				echo "dc1-ui package test failed: $package/$name checksum mismatch" >&2
				echo "  APKBUILD: $want" >&2
				echo "  actual:   $actual" >&2
				exit 1
			}
		done || exit 1
done

# --- the control plane never listens on TCP ------------------------------
# Same rule the debug shell follows (nc bound to 172.16.42.1, never
# 0.0.0.0): the USB host and any Wi-Fi peer must not reach onboarding.
if grep -nE '(-p|--port|0\.0\.0\.0|127\.0\.0\.1|localhost|tcp)' \
		"$aport/dc1-backend.initd" "$aport/dc1-backend.confd" >/dev/null; then
	grep -nE '(-p|--port|0\.0\.0\.0|127\.0\.0\.1|localhost|tcp)' \
		"$aport/dc1-backend.initd" "$aport/dc1-backend.confd" >&2
	fail "the dc1-backend service references a TCP endpoint"
fi
grep -qF -- '-socket ' "$aport/dc1-backend.initd" ||
	fail "the service does not pass a unix socket path to dc1-backend"
grep -qF '/run/dc1-ui.sock' "$aport/dc1-backend.initd" ||
	fail "socket path drift in the dc1-backend service"
# The backend creates the socket 0600 root:root; without the group handover
# the shell gets EACCES and silently falls back to first light.
grep -qF 'chgrp' "$aport/dc1-backend.initd" ||
	fail "the service never hands the socket to the desktop user's group"
grep -qF 'chmod 0660' "$aport/dc1-backend.initd" ||
	fail "socket permissions drift (must be 0660, never world-writable)"
# The shell samples the socket once at startup and draws first light if it is
# missing, so a display manager started before this service costs onboarding
# with no log line. tinydm provides the display-manager virtual.
grep -qE '^[[:space:]]*before[[:space:]]+(display-manager|tinydm)' \
	"$aport/dc1-backend.initd" ||
	fail "dc1-backend is not ordered before the display manager (socket race)"

# --- the session wrapper owns the policy, the sway drop-in does not ------
grep -qF 'exec /usr/bin/dc1-ui-session' "$aport/dc1-ui.sway.conf" ||
	fail "the sway drop-in does not launch the session wrapper"
[ "$(grep -c '^exec ' "$aport/dc1-ui.sway.conf")" -eq 1 ] ||
	fail "the sway drop-in must contain exactly one exec line"
# The window rules are keyed on the app_id the build bakes into the runner,
# and the two live in different files. Derive the id from the build script so
# changing it there without changing the rule here is a test failure and not a
# title bar in front of somebody's first boot.
app_id=$(sed -n 's/^APPLICATION_ID=\([^ ]*\)$/\1/p' "$scripts/build-flutter-ui.sh")
[ -n "$app_id" ] || fail "build-flutter-ui.sh no longer sets APPLICATION_ID"
# Sway criteria are regexes, so the committed rule escapes the dots; strip the
# backslashes before comparing against the literal id.
grep '^for_window ' "$aport/dc1-ui.sway.conf" | tr -d '\\' |
	grep -qF "app_id=\"^$app_id\$\"" ||
	fail "no sway window rule matches the built app_id ($app_id)"

# apk on the device cannot verify any index unless the signing keys are linked
# into /etc/apk/keys, and that has to happen on BOTH a fresh install and an
# upgrade. It lived in post-install only, so every already-installed device
# stayed unable to run `apk upgrade`, permanently and silently.
dev="$overlay/device-daylight-jagar"
[ -x "$dev/dc1-link-apk-keys" ] || fail "dc1-link-apk-keys is missing or not executable"
for hook in post-install post-upgrade; do
	grep -qF '/usr/libexec/dc1-link-apk-keys' "$dev/device-daylight-jagar.$hook" ||
		fail "device-daylight-jagar.$hook does not link the apk signing keys"
done
grep -qF 'usr/libexec/dc1-link-apk-keys' "$dev/APKBUILD" ||
	fail "the device package does not install dc1-link-apk-keys"

# dc1-backend's /screenshot endpoint shells out to grim; without the package
# the endpoint 503s on every device and the only way to see the panel goes
# back to being a photograph.
grep -qF 'grim' "$aport/APKBUILD" ||
	fail "dc1-ui does not depend on grim, which /screenshot shells out to"
grep -qF 'grim' "$root/ui/backend/internal/screen/screen.go" ||
	fail "the capture path no longer uses grim; the dependency above is now wrong"

# The build writes the commit into the payload, the package installs it, and
# dc1-backend reads it back to serve GET /status. Three files, one path: if
# they drift the footer silently reads "unknown build" on every device, which
# is precisely the state this feature exists to end, and nothing else fails.
backend_path=$(sed -n 's/^const VersionPath = "\(.*\)"$/\1/p' \
	"$root/ui/backend/internal/server/server.go")
[ -n "$backend_path" ] ||
	fail "dc1-backend no longer declares VersionPath"
grep -qF "\"\$pkgdir\"/$backend_path" "$aport/APKBUILD" ||
	fail "the APKBUILD does not install the version file to /$backend_path (the path dc1-backend reads)"

grep -qF 'GDK_BACKEND=wayland' "$aport/dc1-ui-session" ||
	fail "the wrapper does not force the Wayland GDK backend"
grep -qF 'MESA_LOADER_DRIVER_OVERRIDE=panfrost' "$aport/dc1-ui-session" ||
	fail "the wrapper does not select the Panfrost driver"
grep -qF 'WLR_RENDERER=gles2' "$aport/dc1-ui-session" ||
	fail "the wrapper does not select the GLES2 renderer"
grep -qF 'unset WLR_RENDERER_ALLOW_SOFTWARE' "$aport/dc1-ui-session" ||
	fail "the wrapper leaves the llvmpipe escape hatch open"
grep -qF '/var/lib/dc1-installer/provisioned' "$aport/dc1-ui-session" ||
	fail "the wrapper does not gate onboarding on the provisioned marker"
grep -qF 'exec /usr/lib/dc1-ui/dc1_shell' "$aport/dc1-ui-session" ||
	fail "the wrapper does not launch the bundle runner (binary name drift)"

# --- what the package installs -------------------------------------------
grep -qF '"$pkgdir"/usr/sbin/dc1-backend' "$aport/APKBUILD" ||
	fail "dc1-backend is not installed to /usr/sbin"
grep -qF '"$pkgdir"/usr/lib/dc1-ui/' "$aport/APKBUILD" ||
	fail "the bundle is not installed to /usr/lib/dc1-ui/"
grep -qF '/etc/sway/config.d/10-dc1-ui.conf' "$aport/APKBUILD" ||
	fail "the sway drop-in is not installed (or lost its 10- ordering)"
# !tracedeps keeps abuild from scanning the prebuilt payload at all: nothing
# is published (no so:libapp.so in the global namespace) and no DT_NEEDED is
# resolved against a build chroot that lacks the GTK stack (CI run
# 31824800838). A somask="libapp.so" alone covers only the publish half.
grep -qE '^options="[^"]*!tracedeps' "$aport/APKBUILD" ||
	fail "prebuilt payload needs options=!tracedeps (soname publish + trace both wrong)"
# The bundle's own copy of the embedder is dropped in favour of the pinned
# flutter-gtk apk; keeping both is how two files that must not diverge do.
grep -qF 'rm -f "$pkgdir"/usr/lib/dc1-ui/lib/libflutter_linux_gtk.so' \
	"$aport/APKBUILD" ||
	fail "the package ships a second copy of libflutter_linux_gtk.so"
# abuild's error() only prints: its body ends in logcmd, which returns 0. An
# assertion written with it announces a half-written payload and then packages
# it anyway; die() is the one that exits.
! grep -nE '(^|[[:space:]])error[[:space:]]+"' "$aport/APKBUILD" ||
	fail "dc1-ui APKBUILD asserts with abuild's fail-open error(); use die"
grep -qF 'die "payload/ is missing' "$aport/APKBUILD" ||
	fail "the payload assertions no longer abort the build"
[ ! -d "$aport/payload" ] ||
	fail "a build payload is committed under pmaports/ (it carries a *.bin asset)"
! find "$aport" -name '*.so' -print -quit | grep -q . ||
	fail "a compiled library is committed under pmaports/device/testing/dc1-ui"

# --- the build wiring reaches the new package ----------------------------
grep -qF 'pmb build --force --arch=aarch64 dc1-ui' "$scripts/build-rootfs.sh" ||
	fail "build-rootfs.sh no longer force-rebuilds dc1-ui (stale payload risk)"
grep -qF 'build-ui-payload.sh' "$scripts/build-rootfs.sh" ||
	fail "build-rootfs.sh never stages the dc1-ui payload"
grep -qF 'device/testing/dc1-ui' "$scripts/prepare.sh" ||
	fail "prepare.sh does not copy the dc1-ui overlay into the pinned checkout"
grep -qF 'dc1-ui' "$scripts/export-artifacts.sh" ||
	fail "export-artifacts.sh does not publish the dc1-ui apk"

# --- payload assertions: positive control, then refusals -----------------
# The bundle is a build artifact, so the only thing that can be tested
# offline is the code that decides whether a bundle is complete. Drive it
# over a synthetic tree: an empty or half-written payload produces a package
# that installs cleanly and shows nothing on the panel.
elf() {
	# ELF magic, then e_type at 16 and e_machine (0xB7 = EM_AARCH64) at 18.
	printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\267\000' \
		>"$1"
	printf 'padding to a non-trivial size\n' >>"$1"
}

make_payload() {
	mp=$1
	rm -rf "$mp"
	mkdir -p "$mp/bundle/lib" "$mp/bundle/data/flutter_assets/fonts"
	elf "$mp/dc1-backend"
	elf "$mp/bundle/dc1_shell"
	elf "$mp/bundle/lib/libapp.so"
	elf "$mp/bundle/lib/libflutter_linux_gtk.so"
	printf '%s\n' 0123456789abcdef0123456789abcdef01234567 >"$mp/version"
	printf 'icu\n' >"$mp/bundle/data/icudtl.dat"
	printf 'font\n' >"$mp/bundle/data/flutter_assets/fonts/MaterialIcons"
	chmod 755 "$mp/dc1-backend" "$mp/bundle/dc1_shell"
}

checker="$scripts/build-ui-payload.sh"
make_payload "$tmp/payload"
sh "$checker" --check-payload "$tmp/payload" >/dev/null ||
	fail "the payload checker rejects a complete payload (positive control)"

make_payload "$tmp/payload"
rm -f "$tmp/payload/bundle/dc1_shell"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with no runner was accepted"

make_payload "$tmp/payload"
: >"$tmp/payload/bundle/lib/libapp.so"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with an empty libapp.so was accepted"

# Without this the onboarding footer says "unknown build" and a photograph of
# a device stops identifying what is on it.
make_payload "$tmp/payload"
rm -f "$tmp/payload/version"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with no version file was accepted"

make_payload "$tmp/payload"
rm -f "$tmp/payload/bundle/data/icudtl.dat"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with no icudtl.dat was accepted"

make_payload "$tmp/payload"
# Present but zero length: an interrupted copy leaves exactly this, and the
# ELF checks below do not cover a data file.
: >"$tmp/payload/bundle/data/icudtl.dat"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with an empty icudtl.dat was accepted"

make_payload "$tmp/payload"
find "$tmp/payload/bundle/data/flutter_assets" -type f -exec rm -f {} +
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with empty flutter_assets was accepted"

make_payload "$tmp/payload"
# x86-64 e_machine (0x3E) where aarch64 is expected: this is the glibc/x86
# build the whole chroot detour exists to prevent.
printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\076\000' \
	>"$tmp/payload/bundle/dc1_shell"
chmod 755 "$tmp/payload/bundle/dc1_shell"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with a non-aarch64 runner was accepted"

make_payload "$tmp/payload"
chmod 644 "$tmp/payload/dc1-backend"
! sh "$checker" --check-payload "$tmp/payload" >/dev/null 2>&1 ||
	fail "a payload with a non-executable dc1-backend was accepted"

echo "dc1-ui package tests passed"
