#!/bin/sh
# Remove the Plasma Mobile session added by plasma-mobile-install.sh (root).
# Switches the owner's next login back to GNOME first; user data is kept.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
for f in /var/lib/AccountsService/users/*; do
	[ -f "$f" ] && sed -i 's/^Session=plasma-mobile$/Session=gnome/' "$f"
done
apk del postmarketos-ui-plasma-mobile plasma-keyboard
echo "Plasma Mobile removed; next login uses GNOME"
