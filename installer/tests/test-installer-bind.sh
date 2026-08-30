#!/bin/sh
# Static regression gate for the effective installer-mode listener policy.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
RC="$HERE/../src/rc.sh"

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

if grep -q '/bin/dc1-installd -listen 172\.16\.42\.1:5555' "$RC"; then
	ok "Go installer binds only to the USB address"
else
	bad "Go installer USB-only bind missing"
fi

if grep -Eq 'nc .*5555|5555.*-e /etc/installer/receive\.sh' "$RC"; then
	bad "unsafe shell receiver is still served"
else
	ok "unsafe shell receiver is never served"
fi

if grep -q 'ip addr show usb0' "$RC" && \
	grep -q 'NOT starting installer receiver' "$RC"; then
	ok "receiver waits for usb0 and fails closed"
else
	bad "receiver does not fail closed when usb0 is absent"
fi

if grep -q '0\.0\.0\.0:5555' "$RC"; then
	bad "wildcard installer bind remains"
else
	ok "no wildcard installer bind"
fi

echo
echo "test-installer-bind: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
