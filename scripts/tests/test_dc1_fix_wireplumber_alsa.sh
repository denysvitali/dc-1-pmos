#!/bin/sh
# The Dummy Output guard must rewrite the WirePlumber 0.5.15 crash sites,
# stay silent when the file is already guarded, leave an unmatched script
# alone, and the apk trigger must dispatch kernel vs wireplumber paths
# without mixing them.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay="$here/../../pmaports/device/testing/device-daylight-jagar"
helper="$overlay/dc1-fix-wireplumber-alsa"
trigger="$overlay/device-daylight-jagar.trigger"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "dc1-fix-wireplumber-alsa test failed: $*" >&2; exit 1; }

[ -x "$helper" ] || fail "helper is not executable"
[ -x "$trigger" ] || fail "trigger is not executable"

cat >"$tmp/alsa.lua" <<'LUA'
function monitorNodeError (node)
  node:connect("state-changed", function (n, old_state, new_state)
    if new_state == "error" and old_state ~= "error" then
      local node_name = n:get_property ("node.name")
      log:info ("Error received on ALSA node " .. node_name)
      log:warning ("Could not find ALSA device for node " .. node_name)
    end
  end)
end

node:activate(Feature.Proxy.BOUND, function (n, err)
    if err then
      log:warning ("Failed to create ALSA node " ..
          n:get_property ("node.name") .. ": " .. tostring(err))
    end
end)

-- Keep the names table identifier intact.
node_names_table[name] = true
log:info ("Create ALSA SplitPCM HW node " .. split_hw_node_name)
LUA

sh "$helper" "$tmp/alsa.lua" || fail "helper exited non-zero on a buggy script"
grep -q 'tostring(n:get_property("node.name"))' "$tmp/alsa.lua" ||
	fail "bind-failure log was not guarded"
grep -q 'tostring(node_name)' "$tmp/alsa.lua" ||
	fail "monitorNodeError log was not guarded"
grep -q 'n:get_property ("node.name")' "$tmp/alsa.lua" &&
	fail "un-guarded get_property site remains"
grep -q 'tostring(node_name)s_table' "$tmp/alsa.lua" &&
	fail "rewrote node_names_table"
grep -q 'node_names_table\[name\]' "$tmp/alsa.lua" ||
	fail "node_names_table assignment was disturbed"
grep -q '\.\. split_hw_node_name' "$tmp/alsa.lua" ||
	fail "unrelated concatenation was disturbed"

# Idempotent: a second pass must not double-wrap or fail.
cp "$tmp/alsa.lua" "$tmp/once.lua"
sh "$helper" "$tmp/alsa.lua" || fail "helper exited non-zero on a guarded script"
cmp -s "$tmp/alsa.lua" "$tmp/once.lua" || fail "second pass rewrote a guarded script"
grep -q 'tostring(tostring(' "$tmp/alsa.lua" &&
	fail "second pass double-wrapped tostring()"

# Missing file, or a script without the crash site, is a successful no-op.
sh "$helper" "$tmp/missing.lua" || fail "helper exited non-zero on a missing file"
printf 'log:info("ok")\n' >"$tmp/other.lua"
cp "$tmp/other.lua" "$tmp/other.lua.orig"
sh "$helper" "$tmp/other.lua" || fail "helper exited non-zero on an unmatched script"
cmp -s "$tmp/other.lua" "$tmp/other.lua.orig" || fail "unmatched script was rewritten"

# On-device extra: the live WirePlumber script must actually be patchable.
live=/usr/share/wireplumber/scripts/monitors/alsa.lua
if [ -f "$live" ]; then
	cp "$live" "$tmp/live.lua"
	sh "$helper" "$tmp/live.lua" || fail "helper exited non-zero on live alsa.lua"
	grep -q 'tostring(n:get_property("node.name"))' "$tmp/live.lua" ||
		fail "live alsa.lua bind-failure log was not guarded"
	grep -q 'n:get_property ("node.name")' "$tmp/live.lua" &&
		fail "live alsa.lua still has an un-guarded get_property site"
	grep -q 'tostring(node_name)s_table' "$tmp/live.lua" &&
		fail "live alsa.lua node_names_table was corrupted"
fi

# Trigger dispatch: a wireplumber path must not deploy a kernel, a kernel
# path (or no args) must not skip the A/B deploy, and both may run.
mkdir -p "$tmp/libexec"
printf '#!/bin/sh\necho helper "$@" >>"%s/helper.log"\n' "$tmp" \
	>"$tmp/libexec/dc1-fix-wireplumber-alsa"
printf '#!/bin/sh\necho boot-sync "$@" >>"%s/boot.log"\n' "$tmp" \
	>"$tmp/libexec/dc1-boot-sync"
chmod 0755 "$tmp/libexec/dc1-fix-wireplumber-alsa" \
	"$tmp/libexec/dc1-boot-sync"

run_trigger() {
	rm -f "$tmp/helper.log" "$tmp/boot.log"
	DC1_LIBEXEC="$tmp/libexec" sh "$trigger" "$@" ||
		fail "trigger exited non-zero for: $*"
}

run_trigger /usr/share/wireplumber/scripts/monitors/alsa.lua
[ -f "$tmp/helper.log" ] || fail "alsa.lua trigger did not run the helper"
[ -f "$tmp/boot.log" ] && fail "alsa.lua trigger deployed a kernel"

run_trigger /boot/vmlinuz
[ -f "$tmp/boot.log" ] || fail "kernel trigger did not run dc1-boot-sync"
[ -f "$tmp/helper.log" ] && fail "kernel trigger ran the wireplumber helper"

run_trigger
[ -f "$tmp/boot.log" ] || fail "no-arg trigger did not run dc1-boot-sync"
[ -f "$tmp/helper.log" ] && fail "no-arg trigger ran the wireplumber helper"

run_trigger /boot/vmlinuz /usr/share/wireplumber/scripts/monitors/alsa.lua
[ -f "$tmp/helper.log" ] || fail "mixed trigger did not run the helper"
[ -f "$tmp/boot.log" ] || fail "mixed trigger did not run dc1-boot-sync"

echo "dc1-fix-wireplumber-alsa tests passed"
