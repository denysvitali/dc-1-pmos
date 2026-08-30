#!/bin/sh
# Offline tests for installer/host/dc1-install.sh pure functions. The host
# script is meant to be sourced with DC1_INSTALL_LIB=1; here we exercise
# require_dtbswap -- the fastboot-side gate that refuses to flash a boot
# image whose kernel slot does not carry our device tree.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

# Source the library portion; die() keeps its real definition (prints to
# stderr, exit 1) so refusals are observable as subshell non-zero exits.
DC1_INSTALL_LIB=1 . "$HERE/../host/dc1-install.sh"

mkimg() { # OUT SLOTBYTESFILE
	python3 - "$1" "$2" <<'PY'
import struct, sys
img, kern = sys.argv[1], open(sys.argv[2], 'rb').read()
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(kern))
open(img, 'wb').write(hdr + b'\0' * (4096 - 1584) + kern)
PY
}

head -c 12345 /dev/zero | tr '\0' 'K' | gzip -c > "$TMP/plain.gz"
mkimg "$TMP/plain.img" "$TMP/plain.gz"
! (require_dtbswap "$TMP/plain.img") 2>/dev/null \
	&& ok "plain (stock-DT) image refused" || bad "plain image accepted"

head -c 12345 /dev/zero | tr '\0' 'K' > "$TMP/raw"
python3 - "$TMP/dtbswap.img" "$TMP/raw" <<'PY'
import struct, sys, gzip
kern = open(sys.argv[2], 'rb').read()
stub = bytearray(5904)
stub[56:60] = b'ARM\x64'
dtb = b'\xd0\x0d\xfe\xed' + b'D' * 996
doff = len(stub); koff = doff + len(dtb)
struct.pack_into('<4I', stub, 0x40, doff, len(dtb), koff, len(kern))
gz = gzip.compress(bytes(stub) + dtb + kern)
hdr = bytearray(1584)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<I', hdr, 8, len(gz))
open(sys.argv[1], 'wb').write(hdr + b'\0' * (4096 - 1584) + gz)
PY
require_dtbswap "$TMP/dtbswap.img" \
	&& ok "dtbswap payload accepted" || bad "dtbswap payload refused"

printf 'not an image at all' > "$TMP/garbage.img"
! (require_dtbswap "$TMP/garbage.img") 2>/dev/null \
	&& ok "garbage refused" || bad "garbage accepted"

# Wiring: BOTH images must pass the gate before any fastboot write --
# installer-boot.img too (issue #1: the stock tree black-screens
# installation mode on some units). dtbswap-only, no plain path.
grep -q 'require_dtbswap "\$INSTALLER_BOOT"' "$HERE/../host/dc1-install.sh" \
	&& ok "installer image is gated" || bad "installer image is not gated"
grep -q 'require_dtbswap "\$BOOT_IMAGE"' "$HERE/../host/dc1-install.sh" \
	&& ok "system boot image is gated" || bad "system boot image is not gated"

# Slot selection is part of each boot_a write. A device previously active on
# slot B would otherwise reboot the untouched slot after a successful flash.
SCRIPT="$HERE/../host/dc1-install.sh"
installer_seq=$(sed -n '/msg "flashing installer to boot_a"/,/fastboot reboot/p' "$SCRIPT")
printf '%s\n' "$installer_seq" | awk '
	/fastboot flash boot_a/ { flash = NR }
	/fastboot set_active a/ { active = NR }
	/fastboot reboot/ { reboot = NR }
	END { exit !(flash && flash < active && active < reboot) }
' && ok "installer flash selects slot A before reboot" \
	|| bad "installer flash does not select slot A before reboot"

system_seq=$(sed -n '/msg "flashing real boot image to boot_a"/,/fastboot reboot/p' "$SCRIPT")
printf '%s\n' "$system_seq" | awk '
	/fastboot flash boot_a/ { flash = NR }
	/fastboot set_active a/ { active = NR }
	/fastboot reboot/ { reboot = NR }
	END { exit !(flash && flash < active && active < reboot) }
' && ok "system flash selects slot A before reboot" \
	|| bad "system flash does not select slot A before reboot"

manual_seq=$(sed -n '/done -- now flash the real boot image/,/fastboot reboot/p' "$SCRIPT")
printf '%s\n' "$manual_seq" | grep -q 'fastboot set_active a' \
	&& ok "manual completion selects slot A" \
	|| bad "manual completion omits slot A selection"

echo
echo "test-dc1-install: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
