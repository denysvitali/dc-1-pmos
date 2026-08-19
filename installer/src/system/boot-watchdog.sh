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
#   3. a shell port is LISTENING, a probe peer answers ping, AND the shell
#      daemon proves it is alive: sshd must return its version banner (a
#      LISTEN socket is kernel state and survives a starved sshd -- the
#      2026-08-19 wedge), or the answering peer is the USB bench host and
#      the bannerless :4444 debug shell is listening.
#
# Firing escalates: two consecutive fires are plain reboots (a boot here is
# proven, and fastboot with no USB host attached strands the device); the
# third goes to fastboot for cable recovery. A reachable boot resets the
# streak.
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
# dc1-reboot-fastboot, DC1_PLAIN_REBOOT overrides reboot, DC1_SSH_PROBE
# (ok|dead) stubs the sshd banner check, DC1_NOW overrides the clock,
# DC1_ONCE runs one
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
# Consecutive unreachability fires, persisted across the reboots they cause;
# reset by the first reachable moment of any boot.
FIRE_COUNT="$VARDIR/watchdog-fires"

# stderr is silenced BEFORE the kmsg redirection is attempted (left-to-right),
# and the status never propagates: without the trailing ':', a non-root run
# (the offline tests) would exit 1 from any code path that ends in a log call.
log() {
	echo "dc1-boot-watchdog: $*"
	{ echo "dc1-boot-watchdog: $*" > /dev/kmsg; } 2>/dev/null || :
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
		tcp_state_on_port "$(port_hex "$p")" 01 && { REACH_PORT=$p; return 0; }
	done
	return 1
}

listening_on_shell_port() {
	for p in $PORTS; do
		tcp_state_on_port "$(port_hex "$p")" 0A && { REACH_PORT=$p; return 0; }
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
		$PING -c 1 -W 2 "$h" >/dev/null 2>&1 && { REACH_PEER=$h; return 0; }
	done
	return 1
}

# sshd_responds: a LISTEN socket is kernel state and survives a starved or
# wedged sshd -- measured 2026-08-19, when userspace starvation left the
# listen socket accepting while sshd never sent its banner for 30+ minutes
# and this watchdog kept calling the device "reachable". A shell channel
# only counts if the daemon TALKS: connect to it locally and require the
# SSH version banner within a few seconds. busybox nc has no read timeout,
# so the timeout wraps the whole probe.
sshd_responds() {
	if [ -n "${DC1_SSH_PROBE:-}" ]; then
		[ "$DC1_SSH_PROBE" = ok ]
		return
	fi
	banner=$(echo "" | timeout 5 nc 127.0.0.1 "$1" 2>/dev/null | head -c 4)
	[ "$banner" = "SSH-" ]
}

# Sets REACH_WHY so the log says WHICH condition patted -- when a boot pats
# unexpectedly (it happened: a forgotten bench-host watcher answered the
# probe), the journal must be able to answer "why" without a re-run.
reachable() {
	REACH_WHY=""
	if [ -e "$PAT_FILE" ]; then
		REACH_WHY="explicit pat file"; return 0
	fi
	if established_on_shell_port; then
		REACH_WHY="established connection on port $REACH_PORT"; return 0
	fi
	if listening_on_shell_port; then
		lp=$REACH_PORT
		if probe_peers_answer; then
			# The path is up; now prove a shell daemon is ALIVE, not
			# just listening. sshd proves itself with its banner. The
			# 4444 debug shell has no banner, so it counts only when
			# the answering peer is the USB bench host -- the one
			# place that can actually use it.
			if sshd_responds 22; then
				REACH_WHY="listener on :$lp + $REACH_PEER answers + sshd banner"
				return 0
			fi
			usb_peer=${PROBE_HOSTS%% *}
			if [ "$REACH_PEER" = "$usb_peer" ] \
				&& tcp_state_on_port "$(port_hex 4444)" 0A; then
				REACH_WHY="USB bench $REACH_PEER answers + :4444 listener"
				return 0
			fi
			REACH_WHY=""
		fi
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
	# A reachable boot ends any escalation streak.
	rm -f "$FIRE_COUNT" 2>/dev/null
}

# Escalation: a plain reboot first -- it clears wedges (a boot here is
# proven) and never strands the device, which reboot-to-fastboot DOES when
# no USB host is attached (fastboot waits on a cable forever; learned
# 2026-08-19 when the bench cable was unplugged). Only a THIRD consecutive
# unreachable boot escalates to fastboot: by then reboots demonstrably do
# not help, and a human with a cable is the remaining audience.
fire() {
	n=$(cat "$FIRE_COUNT" 2>/dev/null)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	n=$((n + 1))
	mkdir -p "$VARDIR" 2>/dev/null
	echo "$n" > "$FIRE_COUNT" 2>/dev/null
	sync
	if [ "$n" -lt 3 ]; then
		log "UNREACHABLE for ${DEADLINE}s; plain reboot (consecutive fire $n of 3)"
		${DC1_PLAIN_REBOOT:-reboot} && exit 0
		log "plain reboot failed; escalating to fastboot"
	else
		log "UNREACHABLE for ${DEADLINE}s and $n consecutive fires;" \
		    "rebooting into fastboot for cable recovery"
	fi
	[ -x "$REBOOT_CMD" ] || REBOOT_CMD=$(command -v dc1-reboot-fastboot 2>/dev/null)
	if [ -n "$REBOOT_CMD" ]; then
		"$REBOOT_CMD" && exit 0
		log "dc1-reboot-fastboot failed; falling back to a plain reboot"
	else
		log "dc1-reboot-fastboot not found; falling back to a plain reboot"
	fi
	# Last resort: the same slot boots again and this watchdog re-arms, so an
	# unreachable device keeps cycling instead of sitting dark forever.
	exec ${DC1_PLAIN_REBOOT:-reboot}
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
			[ "$was_reachable" = yes ] || log "reachable ($REACH_WHY)"
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
