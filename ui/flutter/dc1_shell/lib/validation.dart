import 'dart:convert';

/// Client-side mirror of the installer's validation rules.
///
/// These rules exist three times already -- `installer/src/tui.sh`,
/// `installer/src/provision.sh` and the frozen host `installer/host/
/// dc1-install.sh` -- and this is the fourth copy. They must stay
/// byte-identical in meaning: a typo has to be caught while the user is
/// still on the keyboard screen, not after a destructive step. The backend
/// re-validates everything, so this layer is a courtesy, never the gate.
///
/// `scripts/tests/test_flutter_ui.sh` greps this file for the literal
/// patterns below; it is the parity tripwire between the shell, the Go
/// backend and this app.
///
/// Two divergences from the shell, both deliberate and both measured on
/// busybox ash rather than assumed:
///
///  1. `case "$1" in [a-z_][a-z0-9_-]*)` is a GLOB, not a regex -- the `*`
///     matches any characters at all, so tui.sh and provision.sh in fact
///     accept `us er`, `user!` and `dc_1`. This file implements the rule as
///     documented and as the installer's own error screens describe it
///     (anchored patterns), which is strictly stricter. The client can only
///     reject a name the device would have taken; it can never accept one
///     the device would refuse.
///  2. `${#var}` in Alpine's busybox is LOCALE-DEPENDENT: measured on
///     busybox 1.37.0-r14, `busybox ash -c 'v=café; echo ${#v}'` prints 4
///     under a UTF-8 locale (musl's default when `LANG`/`LC_ALL` are unset,
///     which is how the installer runs) and 5 under `LC_ALL=C`. So the
///     shell counts codepoints in practice, while an 802.11 SSID is 32
///     OCTETS and NetworkManager measures the PSK in bytes. This file
///     counts bytes -- see `byteLength` -- matching what actually consumes
///     these values, and never Dart's `String.length`, which counts UTF-16
///     code units. For ASCII, which is all the username/hostname/timezone
///     charsets permit, all three counts are identical; for an unrestricted
///     SSID or PSK, counting bytes is the stricter rule and can only reject
///     a value the device would have taken.

/// Length in BYTES: neither `String.length` (UTF-16 code units) nor a rune
/// count is the unit that matters here -- an SSID that fits in 32 runes may
/// not fit in the 32 octets 802.11 allows. See divergence 2 above.
int byteLength(String value) => utf8.encode(value).length;

/// username: `[a-z_]` or `[a-z_][a-z0-9_-]*`, max 32, never root/nobody.
final RegExp usernameSingleChar = RegExp(r'^[a-z_]$');
final RegExp usernamePattern = RegExp(r'^[a-z_][a-z0-9_-]*$');

/// hostname: `[a-z0-9]` or `[a-z0-9][a-z0-9-]*`, max 63, no trailing dash.
final RegExp hostnameSingleChar = RegExp(r'^[a-z0-9]$');
final RegExp hostnamePattern = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// timezone: only `[A-Za-z0-9_+/-]`, non-empty, no `..`, no leading or
/// trailing `/`.
final RegExp timezoneCharset = RegExp(r'^[A-Za-z0-9_+/-]+$');

/// Reserved account names the installer refuses outright.
const List<String> reservedUsernames = <String>['root', 'nobody'];

/// The timezone menu, in the order `tui.sh` offers it.
const List<String> offeredTimezones = <String>[
  'UTC',
  'Europe/Zurich',
  'Europe/Berlin',
  'Europe/London',
  'America/New_York',
  'America/Los_Angeles',
  'Asia/Tokyo',
];

/// Returns null when valid, otherwise the message to show next to the field.
String? validateUsername(String value) {
  if (reservedUsernames.contains(value)) {
    return 'Refusing reserved username: $value';
  }
  if (usernameSingleChar.hasMatch(value)) {
    return null;
  }
  if (!usernamePattern.hasMatch(value)) {
    return 'Lowercase letters, digits, - and _; must start with a letter or _.';
  }
  if (byteLength(value) > 32) {
    return 'Maximum 32 characters.';
  }
  return null;
}

String? validateHostname(String value) {
  if (value.endsWith('-')) {
    return 'A hostname may not end with -.';
  }
  if (hostnameSingleChar.hasMatch(value)) {
    return null;
  }
  if (!hostnamePattern.hasMatch(value)) {
    return 'Lowercase letters, digits and -; must start with a letter or digit.';
  }
  if (byteLength(value) > 63) {
    return 'Maximum 63 characters.';
  }
  return null;
}

String? validateTimezone(String value) {
  if (value.isEmpty) {
    return 'Pick a timezone.';
  }
  if (value.contains('..')) {
    return 'A timezone may not contain "..".';
  }
  if (value.startsWith('/') || value.endsWith('/')) {
    return 'Use Area/City, e.g. Europe/Rome.';
  }
  if (!timezoneCharset.hasMatch(value)) {
    return 'Allowed characters: A-Z a-z 0-9 _ + / -';
  }
  return null;
}

/// PSK: 8..63 bytes (the WPA passphrase range).
String? validatePsk(String value) {
  final int length = byteLength(value);
  if (length < 8 || length > 63) {
    return 'WPA passphrases are 8..63 characters.';
  }
  return null;
}

/// SSID: non-empty, max 32 bytes, no newline (it lands in a keyfile).
String? validateSsid(String value) {
  if (value.isEmpty) {
    return 'Enter a network name.';
  }
  if (value.contains('\n')) {
    return 'A network name may not contain a newline.';
  }
  if (byteLength(value) > 32) {
    return 'Maximum 32 characters.';
  }
  return null;
}

String? validatePassword(String value) {
  if (value.isEmpty) {
    return 'Enter a password.';
  }
  return null;
}

String? validatePasswordRepeat(String password, String repeat) {
  if (repeat.isEmpty) {
    return 'Enter the password again.';
  }
  if (password != repeat) {
    return 'Passwords do not match.';
  }
  return null;
}
