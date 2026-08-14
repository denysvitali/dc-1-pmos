#!/bin/sh
# Offline tests for installer/src/tui.sh library functions: field validators
# and answers-file generation (0600, parseable by provision.sh --validate).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

export DC1_WIFI_LIB="$HERE/../src/wifi.sh"
DC1_LIB=1
. "$HERE/../src/tui.sh"

echo "== validators =="

valid_username alice && ok "accepts alice" || bad "rejected alice"
valid_username root 2>/dev/null && bad "accepted root" || ok "rejects root"
valid_username 9lives 2>/dev/null && bad "accepted 9lives" || ok "rejects leading digit"
valid_hostname dc1 && ok "accepts dc1" || bad "rejected dc1"
valid_hostname -x 2>/dev/null && bad "accepted -x" || ok "rejects leading dash"
valid_timezone Europe/Zurich && ok "accepts Europe/Zurich" || bad "rejected Europe/Zurich"
valid_timezone '../etc' 2>/dev/null && bad "accepted ../etc" || ok "rejects traversal"
valid_psk 12345678 && ok "accepts 8-char psk" || bad "rejected 8-char psk"
valid_psk short 2>/dev/null && bad "accepted short psk" || ok "rejects short psk"

echo "== make_answers =="

HASH='$6$testsalt$testhash'
make_answers "$TMP/answers" alice "$HASH" dc1 Europe/Zurich 'Home Net' 'pass phrase'
mode=$(stat -c %a "$TMP/answers" 2>/dev/null || stat -f %Lp "$TMP/answers")
[ "$mode" = 600 ] && ok "answers file is mode 0600" || bad "answers mode is $mode"
grep -q '^DC1_USER=alice$' "$TMP/answers" && ok "user recorded" || bad "user missing"
grep -q '^DC1_PASS_HASH=\$6\$' "$TMP/answers" && ok "hash recorded" || bad "hash missing"
grep -q 'pass phrase' "$TMP/answers" \
	&& bad "cleartext PSK in answers" || ok "PSK stored base64, not cleartext"
ssid_b64=$(sed -n 's/^DC1_WIFI_SSID_B64=//p' "$TMP/answers")
[ "$(echo "$ssid_b64" | base64 -d)" = "Home Net" ] \
	&& ok "SSID base64 round-trips" || bad "SSID base64 broken"

# The generated file must satisfy the authoritative validator.
if sh "$HERE/../src/provision.sh" --validate "$TMP/answers" >/dev/null 2>&1; then
	ok "answers pass provision.sh --validate"
else
	bad "answers rejected by provision.sh --validate"
fi

# No-Wi-Fi variant validates too.
make_answers "$TMP/answers2" bob "$HASH" dc1 UTC "" ""
if sh "$HERE/../src/provision.sh" --validate "$TMP/answers2" >/dev/null 2>&1; then
	ok "no-wifi answers pass provision.sh --validate"
else
	bad "no-wifi answers rejected"
fi

echo "== hash_password =="

if command -v cryptpw >/dev/null 2>&1; then
	h=$(hash_password secret123)
	case "$h" in
		'$6$'*) ok "cryptpw produces sha512crypt" ;;
		*) bad "unexpected hash format: $h" ;;
	esac
else
	echo "  skip: no cryptpw on this host (device busybox provides it; build.sh enforces the applet)"
fi

echo
echo "test-tui: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
