#!/bin/sh
# provision.sh -- apply the user's install-time answers to an installed
# (mounted) DC-1 rootfs. Pure file edits, no chroot: everything works with
# busybox tools, and the whole script is testable offline against a fake
# rootfs directory (see installer/tests/).
#
#   provision.sh --validate ANSWERS_FILE
#       Parse + validate the answers only. No rootfs needed. Used by
#       receive.sh BEFORE any destructive step.
#
#   provision.sh ROOTFS_DIR ANSWERS_FILE
#       Apply: user + password, hostname, timezone, Wi-Fi credentials.
#
# Answers file format (KEY=VALUE lines; parsed, never sourced):
#   DC1_USER=alice              login name          [a-z_][a-z0-9_-]{0,31}
#   DC1_PASS_HASH=$6$...        crypt(3) hash (generated host-side; the
#                               cleartext password never crosses the wire)
#   DC1_HOSTNAME=dc1            [a-z0-9][a-z0-9-]{0,62}
#   DC1_TZ=Europe/Zurich        must exist under /usr/share/zoneinfo/
#   DC1_WIFI_SSID_B64=...       base64; optional (empty = no Wi-Fi config)
#   DC1_WIFI_PSK_B64=...        base64; required iff SSID is set; 8..63 chars
#
# User handling: postmarketOS images ship with one pre-created login user. If
# DC1_USER matches an existing user, only the password is set; if exactly one
# regular user (1000 <= uid < 65534) exists, it is RENAMED (preserving uid and
# every group membership); otherwise a fresh user is created.
#
# Wi-Fi handling adapts to whatever network stack the image carries:
#   /etc/NetworkManager present  -> NetworkManager keyfile (mode 0600)
#   wpa_supplicant present       -> /etc/wpa_supplicant/wpa_supplicant.conf
#                                   (+ OpenRC default-runlevel symlink if the
#                                   service script exists)
#   neither                      -> credentials parked (0600) in
#                                   /var/lib/dc1-installer/wifi.pending
set -eu

err() { echo "provision: $*" >&2; }
die() { err "$*"; exit 1; }

# ------------------------------------------------------------------ parsing

# get KEY FILE -> prints the value of the first KEY= line (empty if absent).
get() {
	sed -n "s/^$1=//p" "$2" | head -1
}

parse_answers() {
	answers=$1
	[ -f "$answers" ] || die "answers file missing: $answers"
	A_USER=$(get DC1_USER "$answers")
	A_HASH=$(get DC1_PASS_HASH "$answers")
	A_HOSTNAME=$(get DC1_HOSTNAME "$answers")
	A_TZ=$(get DC1_TZ "$answers")
	A_SSID_B64=$(get DC1_WIFI_SSID_B64 "$answers")
	A_PSK_B64=$(get DC1_WIFI_PSK_B64 "$answers")
}

validate_answers() {
	case "$A_USER" in
		[a-z_]) ;;
		[a-z_][a-z0-9_-]*) [ ${#A_USER} -le 32 ] || die "username too long" ;;
		*) die "invalid username: '$A_USER'" ;;
	esac
	case "$A_USER" in
		root|nobody) die "refusing reserved username: $A_USER" ;;
	esac

	[ -n "$A_HASH" ] || die "missing DC1_PASS_HASH"
	case "$A_HASH" in
		'$'*'$'*) ;;
		*) die "DC1_PASS_HASH is not a crypt hash" ;;
	esac
	case "$A_HASH" in
		*:*|*' '*) die "DC1_PASS_HASH contains invalid characters" ;;
	esac

	case "$A_HOSTNAME" in
		[a-z0-9]) ;;
		[a-z0-9][a-z0-9-]*) [ ${#A_HOSTNAME} -le 63 ] || die "hostname too long" ;;
		*) die "invalid hostname: '$A_HOSTNAME'" ;;
	esac
	case "$A_HOSTNAME" in *-) die "hostname may not end with -" ;; esac

	[ -n "$A_TZ" ] || die "missing DC1_TZ"
	case "$A_TZ" in
		*..*|/*|*/) die "invalid timezone path: '$A_TZ'" ;;
		*[!A-Za-z0-9_+/-]*) die "invalid timezone characters: '$A_TZ'" ;;
	esac

	if [ -n "$A_SSID_B64" ] || [ -n "$A_PSK_B64" ]; then
		[ -n "$A_SSID_B64" ] && [ -n "$A_PSK_B64" ] || \
			die "Wi-Fi SSID and PSK must both be set (or both empty)"
		A_SSID=$(echo "$A_SSID_B64" | base64 -d 2>/dev/null) || die "bad SSID base64"
		A_PSK=$(echo "$A_PSK_B64" | base64 -d 2>/dev/null) || die "bad PSK base64"
		[ -n "$A_SSID" ] || die "empty SSID"
		[ ${#A_SSID} -le 32 ] || die "SSID longer than 32 bytes"
		[ ${#A_PSK} -ge 8 ] && [ ${#A_PSK} -le 63 ] || \
			die "WPA-PSK passphrase must be 8..63 characters"
		# $(printf '\n') would be stripped to ""; a literal is required here.
		nl='
'
		case "$A_SSID" in *"$nl"*) die "SSID contains newline" ;; esac
		case "$A_PSK" in *"$nl"*) die "PSK contains newline" ;; esac
	else
		A_SSID=""
		A_PSK=""
	fi
}

# ------------------------------------------------------------------ apply

apply_hostname() {
	echo "$A_HOSTNAME" > "$ROOT/etc/hostname"
	if [ -f "$ROOT/etc/hosts" ] && grep -q '^127\.0\.1\.1' "$ROOT/etc/hosts"; then
		sed -i "s/^127\.0\.1\.1.*/127.0.1.1	$A_HOSTNAME/" "$ROOT/etc/hosts"
	else
		printf '127.0.1.1\t%s\n' "$A_HOSTNAME" >> "$ROOT/etc/hosts"
	fi
}

apply_timezone() {
	[ -f "$ROOT/usr/share/zoneinfo/$A_TZ" ] || \
		die "timezone not present in rootfs: $A_TZ"
	ln -sf "../usr/share/zoneinfo/$A_TZ" "$ROOT/etc/localtime"
}

# Replace every occurrence of user $2 with $3 in the comma-separated member
# list (field 4) of $1 (a group file), and rename a group named $2 itself.
rename_in_group() {
	awk -F: -v OFS=: -v old="$2" -v new="$3" '
		{
			if ($1 == old) $1 = new
			n = split($4, m, ",")
			out = ""
			for (i = 1; i <= n; i++) {
				if (m[i] == old) m[i] = new
				out = out (i > 1 ? "," : "") m[i]
			}
			$4 = out
			print
		}' "$1" > "$1.tmp"
	cat "$1.tmp" > "$1"
	rm -f "$1.tmp"
}

set_password() {
	days=$(( $(date +%s) / 86400 ))
	awk -F: -v OFS=: -v u="$A_USER" -v h="$A_HASH" -v d="$days" \
		'$1 == u { $2 = h; $3 = d } { print }' \
		"$ROOT/etc/shadow" > "$ROOT/etc/shadow.tmp"
	cat "$ROOT/etc/shadow.tmp" > "$ROOT/etc/shadow"
	rm -f "$ROOT/etc/shadow.tmp"
	grep -q "^$A_USER:" "$ROOT/etc/shadow" || die "user missing from shadow after edit"
}

apply_user() {
	passwd="$ROOT/etc/passwd"
	shadow="$ROOT/etc/shadow"
	group="$ROOT/etc/group"
	[ -f "$passwd" ] && [ -f "$shadow" ] && [ -f "$group" ] || \
		die "rootfs has no passwd/shadow/group"

	if grep -q "^$A_USER:" "$passwd"; then
		set_password
		return
	fi

	# Exactly one regular user -> rename it, preserving uid/gid and groups.
	existing=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' "$passwd")
	count=$(printf '%s\n' "$existing" | grep -c . || true)
	if [ "$count" -eq 1 ]; then
		old=$existing
		awk -F: -v OFS=: -v old="$old" -v new="$A_USER" \
			'$1 == old { $1 = new; $6 = "/home/" new } { print }' \
			"$passwd" > "$passwd.tmp"
		cat "$passwd.tmp" > "$passwd"; rm -f "$passwd.tmp"
		awk -F: -v OFS=: -v old="$old" -v new="$A_USER" \
			'$1 == old { $1 = new } { print }' \
			"$shadow" > "$shadow.tmp"
		cat "$shadow.tmp" > "$shadow"; rm -f "$shadow.tmp"
		rename_in_group "$group" "$old" "$A_USER"
		if [ -d "$ROOT/home/$old" ] && [ "$old" != "$A_USER" ]; then
			mv "$ROOT/home/$old" "$ROOT/home/$A_USER"
		fi
		set_password
		return
	fi

	# No regular user in the image: create one, first free uid from 10000
	# (the uid postmarketOS gives its primary user).
	uid=10000
	while grep -q "^[^:]*:[^:]*:$uid:" "$passwd"; do uid=$((uid + 1)); done
	echo "$A_USER:x:$uid:$uid::/home/$A_USER:/bin/sh" >> "$passwd"
	echo "$A_USER:x:$uid:" >> "$group"
	echo "$A_USER:!::0:::::" >> "$shadow"
	for g in wheel audio video input netdev plugdev; do
		grep -q "^$g:" "$group" || continue
		awk -F: -v OFS=: -v g="$g" -v u="$A_USER" '
			$1 == g { $4 = ($4 == "" ? u : $4 "," u) } { print }' \
			"$group" > "$group.tmp"
		cat "$group.tmp" > "$group"; rm -f "$group.tmp"
	done
	mkdir -p "$ROOT/home/$A_USER"
	chown "$uid:$uid" "$ROOT/home/$A_USER" 2>/dev/null || true
	chmod 700 "$ROOT/home/$A_USER"
	set_password
}

apply_gdm_autologin() {
	# gdm autologs in by NAME, not uid (tinydm used AUTOLOGIN_UID=10000, which
	# survives the rename; gdm's AutomaticLogin does not). The device package
	# ships /etc/gdm/custom.conf with AutomaticLogin=dc1 for the unprovisioned
	# first boot; once this script renames the user, that target is stale and
	# gdm would fall back to the greeter. Point it at the final username.
	# No-op unless gdm is present (the GNOME/systemd image ships the config; a
	# sway image has no gdm and therefore no custom.conf).
	conf="$ROOT/etc/gdm/custom.conf"
	[ -f "$conf" ] || return 0
	if grep -q '^AutomaticLogin=' "$conf"; then
		sed -i "s/^AutomaticLogin=.*/AutomaticLogin=$A_USER/" "$conf"
	else
		sed -i "/^\[daemon\]/a AutomaticLogin=$A_USER" "$conf"
	fi
}

apply_display_orientation() {
	# The panel scans out 180 degrees from the glass, and the device tree
	# deliberately carries no rotation property, so DRM reports no panel
	# orientation and GNOME comes up upside-down. Compensate where mutter
	# actually looks: monitors.xml in the provisioned user's home (the
	# session) and in gdm's (the greeter). The scale is the one mutter
	# itself computes for this mode; if mutter ever rejects the file it
	# falls back to its defaults, so the failure mode is only the rotation
	# coming back, never a broken session. No-op unless gdm is present
	# (same signal apply_gdm_autologin keys on).
	[ -f "$ROOT/etc/gdm/custom.conf" ] || return 0
	_mon_user_uid=$(awk -F: -v u="$A_USER" '$1 == u { print $3 }' "$ROOT/etc/passwd")
	_mon_gdm_uid=$(awk -F: '$1 == "gdm" { print $3 }' "$ROOT/etc/passwd")
	for _mon_pair in "home/$A_USER:$_mon_user_uid" "var/lib/gdm:$_mon_gdm_uid"; do
		_mon_dir="$ROOT/${_mon_pair%%:*}/.config"
		_mon_uid="${_mon_pair##*:}"
		[ -n "$_mon_uid" ] || continue
		mkdir -p "$_mon_dir"
		cat > "$_mon_dir/monitors.xml" <<'EOF'
<monitors version="2">
  <configuration>
    <layoutmode>logical</layoutmode>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>1.4981273412704468</scale>
      <primary>yes</primary>
      <transform>
        <rotation>upside_down</rotation>
        <flipped>no</flipped>
      </transform>
      <monitor>
        <monitorspec>
          <connector>DSI-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>1200</width>
          <height>1600</height>
          <rate>60.000</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF
		chown -R "$_mon_uid:$_mon_uid" "$_mon_dir" 2>/dev/null || true
	done
}

apply_wifi() {
	[ -n "$A_SSID" ] || return 0
	if [ -d "$ROOT/etc/NetworkManager" ]; then
		dir="$ROOT/etc/NetworkManager/system-connections"
		mkdir -p "$dir"
		conn="$dir/wifi.nmconnection"
		uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
			echo "6d1f5a6e-0000-4000-8000-$(date +%s | tail -c 13)0000")
		umask 077
		cat > "$conn" <<EOF
[connection]
id=$A_SSID
uuid=$uuid
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$A_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$A_PSK

[ipv4]
method=auto

[ipv6]
method=auto
EOF
		chmod 600 "$conn"
		umask 022
		echo "wifi: wrote NetworkManager keyfile"
	elif [ -x "$ROOT/sbin/wpa_supplicant" ] || [ -x "$ROOT/usr/sbin/wpa_supplicant" ]; then
		mkdir -p "$ROOT/etc/wpa_supplicant"
		umask 077
		cat > "$ROOT/etc/wpa_supplicant/wpa_supplicant.conf" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
network={
	ssid="$A_SSID"
	psk="$A_PSK"
}
EOF
		chmod 600 "$ROOT/etc/wpa_supplicant/wpa_supplicant.conf"
		umask 022
		if [ -f "$ROOT/etc/init.d/wpa_supplicant" ] && \
		   [ -d "$ROOT/etc/runlevels/default" ]; then
			ln -sf /etc/init.d/wpa_supplicant \
				"$ROOT/etc/runlevels/default/wpa_supplicant"
		fi
		echo "wifi: wrote wpa_supplicant.conf"
	else
		mkdir -p "$ROOT/var/lib/dc1-installer"
		umask 077
		printf 'ssid=%s\npsk=%s\n' "$A_SSID" "$A_PSK" \
			> "$ROOT/var/lib/dc1-installer/wifi.pending"
		chmod 600 "$ROOT/var/lib/dc1-installer/wifi.pending"
		umask 022
		echo "wifi: no known network stack in rootfs; parked credentials" \
			"in /var/lib/dc1-installer/wifi.pending"
	fi
}

write_marker() {
	mkdir -p "$ROOT/var/lib/dc1-installer"
	# No secrets in the marker: names only.
	cat > "$ROOT/var/lib/dc1-installer/provisioned" <<EOF
provisioned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
user=$A_USER
hostname=$A_HOSTNAME
timezone=$A_TZ
wifi_configured=$([ -n "$A_SSID" ] && echo yes || echo no)
EOF
}

# ------------------------------------------------------------------ main

case "${1:-}" in
	--validate)
		[ $# -eq 2 ] || die "usage: provision.sh --validate ANSWERS"
		parse_answers "$2"
		validate_answers
		echo "answers OK"
		exit 0
		;;
	"")
		die "usage: provision.sh [--validate] ROOTFS_DIR ANSWERS"
		;;
esac

[ $# -eq 2 ] || die "usage: provision.sh ROOTFS_DIR ANSWERS"
ROOT=$1
[ -d "$ROOT" ] || die "rootfs dir missing: $ROOT"
[ -d "$ROOT/etc" ] || die "not a rootfs (no /etc): $ROOT"
parse_answers "$2"
validate_answers

apply_hostname
apply_timezone
apply_user
apply_gdm_autologin
apply_display_orientation
apply_wifi
write_marker
echo "provisioned: user=$A_USER hostname=$A_HOSTNAME tz=$A_TZ wifi=$([ -n "$A_SSID" ] && echo yes || echo no)"
