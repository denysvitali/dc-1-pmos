# The GNOME stack on this image — shims, pins, and why

Deep-dive for the status-table row *Desktop / fresh install* in
[README.md](../README.md#hardware-support-at-a-glance). The desktop is GNOME Mobile (Wayland,
systemd) on the panel, hardware-accelerated via Panfrost. The stack is
currently held together by an explicit, minimal set of shims and pins;
this page is their inventory and removal conditions.

## GNOME fresh-install convergence history (2026-08-19)

A fresh install of this image could not start GNOME: the pmOS systemd
repository is mid-way through its GNOME 50 migration, so the image mixes
Alpine's gdm 48.0-r7 with pmOS's gnome-shell-mobile 999948.0-r4 and the
pmOS accountsservice fork. An on-device session established the exact
minimal fix set — GNOME up, clean reboot, zero failed units — and this
repository now codifies all six pieces. Their delivery through a fresh
published rootfs/install remains unverified.
(Update 2026-08-29: the migration midpoint described here has moved on —
a converged install runs the coherent GNOME-50 mobile set, gdm
999950.2-r0 with gnome-session 999950.1-r0, with all three dc1
extensions active. The "Device-local shims" section below is
consequently historical on this unit; a fresh-rootfs confirmation is
still the open check.)

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
4. **Accelerometer-driven orientation** (device package).
   Static GNOME and Sway 180° transforms were removed: they overrode the
   MC3416 orientation reported through `iio-sensor-proxy`. The device
   package now also installs `gnome-settings-daemon-mobile`, which
   supplies the desktop orientation consumer. A device polkit rule
   permits the active GNOME session to claim the accelerometer; without
   that, SensorProxy rejects the claim and reports orientation as
   `undefined`. The panel's physical scanout correction is supplied by
   the compositor's live sensor orientation, not a fixed monitor file.
   The device orientation bridge runs as a persistent user service and
   waits for SensorProxy and Mutter ownership during session startup instead
   of recording a failed unit before the compositor appears. It reacquires
   the Mutter proxy after a greeter/session compositor replacement, then
   honors GNOME's orientation-lock setting so the Auto Rotate quick-setting
   freezes the current transform without disabling the reliable sensor claim,
   and on unlock immediately applies the current physical orientation. It
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
6. **Modem-less base policy** (device package). The generic GNOME image still
   installs ModemManager and a WWAN NetworkManager policy, but the DC-1 has no
   cellular modem. ModemManager therefore stays dormant, avoiding activation
   of ABI-mismatched MediaTek plugins. An administrator attaching an external
   modem can opt in with `touch /var/lib/dc1/enable-modemmanager` followed by
   `systemctl start ModemManager`. The device's same-named NetworkManager
   override preserves the WWAN route-table policy while removing the one key
   unsupported by the installed NetworkManager.

The shims themselves are hardware-verified; their delivery through the
installer and the rootfs build has not yet been exercised end-to-end on a
device (tracked in [roadmap.md](roadmap.md) tier 2). Two known risks:

- the gdm greeter path (the `gdm` user's own Wayland session) was
  observed once aborting with "no session desktop files installed" during
  the older migration state. Logout → greeter OSK → login, including shell
  extension and orientation-bridge recovery, is still an explicit owed
  hardware session on the converged GNOME-50 stack (the greeter OSK default
  shipped in device r68 addresses the untypeable half; see
  [hw/input.md](hw/input.md));
- screen orientation after removing the static transforms still needs a
  physical tilt test on hardware (runbook in [roadmap.md](roadmap.md)).

## Former device-local shims on the development unit (not in the image)

Around the packaged set, the development device previously carried local shims
(restored 2026-08-19 after a day-long outage), the decisive one being the
libelogind redirect above: a 48-era gjs/mozjs/ICU shadow stack under
`/usr/local/lib` (edge's gjs 1.88 segfaults the 948 mobile shell), a
pinned gnome-session 48, a hand-supplied `org.gnome.Shell.target` user
unit, Wayland-only gdm (no Xorg exists to fall back to), a gdm drop-in
that waits for a DRM connector (gdm races mediatek-drm at boot; the
card0/card1 order flips between boots and mutter's builtin-panel
heuristic copes), and display-manager restart caps (a 1s-restart session
crash-loop once starved the whole machine). Those local shims came off when
the unit converged on the coherent GNOME-50 mobile set recorded above; the
mid-migration versions remain here only as failure-history context.

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
- **Charging profile panel (device r91, owner controls r92):**
  `dc1-charging-settings` is a libadwaita Preferences window in the Settings
  category. It keeps
  the negotiated PD ceiling separate from actual pack current, lists the
  source's fixed/PPS offers, shows the MT6375 input/CC/CV limits, and calls
  out a 5 V fallback with a reconnect instruction. It also selects the live
  2.00/3.15 A charge-current target and exposes authenticated switches for
  charging mode and automatic updates. Contract selection stays in kernel
  TCPM, which already chooses the highest-power compatible PDO.
  Details in [hw/power.md](hw/power.md).
- **120 Hz compositing (device r84):** the `1200x1600@120` mode's kernel
  vblank is 118.4 Hz with 0.31 ms of blanking, and KMS cannot rotate 90°,
  so landscape is an extra GPU blit. Window drag misses that deadline
  (mutter, not the CRTC; tiny-fast ~94 Hz, large-fast ~78 Hz). Schema
  default enables mutter `kms-modifiers` for tiled Panfrost intermediates.
  60 Hz stays preferred. Details in [hw/display.md](hw/display.md).
- **PDF scrolling (device r95):** Chromium's built-in PDF renderer can consume
  a full CPU core while scrolling on the DC-1. Chromium therefore downloads
  PDFs for the default native Papers viewer instead of rendering them in a web
  tab. This does not change the browser used for ordinary web pages.
