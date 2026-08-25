#!/bin/sh
# The Dummy Output guard must rewrite the WirePlumber 0.5.15 crash sites,
# stay silent when the file is already guarded, and leave an unmatched
# script alone.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$here/../../pmaports/device/testing/device-daylight-jagar/dc1-fix-wireplumber-alsa"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "dc1-fix-wireplumber-alsa test failed: $*" >&2; exit 1; }

[ -x "$helper" ] || fail "helper is not executable"

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
LUA

sh "$helper" "$tmp/alsa.lua" || fail "helper exited non-zero on a buggy script"
grep -q 'tostring(n:get_property("node.name"))' "$tmp/alsa.lua" ||
	fail "bind-failure log was not guarded"
grep -q 'tostring(node_name)' "$tmp/alsa.lua" ||
	fail "monitorNodeError log was not guarded"
grep -q 'n:get_property ("node.name")' "$tmp/alsa.lua" &&
	fail "un-guarded get_property site remains"

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

echo "dc1-fix-wireplumber-alsa tests passed"
