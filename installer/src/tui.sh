#!/bin/sh
# tui.sh -- the on-device installer front-end: touch-driven prompts on the
# panel, run in the background by rc.sh. The USB installd daemon keeps
# running in parallel the whole time, so a host can always take over.
#
# The screens are drawn by PID 1, which owns the panel (a second DRM modeset
# blackens it): /bin/dc1-ask is now a thin client that forwards its argv to
# PID 1's in-process dialog server over /tmp/dc1-ask.sock and relays the
# answer. Nothing here paints, and there is no panel handover.
#
# If dc1-ask cannot reach PID 1 (no panel, or no touchscreen), this script
# exits and the classic status screen + USB flow remain -- the touch UI is an
# addition, never a dependency, and the USB path is the fallback.
#
# Secrets: passwords and PSKs live in shell variables and mode-0600 files
# only; they are never echoed, logged, or put on an argv. The password is
# hashed on-device (busybox cryptpw, sha512crypt) before it touches the
# answers file. Validation mirrors provision.sh, which re-validates before
# anything is written.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

STATUS_FILE=${DC1_STATUS_FILE:-/tmp/installer-status}
ANSWERS=/tmp/answers

. "${DC1_WIFI_LIB:-/etc/installer/wifi.sh}"

log() { echo "[tui] $*" > /dev/kmsg 2>/dev/null; }

status() { echo "$*" > "$STATUS_FILE" 2>/dev/null; }

# ---------------------------------------------------------------- validation
# Same rules as provision.sh / the host script; kept here so a typo is
# caught while the user is still on the keyboard screen.

valid_username() {
	case "$1" in
		root|nobody) return 1 ;;
		[a-z_]) return 0 ;;
		[a-z_][a-z0-9_-]*) [ ${#1} -le 32 ] ;;
		*) return 1 ;;
	esac
}

valid_hostname() {
	case "$1" in
		*-) return 1 ;;
		[a-z0-9]) return 0 ;;
		[a-z0-9][a-z0-9-]*) [ ${#1} -le 63 ] ;;
		*) return 1 ;;
	esac
}

valid_timezone() {
	case "$1" in
		''|*..*|/*|*/) return 1 ;;
		*[!A-Za-z0-9_+/-]*) return 1 ;;
		*) return 0 ;;
	esac
}

valid_psk() {
	[ ${#1} -ge 8 ] && [ ${#1} -le 63 ]
}

b64_line() {
	printf '%s' "$1" | base64 | tr -d '\n'
}

# hash_password PASSWORD -> sha512crypt hash on stdout (password via stdin,
# never argv). busybox cryptpw generates its own salt.
hash_password() {
	printf '%s' "$1" | cryptpw -m sha512 -P 0
}

# make_answers OUTFILE USER HASH HOSTNAME TZ SSID PSK
make_answers() {
	umask 077
	{
		echo "DC1_USER=$2"
		echo "DC1_PASS_HASH=$3"
		echo "DC1_HOSTNAME=$4"
		echo "DC1_TZ=$5"
		if [ -n "$6" ]; then
			echo "DC1_WIFI_SSID_B64=$(b64_line "$6")"
			echo "DC1_WIFI_PSK_B64=$(b64_line "$7")"
		else
			echo "DC1_WIFI_SSID_B64="
			echo "DC1_WIFI_PSK_B64="
		fi
	} > "$1"
	umask 022
	chmod 600 "$1"
}

# Library mode for offline tests: stop before any side effect.
if [ -n "${DC1_LIB:-}" ]; then
	return 0 2>/dev/null || exit 0
fi

# -------------------------------------------------------------------- screens
# ask MODE ARGS... -> dc1-ask, which forwards the request to PID 1's dialog
# server and relays the answer. Output is the user's answer on stdout; exit 2
# means the UI is unusable (PID 1 not serving -- no panel or no touchscreen)
# and the caller must fall back to the USB flow.

ask() {
	/bin/dc1-ask "$@"
}

usb_screen() {
	ask info "USB INSTALL" \
		"On your computer, download the release" \
		"and run:" \
		"" \
		"  ./dc1-install.sh \\" \
		"     --rootfs jagar-rootfs.ext4.zst \\" \
		"     --boot-image jagar-boot.img" \
		"" \
		"Device is listening on USB (172.16.42.1)." \
		> /dev/null
}

pick_wifi() {
	while :; do
		status "SCANNING WI-FI NETWORKS"
		nets=$(wifi_scan) || nets=""
		set --
		oldIFS=$IFS; IFS='
'
		for n in $nets; do set -- "$@" "$n"; done
		IFS=$oldIFS
		choice=$(ask menu "CHOOSE WI-FI NETWORK" "$@" \
			"= Rescan" "= Type network name" "= Back") || return 1
		nnets=$#
		if [ "$choice" = "$nnets" ]; then           # rescan
			continue
		elif [ "$choice" = $((nnets + 1)) ]; then   # manual ssid
			SSID=$(ask text "WI-FI NETWORK NAME (SSID)" "") || return 1
			[ -n "$SSID" ] && [ ${#SSID} -le 32 ] && return 0
		elif [ "$choice" = $((nnets + 2)) ]; then   # back
			return 1
		else
			eval "SSID=\${$((choice + 1))}"
			[ -n "$SSID" ] && return 0
		fi
	done
}

net_flow() {
	status "STARTING WI-FI"
	if ! wifi_wait_iface; then
		ask info "NO WI-FI HARDWARE" \
			"wlan0 did not appear." \
			"Check the kernel log (debug shell) or" \
			"use the USB install instead." > /dev/null
		return 1
	fi

	pick_wifi || return 1

	while :; do
		PSK=$(ask secret "PASSPHRASE FOR $SSID") || return 1
		valid_psk "$PSK" && break
		ask info "INVALID PASSPHRASE" \
			"WPA passphrases are 8..63 characters." > /dev/null
	done

	status "CONNECTING TO WI-FI"
	if ! wifi_connect "$SSID" "$PSK"; then
		ask info "WI-FI CONNECTION FAILED" \
			"Could not associate with the network." \
			"Wrong passphrase? Diagnostics are in" \
			"/tmp/wifi (debug shell)." > /dev/null
		return 1
	fi
	status "REQUESTING IP ADDRESS"
	if ! wifi_dhcp; then
		ask info "DHCP FAILED" \
			"Associated, but no IP lease arrived." \
			"Diagnostics are in /tmp/wifi." > /dev/null
		return 1
	fi

	# Account setup can be deferred to first boot. An unprovisioned install
	# writes the rootfs with no account and leaves the idempotence marker
	# unset, so the installed system's Flutter onboarding (Wi-Fi, username,
	# password, hostname, timezone) runs on first boot. Asking everything
	# here remains the default; "set up later" is the "flash and interact"
	# path.
	choice=$(ask menu "ACCOUNT SETUP" \
		"Set up now (username, password, hostname, timezone)" \
		"Set up later (onboard on first boot)") || return 1

	if [ "$choice" = 0 ]; then
		while :; do
			A_USER=$(ask text "USERNAME" "user") || return 1
			valid_username "$A_USER" && break
			ask info "INVALID USERNAME" \
				"Lowercase letters, digits, - and _;" \
				"must start with a letter; max 32." > /dev/null
		done

		while :; do
			A_PASS=$(ask secret "PASSWORD FOR $A_USER") || return 1
			[ -n "$A_PASS" ] || continue
			A_PASS2=$(ask secret "PASSWORD (AGAIN)") || return 1
			[ "$A_PASS" = "$A_PASS2" ] && break
			ask info "PASSWORDS DO NOT MATCH" "Try again." > /dev/null
		done
		A_PASS2=""

		while :; do
			A_HOSTNAME=$(ask text "HOSTNAME" "dc1") || return 1
			valid_hostname "$A_HOSTNAME" && break
			ask info "INVALID HOSTNAME" \
				"Lowercase letters, digits and -;" \
				"max 63 characters." > /dev/null
		done

		while :; do
			tzc=$(ask menu "TIMEZONE" \
				"UTC" "Europe/Zurich" "Europe/Berlin" "Europe/London" \
				"America/New_York" "America/Los_Angeles" "Asia/Tokyo" \
				"= Type another") || return 1
			case "$tzc" in
				0) A_TZ=UTC ;;
				1) A_TZ=Europe/Zurich ;;
				2) A_TZ=Europe/Berlin ;;
				3) A_TZ=Europe/London ;;
				4) A_TZ=America/New_York ;;
				5) A_TZ=America/Los_Angeles ;;
				6) A_TZ=Asia/Tokyo ;;
				*) A_TZ=$(ask text "TIMEZONE (AREA/CITY)" "UTC") || return 1 ;;
			esac
			valid_timezone "$A_TZ" && break
			ask info "INVALID TIMEZONE" "Use Area/City, e.g. Europe/Rome." > /dev/null
		done

		A_HASH=$(hash_password "$A_PASS") || {
			ask info "INTERNAL ERROR" "Password hashing failed." > /dev/null
			return 1
		}
		A_PASS=""

		make_answers "$ANSWERS" "$A_USER" "$A_HASH" "$A_HOSTNAME" "$A_TZ" \
			"$SSID" "$PSK"
	else
		# Unprovisioned: write an empty answers file (netinstall.sh only
		# checks it exists) and flag wr_finalize to skip provisioning.
		umask 077
		: > "$ANSWERS"
		umask 022
		chmod 600 "$ANSWERS"
		export DC1_SKIP_PROVISION=1
	fi
	PSK=""

	choice=$(ask menu "READY TO INSTALL" \
		"Install now (ERASES the Linux data partition)" \
		"Cancel") || return 1
	[ "$choice" = 0 ] || return 1

	# Hand the panel back to the status screen for the long phase; the
	# install ends in a reboot, so reaching the line after netinstall.sh
	# means it FAILED.
	status "STARTING NETWORK INSTALL"
	sh /etc/installer/netinstall.sh "$ANSWERS"
	ask info "INSTALL FAILED" \
		"$(head -2 "$STATUS_FILE" 2>/dev/null)" \
		"Full log: debug shell, /tmp + dmesg." > /dev/null
	return 1
}

# ---------------------------------------------------------------------- main

# Give the panel + touchscreen + rc.sh a moment to settle.
sleep 3

# PID 1 opens the dialog socket only after the display gate returns, which can
# take ~35 s in the worst case. Wait for it before the first prompt; if it
# never appears (no panel), the touch UI is unusable and the USB flow remains.
i=0
while [ ! -e /tmp/dc1-ask.sock ]; do
	[ "$i" -ge 60 ] && { log "dialog socket never appeared; USB flow only"; exit 0; }
	sleep 1
	i=$((i + 1))
done

while :; do
	choice=$(ask menu "DC-1 INSTALLER" \
		"Install from network (recommended)" \
		"Install via USB from a computer" \
		"Reboot to fastboot") \
		|| { log "dc1-ask unavailable; USB flow only"; exit 0; }
	case "$choice" in
		0) net_flow || : ;;
		1) usb_screen
		   status "WAITING FOR HOST
USB: 172.16.42.1
RUN DC1-INSTALL.SH ON HOST" ;;
		2) /bin/dc1-reboot-fastboot -f ;;
	esac
done
