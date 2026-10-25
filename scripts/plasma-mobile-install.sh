#!/bin/sh
# Add a Plasma Mobile session to an installed DC-1 (run on the tablet as root).
#
# Additive: GNOME stays installed and remains the default session. Afterwards
# the owner picks a session with `dc1-session --now plasma-mobile` and
# returns with `dc1-session --now gnome`. Removal: scripts/plasma-mobile-remove.sh.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

# postmarketos-ui-plasma-mobile: pmOS Plasma Mobile meta package (KWin,
# plasma-mobile shell, plasma-nm, plasma-settings, Waydroid integration,
# lock-on-start). plasma-keyboard: the touch keyboard Plasma Mobile 6.8 uses.
apk add postmarketos-ui-plasma-mobile plasma-keyboard

# The orientation bridge (device package >= 1-r117) exits with status 3 under
# KWin; older units keep restarting once a second during a Plasma session.
if ! grep -q RestartPreventExitStatus=3 /usr/lib/systemd/user/dc1-orientation.service; then
	echo "warning: device-daylight-jagar < 1-r117; dc1-orientation will loop under Plasma" >&2
fi

# pmOS ships /etc/xdg/kscreenlockerrc with LockOnStart=true, so every login
# begins at the lock screen asking for the account password as a PIN, and
# kscreenlocker's defaults lock again after 5 idle minutes and on resume.
# gdm autologin is this device's trust boundary and the GNOME session does
# not lock on its own, so match that for every existing owner account.
# ~/.config outranks /etc/xdg.
for home in /home/*; do
	[ -d "$home" ] || continue
	u=$(stat -c %U "$home")
	[ -f "$home/.config/kscreenlockerrc" ] && continue
	install -d -o "$u" -g "$u" "$home/.config"
	printf '[Daemon]\nLockOnStart=false\nAutolock=false\nLockOnResume=false\n' \
		>"$home/.config/kscreenlockerrc"
	chown "$u:$u" "$home/.config/kscreenlockerrc"
done

[ -f /usr/share/wayland-sessions/plasma-mobile.desktop ] || {
	echo "plasma-mobile.desktop missing after install" >&2; exit 1; }
echo "Plasma Mobile installed. As the owner: dc1-session --now plasma-mobile"
