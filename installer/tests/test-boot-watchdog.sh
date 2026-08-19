#!/bin/sh
# Offline tests for the reachability watchdog (src/system/boot-watchdog.sh,
# deployed into the installed system by src/system/boot.sh).
#
# Everything is faked through the script's documented test hooks: DC1_PROC for
# /proc, DC1_RUNDIR / DC1_VARDIR / DC1_CONFDIR for state and config, DC1_PING
# for the probe, DC1_NOW for the clock, DC1_REBOOT_CMD for the firing path,
# DC1_ONCE for single-iteration runs. No root, no device, no network.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WD="$HERE/../src/system/boot-watchdog.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

# Fixture layout. /proc/net/tcp local port field is uppercase hex: 22 = 0016,
# 4444 = 115C. State 01 = ESTABLISHED, 0A = LISTEN.
setup() {
	rm -rf "$TMP/proc" "$TMP/run" "$TMP/var" "$TMP/etc" "$TMP/log"
	mkdir -p "$TMP/proc/net" "$TMP/run" "$TMP/var" "$TMP/etc"
	: > "$TMP/proc/net/tcp"
	: > "$TMP/proc/net/tcp6"
	: > "$TMP/proc/net/route"
	cat > "$TMP/ping-ok" <<-'EOF'
		#!/bin/sh
		echo "$@" >> "${PING_LOG:-/dev/null}"
		exit 0
	EOF
	cat > "$TMP/ping-fail" <<-'EOF'
		#!/bin/sh
		echo "$@" >> "${PING_LOG:-/dev/null}"
		exit 1
	EOF
	cat > "$TMP/fake-reboot" <<-EOF
		#!/bin/sh
		echo fired > "$TMP/fired"
		exit 0
	EOF
	chmod +x "$TMP/ping-ok" "$TMP/ping-fail" "$TMP/fake-reboot"
}

tcp_line() {   # $1 file  $2 hexport  $3 state
	printf '   0: 0100007F:%s 00000000:0000 %s 00000000:00000000 00:00000000 00000000     0        0 0 1 0000000000000000\n' \
		"$2" "$3" >> "$TMP/proc/net/$1"
}

route_default() {   # $1 little-endian hex gw (192.168.1.1 -> 0101A8C0)
	printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n' \
		> "$TMP/proc/net/route"
	printf 'wlan0\t00000000\t%s\t0003\t0\t0\t0\t00000000\t0\t0\t0\n' "$1" \
		>> "$TMP/proc/net/route"
}

run_once() {   # extra env via preceding assignments; returns the exit code
	rc=0
	env DC1_PROC="$TMP/proc" DC1_RUNDIR="$TMP/run" DC1_VARDIR="$TMP/var" \
	    DC1_CONFDIR="$TMP/etc" DC1_REBOOT_CMD="$TMP/fake-reboot" \
	    DC1_ONCE=1 "$@" sh "$WD" run > "$TMP/log" 2>&1 || rc=$?
	return $rc
}

# --- 1. established shell connection => reachable, boot-ok written ----------
setup
tcp_line tcp 0016 01
run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 || bad "established ssh: rc=$?"
[ -e "$TMP/var/boot-ok" ] && ok "established :22 counts as reachable and pats the deadman" \
	|| bad "established :22 did not create boot-ok"

# --- 2. established on 4444 (debug shell) also counts ------------------------
setup
tcp_line tcp 115C 01
run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 \
	&& ok "established :4444 counts as reachable" \
	|| bad "established :4444 not recognized"

# --- 3. listener alone, no peer answering => NOT reachable -------------------
setup
tcp_line tcp 0016 0A
if run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000; then
	bad "listener with dead peers counted as reachable"
else
	[ ! -e "$TMP/var/boot-ok" ] && ok "listener + no answering peer is unreachable" \
		|| bad "boot-ok written while unreachable"
fi

# --- 4. listener + answering probe peer => reachable -------------------------
setup
tcp_line tcp6 0016 0A
run_once DC1_PING="$TMP/ping-ok" DC1_NOW=1000 \
	&& ok "listener (tcp6) + answering peer is reachable" \
	|| bad "listener + answering peer not recognized"
grep -q 'reachable (listener on :22 + 172.16.42.2 answers)' "$TMP/log" \
	&& ok "the log names WHICH condition patted" \
	|| bad "reachability reason missing from the log: $(grep reachable "$TMP/log")"

# --- 5. gateway from /proc/net/route is probed -------------------------------
setup
tcp_line tcp 0016 0A
route_default 0101A8C0
printf 'PROBE_HOSTS=""\n' > "$TMP/etc/boot-watchdog.conf"
run_once PING_LOG="$TMP/pings" DC1_PING="$TMP/ping-ok" DC1_NOW=1000 \
	|| bad "gateway probe run failed"
grep -q '192\.168\.1\.1' "$TMP/pings" \
	&& ok "default gateway decoded little-endian (0101A8C0 -> 192.168.1.1) and probed" \
	|| bad "gateway was not probed: $(cat "$TMP/pings" 2>/dev/null)"

# --- 6. explicit pat file wins even with nothing else ------------------------
setup
echo "pat 999" > "$TMP/run/dc1-boot-watchdog.pat"
run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 \
	&& ok "explicit pat file counts as reachable" \
	|| bad "pat file ignored"

# --- 7. unreachable but young => no fire (rc 1) -------------------------------
setup
echo 950 > "$TMP/run/dc1-boot-watchdog.last-ok"
rc=0; run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 || rc=$?
[ "$rc" = 1 ] && [ ! -e "$TMP/fired" ] \
	&& ok "unreachable inside the deadline does not fire (rc=1)" \
	|| bad "young unreachable state fired or wrong rc ($rc)"

# --- 8. unreachable past DEADLINE => would fire (rc 99) -----------------------
setup
echo 100 > "$TMP/run/dc1-boot-watchdog.last-ok"
rc=0; run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 || rc=$?
[ "$rc" = 99 ] && ok "deadline exceeded fires (rc=99 in DC1_ONCE mode)" \
	|| bad "deadline exceeded did not fire (rc=$rc)"

# --- 9. last-ok persistence: garbage resets to now, not to fire ---------------
setup
echo "not-a-number" > "$TMP/run/dc1-boot-watchdog.last-ok"
rc=0; run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 || rc=$?
[ "$rc" = 1 ] && grep -qx 1000 "$TMP/run/dc1-boot-watchdog.last-ok" \
	&& ok "corrupt last-ok resets the clock instead of firing" \
	|| bad "corrupt last-ok mishandled (rc=$rc)"

# --- 10. disabled flag exits cleanly ------------------------------------------
setup
: > "$TMP/etc/boot-watchdog.disabled"
run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 \
	&& ok "disable flag exits 0 without checking anything" \
	|| bad "disable flag did not exit 0"

# --- 11. conf overrides are honoured ------------------------------------------
setup
printf 'DEADLINE=50\n' > "$TMP/etc/boot-watchdog.conf"
echo 900 > "$TMP/run/dc1-boot-watchdog.last-ok"
rc=0; run_once DC1_PING="$TMP/ping-fail" DC1_NOW=1000 || rc=$?
[ "$rc" = 99 ] && ok "conf DEADLINE override respected (50s < 100s elapsed)" \
	|| bad "conf DEADLINE override ignored (rc=$rc)"

# --- 12. pat subcommand creates both markers -----------------------------------
setup
env DC1_RUNDIR="$TMP/run" DC1_VARDIR="$TMP/var" DC1_CONFDIR="$TMP/etc" \
    DC1_NOW=1234 sh "$WD" pat > /dev/null 2>&1 || bad "pat subcommand failed"
[ -e "$TMP/run/dc1-boot-watchdog.pat" ] && [ -e "$TMP/var/boot-ok" ] \
	&& ok "pat writes the run marker and the deadman file" \
	|| bad "pat did not write both markers"

echo "boot-watchdog: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
