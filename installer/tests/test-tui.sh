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

echo "== touch UI =="

# ask() is defined after tui.sh's library-mode return, so it is extracted
# rather than sourced. It is now a thin forwarding wrapper: /bin/dc1-ask is
# PID 1's dialog client, and the old DC1_TOUCH_UI gate (which kept the broken
# local paint path off) is gone. The discriminator is exact -- /bin/dc1-ask is
# absent on this host, so a forwarding ask() returns 127 (command not found),
# not the gate's 2.
sed -n '/^ask() {/,/^}/p' "$HERE/../src/tui.sh" > "$TMP/ask.sh"
[ -s "$TMP/ask.sh" ] || bad "could not extract ask() from tui.sh"
. "$TMP/ask.sh"

rc=0
ask menu "T" "a" >/dev/null 2>&1 || rc=$?
case "$rc" in
	127) ok "ask() forwards to /bin/dc1-ask (absent on host: 127)" ;;
	*) bad "ask() returned $rc, expected 127 -- the gate is gone and it forwards" ;;
esac

[ ! -e /tmp/ui-active ] ||
	bad "ask() left /tmp/ui-active behind, which would gate PID 1's painting off"

echo "== debug menu wiring =="

# The on-screen debug toolkit lives in the dc1tools applet (Go); tui.sh only
# has to keep offering it and launching it. Read-only on partitions either
# way -- but a menu entry that silently vanished would take the toolkit's
# screen-first interface with it.
if grep -q 'Debug tools' "$HERE/../src/tui.sh"; then
	ok "main menu offers Debug tools"
else
	bad "main menu lost the Debug tools entry"
fi
if grep -q '/bin/dc1-debug menu' "$HERE/../src/tui.sh"; then
	ok "Debug tools launches dc1-debug's on-screen menu"
else
	bad "Debug tools entry does not invoke dc1-debug"
fi

echo
echo "test-tui: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
