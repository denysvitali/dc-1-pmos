# Plasma Mobile session (experimental)

An optional touch-first session next to the shipped GNOME desktop. It is
additive: GNOME stays installed and remains the default; the owner switches
sessions with `dc1-session` and can remove Plasma Mobile again. Nothing here
is wired into the rootfs build or CI.

## Why

GNOME Mobile's phone layout never activates on this panel: 1200×1600 at the
shipped 1.5× scale is 800×1067 logical pixels, above the fork's 500/1000
`_checkIsPhone()` thresholds, so the tablet runs the desktop layout with
mobile OSK/rotation patches. Plasma Mobile is the only interface in
postmarketOS (systemd edition) whose shell, settings, lock screen and window
management are designed for fingers: edge-swipe navigation, maximized
undecorated apps, a task switcher with live cards, Waydroid setup and a
container toggle in quick settings, and Plasma Keyboard.

![Plasma Mobile first-run screen on the DC-1, landscape, 2026-10-25](images/plasma-mobile/welcome.jpg)

![Google Play (Waydroid) as a Plasma Mobile task with the navigation bar below, 2026-10-25](images/plasma-mobile/waydroid-play-store.png)

![Plasma Mobile Settings on the DC-1, 2026-10-25](images/plasma-mobile/settings.png)

Screenshots: `spectacle -b` inside the session, 1200×1600 panel at 1.5× in
landscape, scaled to 900 px wide.

## Install (on the tablet)

```sh
sudo sh scripts/plasma-mobile-install.sh   # apk add postmarketos-ui-plasma-mobile plasma-keyboard
dc1-session --now plasma-mobile            # as the owner; ends the GNOME session
```

`dc1-session` writes the AccountsService `Session` key because gdm autologin
never shows its chooser. `dc1-session --now gnome` returns; `--list` shows
the installed sessions. `scripts/plasma-mobile-remove.sh` uninstalls.

## What the device package changes

- `dc1-orientation` stands down with exit status 3 under KWin, which
  follows `net.hadess.SensorProxy` itself; the unit's
  `RestartPreventExitStatus=3` then leaves it stopped instead of restarting
  once a second for the whole session. Two detections, because the unit
  starts at `default.target` before `startplasma-wayland` has imported
  `XDG_CURRENT_DESKTOP` into the user manager: the environment check in
  `main()`, and `org.kde.KWin` appearing on (or already owning) the session
  bus. Observed on 2026-10-25: the environment check alone missed the first
  Plasma login and the bridge sat waiting for Mutter.
- `/usr/bin/dc1-session` (above).
- The install script writes `~/.config/kscreenlockerrc` with
  `LockOnStart=false`, `Autolock=false` and `LockOnResume=false` for each
  owner account: pmOS's `/etc/xdg` default starts every Plasma login at the
  lock screen, and kscreenlocker then locks again after five idle minutes
  and on resume. The lock screen asks for the account password as a PIN
  (the keypad icon switches to a full keyboard). gdm autologin already
  decides who gets the session, and the GNOME session does not lock on its
  own, so Plasma matches that. Re-enable in Settings › Screen Locking.

The GNOME-only pieces — `dc1-safe-area`, `dc1-session-compat`,
`dc1-warmth`, the Mutter `kms-modifiers` setting and the gschema overrides —
do not apply under KWin. Bezel insets, the GPU/charging settings panels
(GTK apps; they still launch) and the OSK-on-greeter override have no Plasma
counterpart yet.

## Acceptance checks

Record results in this section as they are taken on hardware.

| Check | Result |
| --- | --- |
| Session starts from gdm autologin after `dc1-session --now plasma-mobile` | 2026-10-25: yes; kwin_wayland + plasmashell on seat0, first login landed on the lock screen (fixed above) |
| Touch, pen and auto-rotation (KWin via iio-sensor-proxy) | 2026-10-25: rotation applied by KWin (`Rotation: 2`, landscape geometry); owner reports the session works well; no per-input measurement yet |
| Scale (KWin auto-scale vs. the 1.5× GNOME default) | 2026-10-25: KWin picked 1.25× and the 120 Hz mode (`kscreen-doctor -o`); the port prefers 60 Hz, not yet changed |
| Plasma Keyboard appears for text fields; lock screen unlock by touch | 2026-10-25: Plasma Keyboard configured by envmanager (`InputMethod=org.kde.plasma.keyboard`), toggle in the nav bar; owner reports it works well |
| Wi-Fi, Bluetooth, audio from quick settings | pending |
| Waydroid container toggle and app cards in the task switcher | pending |
| `dc1-orientation` stopped (exit 3), no restart loop in `journalctl --user` | 2026-10-25: yes via the `org.kde.KWin` bus check; `ActiveState=inactive`, `NRestarts=0` |
| Return with `dc1-session --now gnome`; GNOME extensions and rotation recover | pending |
