#!/bin/sh
# Install only the setup GUI/CLI. Never initializes Android or touches a kernel.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run this installer through pkexec using its absolute path.' >&2; exit 1; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
apk add aria2 python3 py3-gobject3 gtk4.0 polkit
root=/usr/local/lib/dc1-waydroid-setup
install -d -m755 "$root" /usr/local/bin /usr/local/share/applications
install -m644 "$here/setup/backend.py" "$here/setup/gui.py" "$here/images.json" "$here/images-gapps.json" "$here/waydroid.config" "$root/"
cat > /usr/local/bin/dc1-waydroid-setup <<'LAUNCH'
#!/bin/sh
if [ "$#" -eq 0 ]; then
 exec /usr/bin/python3 /usr/local/lib/dc1-waydroid-setup/gui.py
fi
exec /usr/bin/python3 /usr/local/lib/dc1-waydroid-setup/backend.py "$@"
LAUNCH
chmod 755 /usr/local/bin/dc1-waydroid-setup
ln -sf dc1-waydroid-setup /usr/local/bin/dc1-waydroid-manager
install -d -m755 /usr/local/share/icons/hicolor/scalable/apps
install -m644 "$here/setup/waydroid-manager.svg" /usr/local/share/icons/hicolor/scalable/apps/io.github.muness.WaydroidManager.svg
cat > /usr/local/share/applications/io.github.muness.WaydroidSetup.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Waydroid Manager
Comment=Install, open and remove Android; diagnose problems
Exec=/usr/local/bin/dc1-waydroid-manager
Icon=io.github.muness.WaydroidManager
Terminal=false
Categories=System;Settings;
StartupNotify=true
DESKTOP
printf 'Installed Waydroid Manager. Open it from Applications as your desktop user.\n'
