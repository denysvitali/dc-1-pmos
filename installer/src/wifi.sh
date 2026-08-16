# wifi.sh -- bring up MT7902 Wi-Fi inside the installer initramfs.
# Sourced (not executed) by tui.sh; offline-testable via DC1_LIB=1 (the pure
# functions never touch hardware).
#
# Secret hygiene (mirrors the boot-proven supplicant handling for this
# device -- do not relax):
#   * the PSK is NEVER placed on a command line (no wpa_cli set_network, no
#     wpa_passphrase argv): it goes straight from shell variable to a
#     mode-0600 tmpfs config file.
#   * all supplicant and DHCP output stays in mode-0600 files under
#     /tmp/wifi (dir mode 0700). NOTHING is streamed to kmsg: even ordinary
#     supplicant logs disclose the SSID.
#   * the driver is mt7921s (built into the kernel); the MT7902 firmware
#     staged at /lib/firmware is the upstream linux-firmware pair, verified
#     by size+SHA-256 at BUILD time. Same-named stock Android blobs pass the
#     legacy handshake and then fail mainline mt76's UNI commands, which is
#     why the pins exist.

WIFI_DIR=${DC1_WIFI_DIR:-/tmp/wifi}
WIFI_IFACE=${DC1_WIFI_IFACE:-wlan0}
WIFI_CTRL=/run/wpa_supplicant

wifi_init_dir() {
	mkdir -p "$WIFI_DIR"
	chmod 700 "$WIFI_DIR"
}

# wpa_quote STRING -> the string with \ and " escaped for use inside a
# double-quoted wpa_supplicant.conf value. Newlines are rejected upstream by
# the answer validation; this is defence in depth for the config syntax.
wpa_quote() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# wifi_conf_write SSID PSK FILE -> write a minimal wpa_supplicant config,
# mode 0600, cleartext PSK (same storage model as the installed rootfs'
# NetworkManager keyfile / wpa_supplicant.conf, which are 0600 too).
wifi_conf_write() {
	wc_ssid=$(wpa_quote "$1")
	wc_psk=$(wpa_quote "$2")
	umask 077
	cat > "$3" <<EOF
ctrl_interface=$WIFI_CTRL
network={
	ssid="$wc_ssid"
	psk="$wc_psk"
}
EOF
	umask 022
	chmod 600 "$3"
}

# wifi_scan_parse -> reads `wpa_cli scan_results` output on stdin, prints
# unique non-empty SSIDs, strongest first, at most $1 lines (default 12).
# Hidden networks and SSIDs containing wpa_cli hex escapes for control
# characters are skipped (they cannot be rendered or re-entered faithfully).
wifi_scan_parse() {
	wsp_max=${1:-12}
	# scan_results: bssid / frequency / signal level / flags / ssid
	awk -F'\t' 'NR > 1 && NF >= 5 && $5 != "" { print $3 "\t" $5 }' \
		| sort -rn \
		| cut -f2- \
		| awk '!seen[$0]++' \
		| grep -v '\\x' \
		| head -n "$wsp_max"
}

# --- everything below touches hardware ------------------------------------

wifi_wait_iface() {
	n=0
	while [ "$n" -lt 30 ]; do
		[ -e "/sys/class/net/$WIFI_IFACE" ] && return 0
		n=$((n + 1))
		sleep 1
	done
	return 1
}

wifi_supplicant_stop() {
	pids=$(pidof wpa_supplicant 2>/dev/null) || return 0
	[ -n "$pids" ] && kill $pids 2>/dev/null
	sleep 1
}

# wifi_supplicant_start CONF -> start wpa_supplicant in the background,
# logging (mode 0600) to $WIFI_DIR/wpa.log only.
wifi_supplicant_start() {
	wifi_init_dir
	mkdir -p "$WIFI_CTRL"
	: > "$WIFI_DIR/wpa.log"
	chmod 600 "$WIFI_DIR/wpa.log"
	ip link set "$WIFI_IFACE" up 2>>"$WIFI_DIR/wpa.log"
	# No -f (log-to-file): this Alpine wpa_supplicant is built without
	# CONFIG_DEBUG_FILE, so -f is rejected -- it prints the usage banner
	# ("wpa_supplicant v2.11 ...") to STDOUT and exits without starting, and
	# that banner is exactly what leaked into the Wi-Fi menu. stdout is
	# redirected to the log here as well, so a startup failure can never flow
	# into wifi_scan's command-substitution output.
	/sbin/wpa_supplicant -B -i "$WIFI_IFACE" -c "$1" >>"$WIFI_DIR/wpa.log" 2>&1
}

# wpa_cli is always called with -p "$WIFI_CTRL": its default control directory
# is /var/run/wpa_supplicant, which does not exist in this initramfs (only
# /run), so a bare `wpa_cli -i wlan0` fails with "Failed to connect to
# non-global ctrl_ifname" even though the socket is at $WIFI_CTRL/wlan0.
wpa_cli() {
	/sbin/wpa_cli -p "$WIFI_CTRL" "$@"
}

# wifi_scan -> print up to 12 SSIDs, strongest first. Starts a bare
# supplicant (ctrl_interface only, no credentials) if none is running.
wifi_scan() {
	wifi_init_dir
	if ! pidof wpa_supplicant >/dev/null 2>&1; then
		umask 077
		printf 'ctrl_interface=%s\n' "$WIFI_CTRL" > "$WIFI_DIR/scan.conf"
		umask 022
		wifi_supplicant_start "$WIFI_DIR/scan.conf" || return 1
	fi
	wpa_cli -i "$WIFI_IFACE" scan >/dev/null 2>&1
	sleep 4
	wpa_cli -i "$WIFI_IFACE" scan_results 2>/dev/null | wifi_scan_parse 12
}

# wifi_connect SSID PSK -> associate and wait for wpa_state=COMPLETED.
# Returns non-zero on timeout; diagnostics stay in $WIFI_DIR.
wifi_connect() {
	wifi_init_dir
	wifi_conf_write "$1" "$2" "$WIFI_DIR/wpa.conf"
	wifi_supplicant_stop
	wifi_supplicant_start "$WIFI_DIR/wpa.conf" || return 1
	n=0
	while [ "$n" -lt 30 ]; do
		if wpa_cli -i "$WIFI_IFACE" status 2>/dev/null \
			| grep -q '^wpa_state=COMPLETED'; then
			return 0
		fi
		n=$((n + 1))
		sleep 1
	done
	return 1
}

# wifi_dhcp -> udhcpc with our hook script (writes /etc/resolv.conf).
# Output stays in $WIFI_DIR/udhcpc.log (0600): lease lines include the SSID's
# network layout, keep them off kmsg too.
wifi_dhcp() {
	wifi_init_dir
	: > "$WIFI_DIR/udhcpc.log"
	chmod 600 "$WIFI_DIR/udhcpc.log"
	udhcpc -i "$WIFI_IFACE" -s /etc/udhcpc.script -n -q -t 6 -T 3 \
		>> "$WIFI_DIR/udhcpc.log" 2>&1
}
