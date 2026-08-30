#!/bin/sh
# Offline tests for the updater's opt-out gate and truthful result state.
# Mocks keep the full script away from apk, the network, and /var/lib/dc1.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UPDATE="$HERE/../../pmaports/device/testing/device-daylight-jagar/dc1-update"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "dc1-update test failed: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/var"

# update succeeds immediately; upgrade fails. Any call is recorded so the
# marker test can prove the script exits before invoking apk at all.
cat >"$TMP/bin/apk" <<'EOF'
#!/bin/sh
echo "$*" >>"$DC1_TEST_APK_LOG"
case ${1:-} in
	update) exit 0 ;;
	upgrade) exit 1 ;;
	*) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/apk"

# Force the best-effort parity path to fail without touching the network.
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP/bin/curl"

run_update() {
	DC1_VAR_DIR="$TMP/var" \
	DC1_TEST_APK_LOG="$TMP/apk.log" \
	PATH="$TMP/bin:/bin:/usr/bin" \
		sh "$UPDATE"
}

echo "-- opt-out marker prevents every apk action"
: >"$TMP/apk.log"
: >"$TMP/var/no-auto-update"
run_update
[ ! -s "$TMP/apk.log" ] || fail "apk ran despite no-auto-update"
[ ! -e "$TMP/var/update-state" ] || fail "disabled run rewrote update state"

echo "-- failed upgrade is recorded as failed even when parity also fails"
rm -f "$TMP/var/no-auto-update"
if run_update; then
	fail "failed apk upgrade returned success"
fi
grep -qx 'update' "$TMP/apk.log" || fail "apk update was not attempted"
grep -qx 'upgrade' "$TMP/apk.log" || fail "apk upgrade was not attempted"
grep -qx 'apk_upgrade=no' "$TMP/var/update-state" ||
	fail "state did not record the failed upgrade"
grep -qx 'parity_behind=unknown' "$TMP/var/update-state" ||
	fail "state did not record unavailable parity"

echo "dc1-update tests passed"
