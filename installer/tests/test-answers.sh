#!/bin/sh
# Offline tests for the host installer's answer handling: validators,
# password hashing, and answers-file generation (sourced in library mode).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

DC1_INSTALL_LIB=1
. "$HERE/../host/dc1-install.sh"

echo "== validators =="
valid_username alice && ok "alice" || bad "alice rejected"
valid_username _svc && ok "_svc" || bad "_svc rejected"
valid_username root && bad "root accepted" || ok "root rejected"
valid_username Alice && bad "Alice accepted" || ok "Alice rejected"
valid_username "a b" && bad "'a b' accepted" || ok "'a b' rejected"
valid_username 1abc && bad "1abc accepted" || ok "1abc rejected"

valid_hostname dc1 && ok "dc1" || bad "dc1 rejected"
valid_hostname my-tablet && ok "my-tablet" || bad "my-tablet rejected"
valid_hostname -bad && bad "-bad accepted" || ok "-bad rejected"
valid_hostname bad- && bad "bad- accepted" || ok "bad- rejected"
valid_hostname "UPPER" && bad "UPPER accepted" || ok "UPPER rejected"

valid_timezone Europe/Zurich && ok "Europe/Zurich" || bad "Europe/Zurich rejected"
valid_timezone UTC && ok "UTC" || bad "UTC rejected"
valid_timezone ../etc/shadow && bad "traversal accepted" || ok "traversal rejected"
valid_timezone "/abs" && bad "absolute accepted" || ok "absolute rejected"
valid_timezone "a;b" && bad "semicolon accepted" || ok "semicolon rejected"

valid_psk "12345678" && ok "8-char psk" || bad "8-char psk rejected"
valid_psk "1234567" && bad "7-char psk accepted" || ok "7-char psk rejected"

echo "== password hashing =="
if H=$(hash_password "test-password-123") 2>/dev/null; then
	case "$H" in
		'$'*'$'*) ok "hash_password produced a crypt hash" ;;
		*) bad "hash_password output not crypt-shaped: $H" ;;
	esac
else
	echo "  skip: no hasher available on this host (mkpasswd/openssl/busybox)"
fi

echo "== answers file round-trip =="
make_answers "$TMP/ans" alice '$6$s$h' mydc1 Europe/Zurich \
	'Ssid with spaces + $pecial' 'p@ss phrase!'
perms=$(stat -c %a "$TMP/ans")
[ "$perms" = 600 ] && ok "answers file mode 600" || bad "answers mode $perms"
grep -q '^DC1_USER=alice$' "$TMP/ans" && ok "user field" || bad "user field"
grep -q '^DC1_PASS_HASH=\$6\$s\$h$' "$TMP/ans" && ok "hash field" || bad "hash field"
ssid=$(sed -n 's/^DC1_WIFI_SSID_B64=//p' "$TMP/ans" | base64 -d)
psk=$(sed -n 's/^DC1_WIFI_PSK_B64=//p' "$TMP/ans" | base64 -d)
[ "$ssid" = 'Ssid with spaces + $pecial' ] && ok "ssid round-trip" || bad "ssid: '$ssid'"
[ "$psk" = 'p@ss phrase!' ] && ok "psk round-trip" || bad "psk: '$psk'"
grep -qi 'p@ss phrase' "$TMP/ans" && bad "cleartext psk in answers file" \
	|| ok "no cleartext psk in answers file"

make_answers "$TMP/ans2" bob '$6$s$h' dc1 UTC "" ""
grep -q '^DC1_WIFI_SSID_B64=$' "$TMP/ans2" && ok "empty wifi fields" \
	|| bad "empty wifi fields wrong"

# The generated file must pass the device-side validator.
sh "$HERE/../src/provision.sh" --validate "$TMP/ans" >/dev/null \
	&& ok "generated answers pass device-side validation" \
	|| bad "generated answers fail device-side validation"

echo
echo "test-answers: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
