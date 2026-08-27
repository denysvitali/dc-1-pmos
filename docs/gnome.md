# The GNOME stack on this image — shims, pins, and why

Deep-dive for the status-table row *On-device UI* in
[status.md](status.md). The desktop is GNOME Mobile (Wayland,
systemd) on the panel, hardware-accelerated via Panfrost. The stack is
currently held together by an explicit, minimal set of shims and pins;
this page is their inventory and removal conditions.

## GNOME on fresh installs: the verified-minimal shim set (2026-08-19)

A fresh install of this image could not start GNOME: the pmOS systemd
repository is mid-way through its GNOME 50 migration, so the image mixes
Alpine's gdm 48.0-r7 with pmOS's gnome-shell-mobile 999948.0-r4 and the
pmOS accountsservice fork. An on-device session established the exact
minimal fix set — GNOME up, clean reboot, zero failed units — and this
repository now codifies all five pieces so every fresh install gets them:

1. **libelogind → libsystemd shim** (installer provisioning,
   `apply_libelogind_shim`). Alpine's gdm links `libelogind.so.0`, and
   real elogind 255.24's session parser fails on systemd cgroups — gdm
   logs "Session never registered" and no session ever reaches the
   display. `/usr/local/lib/libelogind.so.0` is a symlink to
   `/lib/libsystemd.so.0`.
2. **musl loader path** (same function).
   `/etc/ld-musl-aarch64.path` lists `/usr/local/lib` before `/lib` and
   `/usr/lib`; without it the dynamic linker's default search order
   finds the real libelogind first and the shim never wins.
3. **Wayland-only gdm** (installer provisioning, `apply_gdm_wayland_only`).
   `WaylandEnable=true` + `XorgEnable=false` in `/etc/gdm/custom.conf`,
   with the packaged autologin block preserved. Otherwise any session
   failure falls back to an X11 greeter on an image that ships no Xorg
   and no X11 session files — SIGABRT until start-limit-hit.
4. **Accelerometer-driven orientation** (device package, pkgrel 56).
   Static GNOME and Sway 180° transforms were removed: they overrode the
   MC3416 orientation reported through `iio-sensor-proxy`. The device
   package now also installs `gnome-settings-daemon-mobile`, which
   supplies the desktop orientation consumer. A device polkit rule
   permits the active GNOME session to claim the accelerometer; without
   that, SensorProxy rejects the claim and reports orientation as
   `undefined`. The panel's physical scanout correction is supplied by
   the compositor's live sensor orientation, not a fixed monitor file.
   The device orientation bridge runs as a persistent user service and
   requests the compositor-owned rotation transition from the patched
   Mutter-Mobile package, avoiding a visible hard snap during rotation.
   See [hw/sensors.md](hw/sensors.md) for the sensor side.
5. **accountsservice pin** (rootfs build, `scripts/build-rootfs.sh`). The
   pmOS fork `accountsservice-999923.13.9` ships a typelib referencing
   `libaccountsservice.so.0` while the installed gdm/gnome-shell link
   `.so.1`, so the shell's JS init throws. The build writes
   `accountsservice<999` + `libaccountsservice<999` into `/etc/apk/world`,
   which selects Alpine edge (26.27.3, the hardware-verified version) and
   — because world constraints are sticky — survives on-device
   `apk upgrade`. Temporary until the fork's typelib matches its library
   soname.

The shims themselves are hardware-verified; their delivery through the
installer and the rootfs build has not yet been exercised end-to-end on a
device (tracked in [roadmap.md](roadmap.md) tier 2). Two known risks:

- the gdm greeter path (the `gdm` user's own Wayland session) was
  observed once aborting with "no session desktop files installed" —
  after a user rename or a logout the greeter may still be broken even
  with the set above applied (the greeter OSK default shipped in device
  r68 addresses the untypeable half; see [hw/input.md](hw/input.md));
- screen orientation after removing the static transforms still needs a
  physical tilt test on hardware (runbook in [roadmap.md](roadmap.md)).

## Device-local shims on the development unit (not in the image)

Around the packaged set, the development device carries local shims
(restored 2026-08-19 after a day-long outage), the decisive one being the
libelogind redirect above: a 48-era gjs/mozjs/ICU shadow stack under
`/usr/local/lib` (edge's gjs 1.88 segfaults the 948 mobile shell), a
pinned gnome-session 48, a hand-supplied `org.gnome.Shell.target` user
unit, Wayland-only gdm (no Xorg exists to fall back to), a gdm drop-in
that waits for a DRM connector (gdm races mediatek-drm at boot; the
card0/card1 order flips between boots and mutter's builtin-panel
heuristic copes), and display-manager restart caps (a 1s-restart session
crash-loop once starved the whole machine). All of it comes off once
pmOS's systemd repo ships a coherent GNOME-50 mobile set (mid-migration
as of 2026-08-19: session 999950 + shell 999948 + an uninstallable gdm
999950).

## Version-skew fixes shipped in the device package

- **Power menu regression (device r67, 2026-08-24):** gnome-session
  999950.1 changed `CanShutdown` from boolean to a uint32 enum and the
  48-based shell's proxy rejects the reply, emptying the power menu. The
  `dc1-session-compat@denv.it` extension patches that one method with a
  signature-agnostic GDBus call. Drop when gnome-shell-mobile rebases
  onto GNOME ≥ 50. Details in [hw/input.md](hw/input.md).
- **Greeter OSK (device r68, 2026-08-25):** `screen-keyboard-enabled=true`
  via the gschema override so a post-logout greeter password prompt is
  typeable on a tablet with no physical keyboard. Details in
  [hw/input.md](hw/input.md).
- **GPU frequency panel (device r82, default r83):** `dc1-gpu-settings`
  is a libadwaita Preferences window in the Settings category so the
  Mali-G57 min/max floor can be changed without sysfs. Default Super
  smooth = 812 MHz; 700 MHz remains a Smooth preset. The helper persists
  `/var/lib/dc1/gpu-freq.conf`. Details in
  [hw/display.md](hw/display.md).
- **120 Hz compositing (device r84):** the `1200x1600@120` mode's kernel
  vblank is 118.4 Hz with 0.31 ms of blanking, and KMS cannot rotate 90°,
  so landscape is an extra GPU blit. Window drag misses that deadline
  (mutter, not the CRTC; tiny-fast ~94 Hz, large-fast ~78 Hz). Schema
  default enables mutter `kms-modifiers` for tiled Panfrost intermediates.
  60 Hz stays preferred. Details in [hw/display.md](hw/display.md).
