#!/bin/sh
# Offline checks for the Flutter shell (ui/flutter/dc1_shell) and its build
# script. There is no dart/flutter toolchain on the CI lint runner -- the app
# is compiled for the first time inside the pmbootstrap aarch64 chroot -- so
# what can be checked here is structure, the transport, and validation
# PARITY: the rules in installer/src/tui.sh, installer/src/provision.sh, the
# frozen host script and this app must not drift apart. A typo caught here
# costs a lint job; the same typo caught on the device costs a boot cycle.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
app="$root/ui/flutter/dc1_shell"
builder="$root/scripts/build-flutter-ui.sh"

fail() { echo "flutter-ui test failed: $*" >&2; exit 1; }

# 1. The build script must be POSIX sh clean, since verify.sh's sh -n list is
#    a hand-maintained enumeration and a new script is easy to forget.
sh -n "$builder" || fail "build-flutter-ui.sh is not sh -n clean"

# 2. Structure: the committed sources are lib/ + pubspec + analysis options.
#    The linux/ runner and the bundle are generated, never committed.
for file in \
	pubspec.yaml \
	analysis_options.yaml \
	.gitignore \
	lib/main.dart \
	lib/first_light.dart \
	lib/backend.dart \
	lib/validation.dart \
	lib/onboarding.dart \
	lib/draft.dart \
	lib/theme.dart \
	lib/widgets.dart \
	lib/keyboard.dart \
	lib/screens/wifi_screen.dart \
	lib/screens/psk_screen.dart \
	lib/screens/username_screen.dart \
	lib/screens/password_screen.dart \
	lib/screens/hostname_screen.dart \
	lib/screens/timezone_screen.dart \
	lib/screens/confirm_screen.dart \
	lib/screens/progress_screen.dart; do
	[ -f "$app/$file" ] || fail "missing $file"
done
[ ! -d "$app/linux" ] || fail "the generated linux/ runner must not be committed"
[ ! -d "$app/build" ] || fail "a build bundle must not be committed"
! find "$app" -name '*.so' -print -quit | grep -q . ||
	fail "a compiled library is committed under ui/flutter/dc1_shell"

# 3. No third-party pub packages: the chroot build must resolve with the
#    Flutter SDK alone. A hosted dependency shows up as a version constraint.
grep -q '^name: dc1_shell$' "$app/pubspec.yaml" || fail "pubspec name drift"
! grep -q '\^' "$app/pubspec.yaml" ||
	fail "pubspec.yaml has a hosted version constraint (third-party package)"
! grep -qE '^\s*(dependency_overrides|hosted|git|path):' "$app/pubspec.yaml" ||
	fail "pubspec.yaml pulls a dependency from outside the SDK"
grep -q 'sdk: flutter' "$app/pubspec.yaml" || fail "pubspec has no SDK dependency"

# 4. Phase 1 first light: the background colour and the title are the whole
#    contract of the smallest verifiable unit.
grep -qF '0xFF101418' "$app/lib/theme.dart" || fail "first-light background drift"
grep -qF "'DC-1'" "$app/lib/first_light.dart" || fail "first-light title drift"
grep -qF 'DC1_FIRST_LIGHT' "$app/lib/main.dart" ||
	fail "main.dart no longer honours DC1_FIRST_LIGHT"
grep -qF 'backendSocketPresent' "$app/lib/main.dart" ||
	fail "main.dart no longer falls back to first light without a backend"

# 5. Transport: Unix socket only. Never TCP -- the USB host and any Wi-Fi
#    peer must not be able to reach the control plane.
grep -qF 'InternetAddressType.unix' "$app/lib/backend.dart" ||
	fail "backend client does not connect over a Unix socket"
grep -qF '/run/dc1-ui.sock' "$app/lib/backend.dart" || fail "socket path drift"
grep -qF 'DC1_BACKEND_SOCKET' "$app/lib/backend.dart" ||
	fail "socket path is not overridable via DC1_BACKEND_SOCKET"
if grep -rnE '127\.0\.0\.1|InternetAddress\.loopback|localhost|ServerSocket|RawSocket\.connect|Socket\.connect\(' \
	"$app/lib" >/dev/null; then
	grep -rnE '127\.0\.0\.1|InternetAddress\.loopback|localhost|ServerSocket|RawSocket\.connect|Socket\.connect\(' \
		"$app/lib" >&2
	fail "a TCP endpoint appears in the UI sources"
fi
for endpoint in /wifi/scan /wifi/connect /onboard /events /finish; do
	grep -qF "'$endpoint'" "$app/lib/backend.dart" ||
		fail "backend client lost the $endpoint endpoint"
done
grep -qF 'LineSplitter' "$app/lib/backend.dart" ||
	fail "the /events stream is no longer parsed line by line (NDJSON)"
# dc1-backend publishes the installer's phrasing ("ONBOARDING COMPLETE",
# "WI-FI CONNECTION FAILED"), so terminal states are matched by substring.
# An equality test against bare COMPLETE/FAILED never fires against the real
# backend and the progress screen hangs on the last intermediate state.
grep -qF "state.contains('FAILED')" "$app/lib/backend.dart" ||
	fail "terminal-state detection no longer matches the backend vocabulary"

# 6. Validation parity with installer/src/tui.sh. These are the literal
#    patterns; if the shell rules move, this test must be updated in the same
#    commit as the Dart, which is exactly the point.
rules="$app/lib/validation.dart"
grep -qF -e "r'^[a-z_]\$'" "$rules" || fail "username single-char rule drift"
grep -qF -e "r'^[a-z_][a-z0-9_-]*\$'" "$rules" || fail "username pattern drift"
grep -qF -e "r'^[a-z0-9]\$'" "$rules" || fail "hostname single-char rule drift"
grep -qF -e "r'^[a-z0-9][a-z0-9-]*\$'" "$rules" || fail "hostname pattern drift"
grep -qF -e "r'^[A-Za-z0-9_+/-]+\$'" "$rules" || fail "timezone charset drift"
grep -qF "<String>['root', 'nobody']" "$rules" ||
	fail "reserved usernames drift (root/nobody)"
grep -qF "byteLength(value) > 32" "$rules" || fail "32-byte cap missing"
grep -qF "byteLength(value) > 63" "$rules" || fail "63-byte cap missing"
grep -qF "length < 8 || length > 63" "$rules" || fail "PSK 8..63 rule drift"
grep -qF "value.contains('..')" "$rules" || fail "timezone '..' rejection drift"
grep -qF "value.startsWith('/') || value.endsWith('/')" "$rules" ||
	fail "timezone leading/trailing slash rejection drift"
grep -qF "value.contains('\\n')" "$rules" || fail "SSID newline rejection drift"
# Byte semantics, not runes: the shell caps are POSIX \${#var}.
grep -qF 'utf8.encode(value).length' "$rules" ||
	fail "length caps are not measured in bytes"

# The timezone menu, in tui.sh's order.
tz_expected="UTC Europe/Zurich Europe/Berlin Europe/London America/New_York America/Los_Angeles Asia/Tokyo"
tz_actual=$(sed -n "/^const List<String> offeredTimezones/,/^];/p" "$rules" |
	sed -n "s/^  '\\([^']*\\)',$/\\1/p" | tr '\n' ' ')
tz_actual=${tz_actual% }
[ "$tz_actual" = "$tz_expected" ] ||
	fail "timezone menu drift: '$tz_actual' != '$tz_expected'"

# 7. Secrets never get rendered or logged.
! grep -rn 'print(' "$app/lib" >/dev/null || fail "the UI writes to stdout"
! grep -rnE 'Text\((draft\.(password|psk)|_first\.text|_second\.text)' \
	"$app/lib" >/dev/null || fail "a secret is rendered on screen"

# 8. The build script: exact toolchain pin, generated runner, asserted bundle.
grep -qF 'FLUTTER_DESKTOP_VERSION=3.38.4-r2' "$builder" ||
	fail "build script no longer pins flutter-desktop 3.38.4-r2"
grep -qF 'apk add "flutter-desktop=$FLUTTER_DESKTOP_VERSION"' "$builder" ||
	fail "build script does not install the pinned flutter-desktop version"
! grep -q 'apk add .*flutter-gtk' "$builder" ||
	fail "the build script must not install the runtime embedder"
grep -qF 'flutter config --no-analytics' "$builder" ||
	fail "build script no longer disables analytics"
grep -qF 'flutter create --platforms=linux' "$builder" ||
	fail "build script no longer generates the linux/ runner"
grep -qF 'flutter build linux --release' "$builder" ||
	fail "build script no longer builds a release bundle"
# flutter_tools invokes CMake with CC=clang/CXX=clang++, which Alpine's
# clang21 does not provide under those names. Losing the shim fails the
# build an hour into the aarch64 job.
grep -qF 'clang++:clang++-21' "$builder" ||
	fail "build script lost the unversioned clang/clang++ shim"
grep -qF 'apk add binutils musl-dev' "$builder" ||
	fail "build script lost the linker toolchain (clang cannot exec ld without it)"
grep -qF 'for member in "$PROJECT_NAME" lib/libapp.so lib/libflutter_linux_gtk.so' \
	"$builder" || fail "build script does not assert the bundle members"
grep -qF 'data/icudtl.dat' "$builder" ||
	fail "build script does not assert the ICU data (Alpine ships it out of tree)"
grep -qF 'data/flutter_assets' "$builder" ||
	fail "build script does not assert data/flutter_assets/"
grep -qF 'set -eu' "$builder" || fail "build script is not fail-closed"

# 9. The touch keyboard. The DC-1 has no keys beyond power and volume, so a
#    text field with nothing to type into it is a dead end, not a cosmetic
#    gap: onboarding asks for a username and a Wi-Fi passphrase before it can
#    do anything. These assert the wiring end to end, because each half is
#    silently useless without the other.
kbd="$app/lib/keyboard.dart"
grep -q 'class Dc1Keyboard' "$kbd" || fail "no on-screen keyboard widget"
grep -q 'class Dc1KeyboardController' "$kbd" ||
	fail "no keyboard controller to drive the focused field"
grep -qF 'ExcludeFocus' "$kbd" ||
	fail "keyboard keys can take focus, which would detach the field being typed into"
# The keyboard mutates the controller directly, and Flutter does not fire
# TextField.onChanged for that -- so the field's onChanged must be threaded
# through, or validation errors never clear while the user retypes.
grep -qF 'onChanged' "$kbd" ||
	fail "keyboard does not forward onChanged (stale validation errors)"
grep -qF 'Dc1Keyboard(' "$app/lib/widgets.dart" ||
	fail "StepScaffold does not dock the keyboard"
grep -qF 'keyboard.attach' "$app/lib/widgets.dart" ||
	fail "Dc1TextField does not attach to the keyboard on focus"
grep -qF 'KeyboardScope' "$app/lib/onboarding.dart" ||
	fail "the onboarding flow does not provide a KeyboardScope"
# No third-party package sneaking in through the keyboard either.
if grep "^import 'package:" "$kbd" | grep -qv "^import 'package:flutter/"; then
	fail "keyboard.dart imports a package outside the Flutter SDK"
fi

echo "flutter-ui tests passed"
