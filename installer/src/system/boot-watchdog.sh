#!/bin/sh
# dc1-boot-watchdog -- reachability watchdog for the INSTALLED system.
#
# The DC-1 has no remote way back from a boot that "succeeds" but cannot be
# reached: systemd is healthy, so the hardware watchdog is petted forever,
# and without Wi-Fi or USB networking the only recovery is a physical key
# combo. This service closes that hole. It considers the device reachable
# while any remote-shell channel is provably alive, and when it has been
# unreachable for DEADLINE seconds it reboots into LK fastboot (via
# dc1-reboot-fastboot, hardware-verified), which is a state the attached
# host can always re-flash from.
#
# "Reachable" is any of, checked every CHECK_INTERVAL seconds:
#   1. an explicit pat: /run/dc1-boot-watchdog.pat exists
#      (`dc1-boot-watchdog pat` over any shell);
#   2. an ESTABLISHED inbound TCP connection on a shell port (sshd:22 or the
#      dc1-debug-shell on 4444) -- someone is already in;
#   3. a shell port is LISTENING and a probe peer answers ping: the USB host
#      (172.16.42.2) or the Wi-Fi default gateway -- nobody is in, but the
#      path is up.
#
# The first time the device is reachable each boot, /var/lib/dc1/boot-ok is
# created; the initramfs deadman (installer/src/system/init.c) waits for that
# file and reboots to fastboot itself if it never appears, which covers the
# window before this unit runs -- including a systemd that wedges before
# multi-user.target. boot.sh removes the stale file on every boot.
#
# The deadline survives service restarts: the last-reachable timestamp lives
# in /run (cleared by reboot, kept across a crash-looping unit), so a
# restarting service cannot indefinitely re-arm its own grace period.
#
# Opting out: `touch /etc/dc1/boot-watchdog.disabled` (persistent) or
# `systemctl disable dc1-boot-watchdog`. Tunables in
# /etc/dc1/boot-watchdog.conf (DEADLINE, CHECK_INTERVAL, PORTS, PROBE_HOSTS).
#
# Test hooks: DC1_PROC overrides /proc, DC1_RUNDIR overrides /run,
# DC1_VARDIR overrides /var/lib/dc1, DC1_CONFDIR overrides /etc/dc1,
# DC1_PING overrides the ping command, DC1_REBOOT_CMD overrides
# dc1-reboot-fastboot, DC1_NOW overrides the clock, DC1_ONCE runs one
# iteration and exits (its exit code: 0 reachable, 1 not yet fatal, 99 would
# have fired).

PROC=${DC1_PROC:-/proc}
RUNDIR=${DC1_RUNDIR:-/run}
VARDIR=${DC1_VARDIR:-/var/lib/dc1}
CONFDIR=${DC1_CONFDIR:-/etc/dc1}
PING=${DC1_PING:-ping}
REBOOT_CMD=${DC1_REBOOT_CMD:-/usr/local/sbin/dc1-reboot-fastboot}

# Defaults; /etc/dc1/boot-watchdog.conf may override.
DEADLINE=600
CHECK_INTERVAL=20
PORTS="22 4444"
PROBE_HOSTS="172.16.42.2"

[ -r "$CONFDIR/boot-watchdog.conf" ] && . "$CONFDIR/boot-watchdog.conf"

PAT_FILE="$RUNDIR/dc1-boot-watchdog.pat"
LASTOK_FILE="$RUNDIR/dc1-boot-watchdog.last-ok"
BOOT_OK="$VARDIR/boot-ok"

log() {
	echo "dc1-boot-watchdog: $*"
	echo "dc1-boot-watchdog: $*" > /dev/kmsg 2>/dev/null
}

now() { if [ -n "$DC1_NOW" ]; then echo "$DC1_NOW"; else date +%s; fi; }

# Hex (uppercase, 4 digits) for each configured port, once.
port_hex() {
	printf '%04X' "$1"
}

# /proc/net/tcp{,6}: field 2 is local_address (HEXIP:HEXPORT), field 4 the
# state -- 01 ESTABLISHED, 0A LISTEN. No awk dependency: sed+grep only.
tcp_state_on_port() {   # $1=hex port  $2=state  -> success if present
	# shellcheck disable=SC2013
	for f in "$PROC/net/tcp" "$PROC/net/tcp6"; do
		[ -r "$f" ] || continue
		grep -q "^ *[0-9]*: [0-9A-F]*:$1 [0-9A-F]*:[0-9A-F]* $2 " "$f" && return 0
	done
	return 1
}

established_on_shell_port() {
	for p in $PORTS; do
		tcp_state_on_port "$(port_hex "$p")" 01 && return 0
	done
	return 1
}

listening_on_shell_port() {
	for p in $PORTS; do
		tcp_state_on_port "$(port_hex "$p")" 0A && return 0
	done
	return 1
}

# Default IPv4 gateway from /proc/net/route: destination 00000000, gateway is
# little-endian hex. Empty output when there is no default route.
default_gateway() {
	# shellcheck disable=SC2162
	while read iface dest gw rest; do
		[ "$dest" = "00000000" ] || continue
		set -- \
			$((0x$(echo "$gw" | cut -c7-8))) \
			$((0x$(echo "$gw" | cut -c5-6))) \
			$((0x$(echo "$gw" | cut -c3-4))) \
			$((0x$(echo "$gw" | cut -c1-2)))
		echo "$1.$2.$3.$4"
		return 0
	done < "$PROC/net/route" 2>/dev/null
	return 1
}

probe_peers_answer() {
	gw=$(default_gateway 2>/dev/null || true)
	for h in $PROBE_HOSTS $gw; do
		[ "$h" = "0.0.0.0" ] && continue
		$PING -c 1 -W 2 "$h" >/dev/null 2>&1 && return 0
	done
	return 1
}

reachable() {
	[ -e "$PAT_FILE" ] && return 0
	established_on_shell_port && return 0
	if listening_on_shell_port && probe_peers_answer; then
		return 0
	fi
	return 1
}

mark_boot_ok() {
	# Once per boot; the initramfs deadman only needs existence, and not
	# rewriting it keeps the rootfs quiet.
	[ -e "$BOOT_OK" ] && return 0
	mkdir -p "$VARDIR" 2>/dev/null
	echo "reachable $(now)" > "$BOOT_OK" 2>/dev/null \
		&& log "first reachability this boot; initramfs deadman satisfied ($BOOT_OK)"
}

fire() {
	log "UNREACHABLE for ${DEADLINE}s (no shell connection, no listener+peer);" \
	    "rebooting into fastboot for remote recovery"
	sync
	[ -x "$REBOOT_CMD" ] || REBOOT_CMD=$(command -v dc1-reboot-fastboot 2>/dev/null)
	if [ -n "$REBOOT_CMD" ]; then
		"$REBOOT_CMD" && exit 0
		log "dc1-reboot-fastboot failed; falling back to a plain reboot"
	else
		log "dc1-reboot-fastboot not found; falling back to a plain reboot"
	fi
	# Last resort: the same slot boots again and this watchdog re-arms, so an
	# unreachable device keeps cycling instead of sitting dark forever.
	exec reboot
}

run() {
	if [ -e "$CONFDIR/boot-watchdog.disabled" ]; then
		log "disabled by $CONFDIR/boot-watchdog.disabled; exiting"
		exit 0
	fi
	log "armed: deadline ${DEADLINE}s, ports [$PORTS]," \
	    "probes [$PROBE_HOSTS + default gw], interval ${CHECK_INTERVAL}s"

	# Survive our own restarts: reuse the previous last-ok if one exists,
	# else start the clock now.
	last_ok=$(cat "$LASTOK_FILE" 2>/dev/null)
	case "$last_ok" in
		''|*[!0-9]*) last_ok=$(now); echo "$last_ok" > "$LASTOK_FILE" ;;
	esac

	was_reachable=""
	while :; do
		if reachable; then
			last_ok=$(now)
			echo "$last_ok" > "$LASTOK_FILE"
			mark_boot_ok
			[ "$was_reachable" = yes ] || log "reachable"
			was_reachable=yes
		else
			[ "$was_reachable" = no ] || log "unreachable; deadline ${DEADLINE}s running"
			was_reachable=no
			t=$(now)
			if [ $((t - last_ok)) -ge "$DEADLINE" ]; then
				[ -n "$DC1_ONCE" ] && exit 99
				fire
			fi
		fi
		[ -n "$DC1_ONCE" ] && { [ "$was_reachable" = yes ] && exit 0 || exit 1; }
		sleep "$CHECK_INTERVAL"
	done
}

case "${1:-run}" in
	run)    run ;;
	pat)
		mkdir -p "$RUNDIR" 2>/dev/null
		echo "pat $(now)" > "$PAT_FILE"
		mark_boot_ok
		log "patted; this boot will not be rebooted for unreachability"
		;;
	status)
		if [ -e "$CONFDIR/boot-watchdog.disabled" ]; then echo "disabled"; exit 0; fi
		if reachable; then echo "reachable"; else
			t=$(now); lo=$(cat "$LASTOK_FILE" 2>/dev/null || echo "$t")
			echo "UNREACHABLE for $((t - lo))s of ${DEADLINE}s"
		fi
		;;
	*)
		echo "usage: dc1-boot-watchdog [run|pat|status]" >&2
		exit 2
		;;
esac
