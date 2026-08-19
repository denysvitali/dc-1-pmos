#!/bin/sh
# Offline tests for installer/src/provision.sh: validation and the pure
# file-edit provisioning, run against a fake rootfs directory. No root, no
# device, no network.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PROV="$HERE/../src/provision.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()   { pass=$((pass + 1)); echo "  ok: $*"; }
bad()  { failn=$((failn + 1)); echo "  FAIL: $*"; }

HASH='$6$testsalt$abcdefghijklmnopqrstuvwxyz0123456789'

write_answers() {
	# write_answers FILE [ssid] [psk]
	f=$1; ssid=${2:-}; psk=${3:-}
	{
		echo "DC1_USER=alice"
		echo "DC1_PASS_HASH=$HASH"
		echo "DC1_HOSTNAME=mydc1"
		echo "DC1_TZ=Europe/Zurich"
		if [ -n "$ssid" ]; then
			echo "DC1_WIFI_SSID_B64=$(printf '%s' "$ssid" | base64 | tr -d '\n')"
			echo "DC1_WIFI_PSK_B64=$(printf '%s' "$psk" | base64 | tr -d '\n')"
		else
			echo "DC1_WIFI_SSID_B64="
			echo "DC1_WIFI_PSK_B64="
		fi
	} > "$f"
}

make_rootfs() {
	# make_rootfs DIR -> fake pmOS-ish rootfs with one regular user "dc1"
	r=$1
	mkdir -p "$r/etc" "$r/home/dc1" "$r/usr/share/zoneinfo/Europe" \
		"$r/var/lib"
	cat > "$r/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
daemon:x:2:2:daemon:/sbin:/sbin/nologin
dc1:x:10000:10000:dc1 user:/home/dc1:/bin/ash
EOF
	cat > "$r/etc/shadow" <<'EOF'
root:!::0:::::
daemon:!::0:::::
dc1:!:19000:0:99999:7:::
EOF
	cat > "$r/etc/group" <<'EOF'
root:x:0:
wheel:x:10:dc1
video:x:27:dc1
audio:x:18:dc1
dc1:x:10000:
EOF
	cat > "$r/etc/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	oldname
EOF
	echo oldname > "$r/etc/hostname"
	touch "$r/usr/share/zoneinfo/Europe/Zurich"
	touch "$r/usr/share/zoneinfo/UTC"
	# The built image ships sshd.service DISABLED: pmbootstrap's --no-sshd
	# writes a disable preset that overrides the base preset's enable.
	# provision.sh must both create the wants symlink and drop the preset.
	mkdir -p "$r/usr/lib/systemd/system" "$r/usr/lib/systemd/system-preset"
	touch "$r/usr/lib/systemd/system/sshd.service"
	echo "disable sshd.service" \
		> "$r/usr/lib/systemd/system-preset/80-pmbootstrap-install-disable-sshd.preset"
}

# ---------------------------------------------------------- validation
echo "== validation =="

write_answers "$TMP/good"
sh "$PROV" --validate "$TMP/good" >/dev/null && ok "valid answers accepted" \
	|| bad "valid answers rejected"

sed 's/^DC1_USER=.*/DC1_USER=Alice/' "$TMP/good" > "$TMP/a"
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "uppercase username accepted" \
	|| ok "uppercase username rejected"

sed 's/^DC1_USER=.*/DC1_USER=root/' "$TMP/good" > "$TMP/a"
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "root username accepted" \
	|| ok "root username rejected"

sed 's/^DC1_PASS_HASH=.*/DC1_PASS_HASH=cleartext/' "$TMP/good" > "$TMP/a"
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "non-crypt hash accepted" \
	|| ok "non-crypt hash rejected"

sed 's/^DC1_HOSTNAME=.*/DC1_HOSTNAME=-bad-/' "$TMP/good" > "$TMP/a"
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "bad hostname accepted" \
	|| ok "bad hostname rejected"

sed 's|^DC1_TZ=.*|DC1_TZ=../../etc/shadow|' "$TMP/good" > "$TMP/a"
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "traversal timezone accepted" \
	|| ok "traversal timezone rejected"

write_answers "$TMP/a" "MyNet" "short"
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "short PSK accepted" \
	|| ok "short PSK rejected"

write_answers "$TMP/a" "MyNet" ""
sh "$PROV" --validate "$TMP/a" >/dev/null 2>&1 && bad "SSID without PSK accepted" \
	|| ok "SSID without PSK rejected"

# ------------------------------------------------- apply: rename user
echo "== apply: rename existing user =="
R="$TMP/root1"
make_rootfs "$R"
write_answers "$TMP/ans" "Home Net" "supersecret1"
sh "$PROV" "$R" "$TMP/ans" >/dev/null || bad "provision run failed"

grep -q '^alice:x:10000:10000:' "$R/etc/passwd" \
	&& ok "user renamed, uid preserved" || bad "passwd rename wrong"
grep -q '^dc1:' "$R/etc/passwd" && bad "old user still in passwd" \
	|| ok "old user gone from passwd"
grep -qF 'alice:$6$testsalt$' "$R/etc/shadow" \
	&& ok "password hash set in shadow" || bad "shadow hash wrong"
grep -q '^wheel:x:10:alice$' "$R/etc/group" \
	&& ok "group membership renamed" || bad "group membership wrong"
[ -d "$R/home/alice" ] && ok "home dir moved" || bad "home dir not moved"
[ "$(cat "$R/etc/hostname")" = "mydc1" ] && ok "hostname written" \
	|| bad "hostname wrong"
grep -q '^127\.0\.1\.1	mydc1$' "$R/etc/hosts" && ok "hosts updated" \
	|| bad "hosts wrong"
[ "$(readlink "$R/etc/localtime")" = "../usr/share/zoneinfo/Europe/Zurich" ] \
	&& ok "timezone symlink" || bad "timezone symlink wrong"

# sshd: always enabled, never conditional on the answers.
[ "$(readlink "$R/etc/systemd/system/multi-user.target.wants/sshd.service")" = \
	"/usr/lib/systemd/system/sshd.service" ] \
	&& ok "sshd enabled via wants symlink" || bad "sshd wants symlink wrong"
[ -e "$R/usr/lib/systemd/system-preset/80-pmbootstrap-install-disable-sshd.preset" ] \
	&& bad "pmbootstrap disable-sshd preset survived" \
	|| ok "pmbootstrap disable-sshd preset removed"

# Wi-Fi: no NM dir, no wpa_supplicant binary -> parked credentials.
[ -f "$R/var/lib/dc1-installer/wifi.pending" ] \
	&& ok "wifi parked without network stack" || bad "wifi.pending missing"
grep -q '^ssid=Home Net$' "$R/var/lib/dc1-installer/wifi.pending" \
	&& ok "parked ssid correct" || bad "parked ssid wrong"

# gdm-keyed provisioning must all no-op on a rootfs without gdm.
[ -e "$R/etc/ld-musl-aarch64.path" ] \
	&& bad "ld-musl path written on gdm-less rootfs" \
	|| ok "no ld-musl path on gdm-less rootfs"
[ -e "$R/usr/local/lib/libelogind.so.0" ] \
	&& bad "libelogind shim installed on gdm-less rootfs" \
	|| ok "no libelogind shim on gdm-less rootfs"

# ------------------------------------------------- apply: NM keyfile
echo "== apply: NetworkManager keyfile =="
R="$TMP/root2"
make_rootfs "$R"
mkdir -p "$R/etc/NetworkManager"
sh "$PROV" "$R" "$TMP/ans" >/dev/null || bad "provision run failed"
CONN="$R/etc/NetworkManager/system-connections/wifi.nmconnection"
[ -f "$CONN" ] && ok "keyfile written" || bad "keyfile missing"
grep -q '^ssid=Home Net$' "$CONN" && ok "keyfile ssid" || bad "keyfile ssid wrong"
grep -q '^psk=supersecret1$' "$CONN" && ok "keyfile psk" || bad "keyfile psk wrong"
perms=$(stat -c %a "$CONN")
[ "$perms" = 600 ] && ok "keyfile mode 600" || bad "keyfile mode $perms"

# ------------------------------------------------- apply: wpa_supplicant
echo "== apply: wpa_supplicant fallback =="
R="$TMP/root3"
make_rootfs "$R"
mkdir -p "$R/sbin" "$R/etc/init.d" "$R/etc/runlevels/default"
touch "$R/sbin/wpa_supplicant"; chmod 755 "$R/sbin/wpa_supplicant"
touch "$R/etc/init.d/wpa_supplicant"
sh "$PROV" "$R" "$TMP/ans" >/dev/null || bad "provision run failed"
WPA="$R/etc/wpa_supplicant/wpa_supplicant.conf"
[ -f "$WPA" ] && ok "wpa_supplicant.conf written" || bad "wpa conf missing"
grep -q 'ssid="Home Net"' "$WPA" && ok "wpa ssid" || bad "wpa ssid wrong"
[ -L "$R/etc/runlevels/default/wpa_supplicant" ] \
	&& ok "openrc service enabled" || bad "openrc symlink missing"

# ------------------------------------------------- apply: matching user
echo "== apply: username matches existing user =="
R="$TMP/root4"
make_rootfs "$R"
sed 's/^DC1_USER=.*/DC1_USER=dc1/' "$TMP/ans" > "$TMP/ans2"
sh "$PROV" "$R" "$TMP/ans2" >/dev/null || bad "provision run failed"
grep -q '^dc1:x:10000:' "$R/etc/passwd" && ok "existing user kept" \
	|| bad "existing user broken"
grep -qF 'dc1:$6$testsalt$' "$R/etc/shadow" && ok "password set on existing user" \
	|| bad "existing user hash wrong"

# ------------------------------------------------- apply: gdm autologin
echo "== apply: gdm autologin follows the rename =="
R="$TMP/root5"
make_rootfs "$R"
mkdir -p "$R/etc/gdm"
printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=dc1\n' \
	> "$R/etc/gdm/custom.conf"
write_answers "$TMP/ans3"
sh "$PROV" "$R" "$TMP/ans3" >/dev/null || bad "provision run failed"
grep -q '^AutomaticLogin=alice$' "$R/etc/gdm/custom.conf" \
	&& ok "gdm autologin rewritten to the renamed user" \
	|| bad "gdm autologin not rewritten (still: $(tr '\n' ' ' < "$R/etc/gdm/custom.conf"))"
# Wayland-only keys are added even here, but the libelogind shim is not:
# this rootfs carries no /lib/libsystemd.so.0 (e.g. an elogind image).
grep -q '^WaylandEnable=true$' "$R/etc/gdm/custom.conf" \
	&& ok "WaylandEnable=true added" || bad "WaylandEnable missing"
grep -q '^XorgEnable=false$' "$R/etc/gdm/custom.conf" \
	&& ok "XorgEnable=false added" || bad "XorgEnable missing"
[ -e "$R/usr/local/lib/libelogind.so.0" ] \
	&& bad "libelogind shim installed without libsystemd in rootfs" \
	|| ok "no libelogind shim without libsystemd"
[ -e "$R/etc/ld-musl-aarch64.path" ] \
	&& bad "ld-musl path written without libsystemd in rootfs" \
	|| ok "no ld-musl path without libsystemd"

# ----------------------------------------- apply: gdm wayland + libelogind
echo "== apply: gdm wayland pin + libelogind shim =="
R="$TMP/rootgdm"
make_rootfs "$R"
mkdir -p "$R/etc/gdm" "$R/lib"
# WaylandEnable=false simulates a stray packaged value: it must be
# rewritten in place, not duplicated, and the autologin block must survive.
printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=dc1\nWaylandEnable=false\n' \
	> "$R/etc/gdm/custom.conf"
touch "$R/lib/libsystemd.so.0"
sh "$PROV" "$R" "$TMP/ans3" >/dev/null || bad "provision run failed"
grep -q '^WaylandEnable=true$' "$R/etc/gdm/custom.conf" \
	&& ok "WaylandEnable=false rewritten to true" || bad "WaylandEnable wrong"
[ "$(grep -c '^WaylandEnable=' "$R/etc/gdm/custom.conf")" = 1 ] \
	&& ok "WaylandEnable not duplicated" || bad "WaylandEnable duplicated"
grep -q '^XorgEnable=false$' "$R/etc/gdm/custom.conf" \
	&& ok "XorgEnable=false added under [daemon]" || bad "XorgEnable missing"
grep -q '^AutomaticLoginEnable=True$' "$R/etc/gdm/custom.conf" \
	&& ok "packaged autologin block preserved" || bad "autologin block lost"
[ "$(readlink "$R/usr/local/lib/libelogind.so.0")" = "/lib/libsystemd.so.0" ] \
	&& ok "libelogind shim points at libsystemd" || bad "libelogind shim wrong"
printf '/usr/local/lib\n/lib\n/usr/lib\n' \
	| cmp -s - "$R/etc/ld-musl-aarch64.path" \
	&& ok "ld-musl path: exactly /usr/local/lib, /lib, /usr/lib" \
	|| bad "ld-musl path content wrong"

# ------------------------------------------------- apply: sshd fallbacks
echo "== apply: sshd on an OpenRC-only rootfs =="
R="$TMP/root6"
make_rootfs "$R"
rm "$R/usr/lib/systemd/system/sshd.service"
mkdir -p "$R/etc/init.d" "$R/etc/runlevels/default"
touch "$R/etc/init.d/sshd"
sh "$PROV" "$R" "$TMP/ans3" >/dev/null || bad "provision run failed"
[ -L "$R/etc/runlevels/default/sshd" ] \
	&& ok "sshd enabled in openrc default runlevel" \
	|| bad "openrc sshd symlink missing"

echo "== apply: rootfs without any sshd refuses to provision =="
R="$TMP/root7"
make_rootfs "$R"
rm "$R/usr/lib/systemd/system/sshd.service"
sh "$PROV" "$R" "$TMP/ans3" >/dev/null 2>&1 \
	&& bad "provision succeeded with no sshd in rootfs" \
	|| ok "provision fails loudly when the rootfs ships no sshd"

echo
echo "test-provision: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
