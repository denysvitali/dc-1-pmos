#!/bin/sh
# Offline tests for installer/src/wifi.sh pure functions: config quoting,
# file permissions (credentials are 0600, always) and scan-result parsing.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

export DC1_WIFI_DIR="$TMP/wifi"
. "$HERE/../src/wifi.sh"

echo "== wpa_quote =="

[ "$(wpa_quote 'plain')" = 'plain' ] \
	&& ok "plain string untouched" || bad "plain string mangled"
[ "$(wpa_quote 'a"b')" = 'a\"b' ] \
	&& ok "double quote escaped" || bad "double quote: got $(wpa_quote 'a"b')"
[ "$(wpa_quote 'a\b')" = 'a\\b' ] \
	&& ok "backslash escaped" || bad "backslash: got $(wpa_quote 'a\b')"

echo "== wifi_conf_write =="

wifi_conf_write 'My "Net"' 'p@ss\word123' "$TMP/wpa.conf"
mode=$(stat -c %a "$TMP/wpa.conf" 2>/dev/null || stat -f %Lp "$TMP/wpa.conf")
[ "$mode" = 600 ] && ok "config file is mode 0600" || bad "config mode is $mode"
grep -q 'ssid="My \\"Net\\""' "$TMP/wpa.conf" \
	&& ok "ssid quoted into config" || bad "ssid quoting wrong"
grep -q 'psk="p@ss\\\\word123"' "$TMP/wpa.conf" \
	&& ok "psk quoted into config" || bad "psk quoting wrong"
grep -q "ctrl_interface=$WIFI_CTRL" "$TMP/wpa.conf" \
	&& ok "control interface configured" || bad "no ctrl_interface"

echo "== wifi_scan_parse =="

# wpa_cli scan_results: header line, then bssid/freq/signal/flags/ssid.
scan_input() {
	printf 'bssid / frequency / signal level / flags / ssid\n'
	printf 'aa:aa:aa:aa:aa:aa\t2412\t-70\t[WPA2-PSK-CCMP][ESS]\tWeakNet\n'
	printf 'bb:bb:bb:bb:bb:bb\t5180\t-40\t[WPA2-PSK-CCMP][ESS]\tStrongNet\n'
	printf 'cc:cc:cc:cc:cc:cc\t2437\t-55\t[WPA2-PSK-CCMP][ESS]\tMidNet\n'
	printf 'dd:dd:dd:dd:dd:dd\t2437\t-60\t[WPA2-PSK-CCMP][ESS]\tMidNet\n'
	printf 'ee:ee:ee:ee:ee:ee\t2437\t-45\t[WPA2-PSK-CCMP][ESS]\t\n'
	printf 'ff:ff:ff:ff:ff:ff\t2437\t-45\t[WPA2-PSK-CCMP][ESS]\tBad\\x00Name\n'
}

out=$(scan_input | wifi_scan_parse 12)
[ "$(printf '%s\n' "$out" | head -1)" = "StrongNet" ] \
	&& ok "strongest network listed first" || bad "ordering wrong: $out"
[ "$(printf '%s\n' "$out" | grep -c '^MidNet$')" = 1 ] \
	&& ok "duplicate SSIDs collapsed" || bad "duplicates not collapsed"
printf '%s\n' "$out" | grep -q 'Bad' \
	&& bad "hex-escaped SSID not filtered" || ok "hex-escaped SSID filtered"
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] \
	&& ok "hidden (empty) SSID skipped" || bad "unexpected list: $out"

out=$(scan_input | wifi_scan_parse 2)
[ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] \
	&& ok "result cap respected" || bad "cap not respected"

echo
echo "test-wifi: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
