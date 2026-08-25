#!/bin/sh
# Offline tests for the DC-1 headless charging mode (device-daylight-jagar,
# pkgrel >= 79): dc1-charging-generator's boot decision, dc1-charging-monitor's
# debounce/capacity library functions, the dc1-poweroff-flag hook, and the
# dc1-pwrkey exit matrix. No root, no device, no systemd, no network.
#
# What is deliberately NOT exercised here: real KEY_POWER injection into an
# event device (needs a uinput/eventfd-backed evdev device), the monitor's
# systemctl poweroff/reboot actions, the flag hook's /run/systemd/reboot|
# kexec skip branch (markers are root-owned; covered by code inspection),
# and dc1-pwrkey's live forever-watch with real event devices.
#
# HARNESS NOTE: interactive shells in some development environments carry a
# shell-function wrapper around grep (an ugrep shim) that flakes on certain
# flag combinations; CI has stock busybox/GNU grep. Every piece of logic
# below therefore runs in a CLEAN SUBPROCESS via
#
#	PATH=/bin:/usr/bin sh -c '...'
#
# and nothing in this file invokes grep or sources the scripts into its own
# shell. Results are identical locally and in CI.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DEVDIR="$HERE/../../pmaports/device/testing/device-daylight-jagar"
GEN="$DEVDIR/dc1-charging-generator"
MON="$DEVDIR/dc1-charging-monitor"
FLAGSH="$DEVDIR/dc1-poweroff-flag"
PWRSRC="$DEVDIR/dc1-pwrkey.c"

fail() { echo "dc1-charging test failed: $*" >&2; exit 1; }

for f in "$GEN" "$MON" "$FLAGSH" "$PWRSRC"; do
	[ -r "$f" ] || fail "missing implementation file: $f"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "-- generator decision matrix (library seam)"

# Scenario tree builder. Every tree starts fully positive: provisioned,
# VBUS present, empty ring. Individual tests then knock out exactly one
# gate so failures isolate the broken condition.
newtree() { # $1 = scenario name
	tree=$tmp/tree-$1
	var_dir=$tree/var
	supply=$tree/supply
	ring=$tree/ring
	flagfile=$var_dir/poweroff-clean
	dc1_extra=
	mkdir -p "$var_dir"
	touch "$var_dir/first-boot-apps-done"
	printf '%s\n' 1 >"$supply"
	: >"$ring"
}

ring_reason() { # $1 = firmware reason code; valid ring: marker present
	{
		printf '%s\n' 'lk early console noise'
		printf '%s\n' "BOOT_REASON: $1"
		printf '%s\n' 'jump to linux kernel 64Bit'
	} >"$ring"
}

# Garbage ring: tail marker reached, but no parsable BOOT_REASON anywhere
# (textual junk rather than binary bytes: portable across shells, and the
# parser only ever sees shell variables, where NUL handling differs).
ring_garbage() {
	{
		printf '%s\n' '~!@#$%^&*() lk gibberish, no reason field here'
		printf '%s\n' 'jump to linux kernel 64Bit'
	} >"$ring"
}

# Valid reason line but the kernel-handoff tail marker is absent: a stale
# or truncated ring must not get a vote.
ring_no_marker() {
	{
		printf '%s\n' 'BOOT_REASON: 1'
		printf '%s\n' 'truncated ring, handoff never reached'
	} >"$ring"
}

set_flag_fresh() {
	printf '%s\n' "$(date +%s)" >"$flagfile"
}

# gen_decide [EXTRA=EXPORT ...] -- run decide() against the current tree in
# a clean subprocess; echoes CHARGE (0) or DESKTOP (non-zero).
gen_decide() {
	PATH=/bin:/usr/bin DC1_CHARGING_LIB=1 GEN="$GEN" \
		GVAR="$var_dir" GSUP="$supply" GRING="$ring" \
		sh -c '
			export DC1_VAR_DIR="$GVAR" DC1_SUPPLY_ONLINE="$GSUP" \
				DC1_RING_FILE="$GRING"
			for kv in "$@"; do
				export "$kv"
			done
			. "$GEN"
			if decide; then
				echo CHARGE
			else
				echo DESKTOP
			fi
		' gen_decide "$@"
}

# gen_detect [EXTRA=EXPORT ...] -- same, but echoes detect_boot_reason's
# output and propagates its exit status.
gen_detect() {
	PATH=/bin:/usr/bin DC1_CHARGING_LIB=1 GEN="$GEN" \
		GVAR="$var_dir" GSUP="$supply" GRING="$ring" \
		sh -c '
			export DC1_VAR_DIR="$GVAR" DC1_SUPPLY_ONLINE="$GSUP" \
				DC1_RING_FILE="$GRING"
			for kv in "$@"; do
				export "$kv"
			done
			. "$GEN"
			detect_boot_reason
		' gen_detect "$@"
}

# Positive: authoritative charger verdict, flag not required...
newtree br1
ring_reason 1
[ "$(gen_decide)" = CHARGE ] || fail "BR=1 + VBUS + provisioned did not charge"
# ...with or without a fresh flag.
set_flag_fresh
[ "$(gen_decide)" = CHARGE ] || fail "BR=1 with a fresh flag did not charge"

# Positive fallback: unreadable/unparsable firmware verdicts still charge
# when the previous shutdown was clean (fresh flag) and VBUS is present.
newtree fallback
ring_garbage
set_flag_fresh
[ "$(gen_decide)" = CHARGE ] || fail "garbage ring with fresh flag did not charge"

newtree nomark
ring_no_marker
set_flag_fresh
[ "$(gen_decide)" = CHARGE ] || fail "ring without tail marker + fresh flag did not charge"

newtree noring
rm -f "$ring"
set_flag_fresh
[ "$(gen_decide)" = CHARGE ] || fail "missing ring file + fresh flag did not charge"

for reason in 0 2 31; do
	newtree "code$reason"
	ring_reason "$reason"
	set_flag_fresh
	[ "$(gen_decide)" = CHARGE ] ||
		fail "BR=$reason with fresh flag did not charge"
done

# Age boundary: fresh means age < MAX_AGE (default 604800), with DC1_NOW
# pinned so the wall clock cannot leak into the result.
ts=1700000000
newtree agebound
ring_reason 0
printf '%s\n' "$ts" >"$flagfile"
[ "$(gen_decide "DC1_NOW=$((ts + 604799))")" = CHARGE ] ||
	fail "flag age MAX_AGE-1 was refused"
[ "$(gen_decide "DC1_NOW=$((ts + 604800))")" = DESKTOP ] ||
	fail "flag age == MAX_AGE still charged"

# Last BOOT_REASON line wins.
newtree lastwin
{
	printf '%s\n' 'BOOT_REASON: 0'
	printf '%s\n' 'noise'
	printf '%s\n' 'BOOT_REASON: 1'
	printf '%s\n' 'jump to linux kernel 64Bit'
} >"$ring"
[ "$(gen_detect)" = 1 ] || fail "detect_boot_reason did not take the LAST reason (want 1)"
[ "$(gen_decide)" = CHARGE ] || fail "last-wins BR=1 did not charge without a flag"

# Reversed order: the later 0 wins, so the verdict falls back to the flag.
newtree lastwinrev
{
	printf '%s\n' 'BOOT_REASON: 1'
	printf '%s\n' 'noise'
	printf '%s\n' 'BOOT_REASON: 0'
	printf '%s\n' 'jump to linux kernel 64Bit'
} >"$ring"
[ "$(gen_detect)" = 0 ] || fail "detect_boot_reason did not take the LAST reason (want 0)"
[ "$(gen_decide)" = DESKTOP ] || fail "reversed ring charged without a flag"
set_flag_fresh
[ "$(gen_decide)" = CHARGE ] || fail "reversed ring + fresh flag did not fall back to charge"

# Negatives. Opt-out wins over everything, even a perfect BR=1 boot.
newtree optout
ring_reason 1
set_flag_fresh
touch "$var_dir/no-charging-mode"
[ "$(gen_decide)" = DESKTOP ] || fail "opt-out file did not block charging mode"

# VBUS gate: missing, empty, and 0 supplies all block, even with BR=1.
for vbus in missing empty zero; do
	newtree "vbus-$vbus"
	ring_reason 1
	set_flag_fresh
	case $vbus in
	missing) rm -f "$supply" ;;
	empty)   : >"$supply" ;;
	zero)    printf '%s\n' 0 >"$supply" ;;
	esac
	[ "$(gen_decide)" = DESKTOP ] ||
		fail "VBUS state '$vbus' still charged despite BR=1"
done

# Provisioning gate: a never-provisioned system must reach the desktop.
newtree unprovisioned
ring_reason 1
set_flag_fresh
rm -f "$var_dir/first-boot-apps-done"
[ "$(gen_decide)" = DESKTOP ] ||
	fail "unprovisioned system charged despite BR=1"

# Watchdog / warm-reboot bypass codes never charge, even with a perfect
# fallback picture (fresh flag + VBUS + provisioned).
for reason in 3 4 5; do
	newtree "wdt$reason"
	ring_reason "$reason"
	set_flag_fresh
	[ "$(gen_decide)" = DESKTOP ] ||
		fail "BR=$reason charged despite fresh flag + VBUS"
done

# Flag hygiene: any unusable flag blocks the fallback path (BR=0 ring).
newtree flagstale
ring_reason 0
printf '%s\n' "$ts" >"$flagfile"
[ "$(gen_decide "DC1_NOW=$((ts + 604801))")" = DESKTOP ] ||
	fail "stale flag still enabled the fallback"

newtree flagfuture
ring_reason 0
printf '%s\n' "$((ts + 100))" >"$flagfile"
[ "$(gen_decide "DC1_NOW=$ts")" = DESKTOP ] ||
	fail "future-timestamped flag still enabled the fallback"

newtree flagnonum
ring_reason 0
set_flag_fresh
printf '%s\n' 'yesterday-ish' >"$flagfile"
[ "$(gen_decide)" = DESKTOP ] ||
	fail "non-numeric flag still enabled the fallback"

newtree flagempty
ring_reason 0
: >"$flagfile"
[ "$(gen_decide)" = DESKTOP ] ||
	fail "empty flag still enabled the fallback"

newtree flagabsent
ring_reason 0
rm -f "$flagfile"
[ "$(gen_decide)" = DESKTOP ] ||
	fail "absent flag still enabled the fallback"

echo "-- generator end-to-end (executed as systemd generator)"

# run_gen_e2e DIR -- execute the generator FILE itself (a fresh process,
# never sourced) with the current tree's environment; leaves rc in e2e_rc,
# stdout in e2e_out. Invoked through sh(1) because the in-repo file lacks
# the exec bit (the APKBUILD installs it with install -Dm755, so the
# on-device generator is executable; only the checkout copy is 644).
run_gen_e2e() {
	e2e_rc=0
	e2e_out=$(PATH=/bin:/usr/bin \
		DC1_VAR_DIR="$var_dir" DC1_SUPPLY_ONLINE="$supply" \
		DC1_RING_FILE="$ring" \
		sh "$GEN" "$1" 2>/dev/null) || e2e_rc=$?
}

newtree e2epos
ring_reason 1
outpos=$tmp/gen-out-pos
run_gen_e2e "$outpos"
[ "$e2e_rc" -eq 0 ] || fail "generator exited $e2e_rc on a charging boot"
[ -z "$e2e_out" ] || fail "generator wrote to stdout on a charging boot: $e2e_out"
[ -L "$outpos/default.target" ] ||
	fail "charging boot produced no default.target symlink"
got=$(readlink "$outpos/default.target")
[ "$got" = "/usr/lib/systemd/system/dc1-charging.target" ] ||
	fail "default.target resolves to '$got', want dc1-charging.target"

newtree e2eneg
ring_reason 3
outneg=$tmp/gen-out-neg
run_gen_e2e "$outneg"
[ "$e2e_rc" -eq 0 ] || fail "generator exited $e2e_rc on a normal boot"
[ -z "$e2e_out" ] || fail "generator wrote to stdout on a normal boot: $e2e_out"
[ ! -e "$outneg/default.target" ] && [ ! -L "$outneg/default.target" ] ||
	fail "normal boot staged a default.target"

echo "-- monitor library functions (library seam)"

mon_sup=$tmp/mon-supply
mon_cap=$tmp/mon-capacity
printf '%s\n' 1 >"$mon_sup"
printf '%s\n' 57 >"$mon_cap"

run_mon_online() {
	PATH=/bin:/usr/bin DC1_CHARGING_LIB=1 MON="$MON" MSUP="$mon_sup" \
		sh -c '
			export DC1_SUPPLY_ONLINE="$MSUP"
			. "$MON"
			if is_online; then echo ON; else echo OFF; fi
		' run_mon_online
}

run_mon_cap() {
	PATH=/bin:/usr/bin DC1_CHARGING_LIB=1 MON="$MON" MCAP="$mon_cap" \
		sh -c '
			export DC1_FG_CAPACITY="$MCAP"
			. "$MON"
			if v=$(read_capacity); then
				echo "OK:$v"
			else
				echo FAIL
			fi
		' run_mon_cap
}

# Debounce trace: for each supply state in $deb_seq, print counter/FIRE-or-WAIT.
run_mon_debounce() {
	PATH=/bin:/usr/bin DC1_CHARGING_LIB=1 MON="$MON" \
		MSUP="$mon_sup" MSEQ="$deb_seq" MOL="${deb_ol-2}" \
		sh -c '
			export DC1_SUPPLY_ONLINE="$MSUP" DC1_OFFLINE_TICKS="$MOL"
			. "$MON"
			c=0
			res=""
			for st in $MSEQ; do
				printf "%s\n" "$st" >"$DC1_SUPPLY_ONLINE"
				c=$(update_offline "$c")
				if decide_exit "$c"; then
					r=FIRE
				else
					r=WAIT
				fi
				res="$res $c/$r"
			done
			echo "trace:$res"
		' run_mon_debounce
}

printf '%s\n' 1 >"$mon_sup"
[ "$(run_mon_online)" = ON ] || fail "is_online said OFF with online=1"
printf '%s\n' 0 >"$mon_sup"
[ "$(run_mon_online)" = OFF ] || fail "is_online said ON with online=0"
: >"$mon_sup"
[ "$(run_mon_online)" = OFF ] || fail "is_online said ON with an empty attribute"
rm -f "$mon_sup"
[ "$(run_mon_online)" = OFF ] || fail "is_online said ON with a missing attribute"

printf '%s\n' 57 >"$mon_cap"
[ "$(run_mon_cap)" = OK:57 ] || fail "read_capacity mangled a numeric value"
printf '%s\n' 'garbage' >"$mon_cap"
[ "$(run_mon_cap)" = FAIL ] || fail "read_capacity accepted garbage"
: >"$mon_cap"
[ "$(run_mon_cap)" = FAIL ] || fail "read_capacity accepted an empty file"
rm -f "$mon_cap"
[ "$(run_mon_cap)" = FAIL ] || fail "read_capacity accepted a missing file"

# Debounce at OFFLINE_TICKS=2: increments while offline, fires EXACTLY at
# the limit, resets to zero as soon as power comes back. States are raw
# sysfs values: the attribute must contain exactly "1" to read online.
deb_seq='0 0 1 0 0'
deb_ol=2
[ "$(run_mon_debounce)" = 'trace: 1/WAIT 2/FIRE 0/WAIT 1/WAIT 2/FIRE' ] ||
	fail "offline debounce trace wrong: $(run_mon_debounce)"

# A non-numeric OFFLINE_LIMIT must disable the exit, not trip it.
deb_seq='off'
deb_ol=nothing
[ "$(run_mon_debounce)" = 'trace: 1/WAIT' ] ||
	fail "non-numeric OFFLINE_LIMIT changed the debounce outcome"

echo "-- dc1-pwrkey exit matrix"

if ! command -v gcc >/dev/null 2>&1; then
	echo "   (gcc not available; skipping dc1-pwrkey compilation)"
else
	PWRBIN=$tmp/dc1-pwrkey
	if ! gcc -Wall -Wextra -Os -o "$PWRBIN" "$PWRSRC" 2>"$tmp/cc.err"; then
		fail "dc1-pwrkey compile failed: $(cat "$tmp/cc.err")"
	fi
	[ ! -s "$tmp/cc.err" ] ||
		fail "gcc emitted warnings: $(cat "$tmp/cc.err")"

	# pwr_run ARGS... -- run the binary with DC1_INPUT_DIR=$pwr_in;
	# leaves rc in p_rc and stdout in p_out.
	pwr_run() {
		p_rc=0
		p_out=$(PATH=/bin:/usr/bin \
			DC1_INPUT_DIR="$pwr_in" "$PWRBIN" "$@" \
			2>/dev/null) || p_rc=$?
	}

	# Degraded scans (nothing to watch) must run out the clock to 62 --
	# "nothing happened", distinct from fatal -- not fail instantly.
	pwr_in=$tmp/no-such-input
	pwr_run 1
	[ "$p_rc" -eq 62 ] ||
		fail "nonexistent input dir + timeout 1: rc=$p_rc, want 62"
	[ -z "$p_out" ] || fail "timeout path wrote to stdout: $p_out"

	pwr_in=$tmp/empty-input
	mkdir -p "$pwr_in"
	pwr_t0=$(date +%s)
	pwr_run 1
	[ "$p_rc" -eq 62 ] ||
		fail "empty input dir + timeout 1: rc=$p_rc, want 62"
	pwr_t1=$(date +%s)
	[ $((pwr_t1 - pwr_t0)) -ge 1 ] ||
		fail "timeout=1 returned sooner than 1 s (deadline math)"

	# Usage errors exit 2 (source constant DC1_EXIT_USAGE): non-numeric,
	# negative, empty, overflowing timeouts, and extra arguments.
	for bad in abc -1 '' 99999999999999999999; do
		pwr_run "$bad"
		[ "$p_rc" -eq 2 ] ||
			fail "bad timeout '$bad': rc=$p_rc, want 2"
	done
	pwr_in=$tmp/empty-input
	pwr_run 5 6
	[ "$p_rc" -eq 2 ] || fail "extra args: rc=$p_rc, want 2"

	# Omitted timeout means "forever" with devices to watch; that live
	# mode needs a real event device (KEY_POWER injection is NOT
	# simulated here). In the degraded scan there is no forever: the
	# documented contract is an immediate FATAL exit 1 -- which also
	# proves the no-args path cannot hang the test.
	pwr_in=$tmp/no-such-input
	pwr_run
	[ "$p_rc" -eq 1 ] ||
		fail "no args + no watchers: rc=$p_rc, want 1 (fatal)"
fi

echo "-- poweroff-flag hook"

# flagrun ARGS... -- run the hook (fresh process, not sourced) with
# DC1_FLAG_FILE=$flag_path; leaves rc in f_rc and combined output in f_out.
# Via sh(1): the in-repo file has no exec bit; the APKBUILD installs -m755.
flagrun() {
	f_rc=0
	f_out=$(PATH=/bin:/usr/bin \
		DC1_FLAG_FILE="$flag_path" sh "$FLAGSH" "$@" 2>&1) || f_rc=$?
}

# Consume must create the flag's parent directories and clear any flag.
flag_path=$tmp/hook/deep/a/b/c/poweroff-clean
flagrun consume
[ "$f_rc" -eq 0 ] || fail "consume on a fresh path exited $f_rc"
[ -d "$tmp/hook/deep/a/b/c" ] || fail "consume did not create parent dirs"
[ ! -e "$flag_path" ] || fail "consume left a flag behind"
printf '%s\n' 12345 >"$flag_path"
flagrun consume
[ "$f_rc" -eq 0 ] || fail "consume over an existing flag exited $f_rc"
[ ! -e "$flag_path" ] || fail "consume did not remove an existing flag"

# Record (reboot markers absent on dev/CI machines) writes a fresh
# epoch-seconds stamp atomically.
flag_path=$tmp/hookrec/poweroff-clean
mkdir -p "$tmp/hookrec"
flagrun record
[ "$f_rc" -eq 0 ] || fail "record exited $f_rc: $f_out"
[ -f "$flag_path" ] || fail "record wrote no flag file"
rec_val=$(cat "$flag_path")
case $rec_val in
''|*[!0-9]*) fail "record wrote non-numeric content: '$rec_val'" ;;
esac
rec_now=$(date +%s)
skew=$((rec_val - rec_now))
[ "$skew" -le 60 ] && [ "$skew" -ge -60 ] ||
	fail "record timestamp $rec_val too far from now $rec_now"
entries=$(ls -A "$tmp/hookrec" | wc -l)
[ "$entries" -eq 1 ] || fail "record left temp files behind ($entries entries)"

# Bad invocations are usage errors (exit 2), never silent misbehavior.
flag_path=$tmp/hookusage/poweroff-clean
flagrun
[ "$f_rc" -eq 2 ] || fail "no-arg invocation: rc=$f_rc, want 2"
flagrun frobnicate
[ "$f_rc" -eq 2 ] || fail "unknown subcommand: rc=$f_rc, want 2"

# An unwritable destination fails the record (worst case: no flag, one
# normal desktop boot) instead of wedging the shutdown.
flag_path=$tmp/no-such-dir/poweroff-clean
flagrun record
[ "$f_rc" -ne 0 ] || fail "record into a missing directory succeeded"
[ ! -e "$flag_path" ] || fail "failed record left a flag"

# Not exercisable unprivileged, covered by inspection: the record path's
# /run/systemd/reboot and /run/systemd/kexec skip branch (root-owned
# markers; they are what keeps a warm reboot out of charging mode).

echo "dc1 charging mode tests passed"
