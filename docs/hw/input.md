# Touch, pen, buttons, power key — measurement record

Deep-dive for the status-table rows *Touchscreen*, *Pen digitizer*, and
*Power key* in [docs/status.md](../status.md), plus the button map.
Newest facts last inside each section.

## Touchscreen

ILI2910, 10-point multitouch. ✅ Works; no open items.

## Buttons

Five physical controls: Power, Volume Up, Volume Down, plus custom keys
"Walkie-Talkie" and "Quick Action". Power + Vol-up via PMIC keys, Vol-down
via KPD matrix; the two custom keys are matrix positions (0,1)/(1,1) mapped
`KEY_F11`/`KEY_F12` verbatim from stock — mapping needs on-device
confirmation.

## Pen digitizer

Wacom EMR digitizer on i2c9 `0x09`, driven by the mainline **`wacom_i2c`**
driver — hardware-verified 2026-08-22, closed through calibration
2026-08-23, with one final hands-on alignment check pending an r38 boot
(see [../roadmap.md](../roadmap.md)). The road there had two wrong turns
worth recording. First root cause: no Wacom driver was compiled in at all
(`CONFIG_TOUCHSCREEN_WACOM_W9000` landed in `e2836cc1dcb4`, linux
pkgrel=29) — but live bring-up the same day proved *that driver family*
wrong: the part completely ignores `wacom_w9000`'s CMD_QUERY `0x2a`
handshake yet ACKs every plain read, streaming 19-byte frames whose layout
matches the older **`wacom_i2c.c`** exactly (flags in data[3], LE X@[4:5],
Y@[6:7], pressure@[8:9]). Kernel `4af6c7fef881` gives `wacom_i2c.c` an OF
match table, optional reset-GPIO/vdd power sequencing and a non-fatal
feature query with DT fallbacks; `3581ef5732a6` (both pinned at linux
pkgrel=30) swaps the compatible to `wacom,wacom-i2c`, sets
`CONFIG_TOUCHSCREEN_WACOM_I2C`, drops `output-low` from `wacom_pins`'
reset pin — which had been holding GPIO88, the active-low reset line, low
for the chip's entire life and silently defeating every earlier attempt —
and adds `touchscreen-max-pressure = <8191>`. Verified live on the running
pre-Wacom build by loading a test module: probe succeeded immediately from
cold-boot rail state, the feature query answered (X max 16008, Y max
21344, firmware byte 0x52 — bracketing a passive capture envelope of X
815..16008 / Y 14833..20868), and a 15 s drawing window produced 4489
input events including tip pressure up to 2849 and the barrel button
(`BTN_STYLUS`).

**Boot verification 2026-08-23 (linux r31):** the real driver binds from
cold boot (`wacom_i2c` at 9-0009, no out-of-tree taint, no "Feature query
failed" — sizes come from the controller), and a live evtest window proved
the whole kernel event path end to end: `BTN_TOOL_PEN` proximity through
17 approach/lift cycles, 50 `BTN_TOUCH` down/up pairs across strokes
spanning nearly the full coordinate envelope, pressure ramping to
3770/8191, the barrel button (`BTN_STYLUS`) and the eraser end
(`BTN_TOOL_RUBBER`) both reporting. One new blocker found before any
cursor could be watched: the driver leaves ABS_X/ABS_Y **resolution at
zero**, so libinput refuses the device outright ("missing tablet
capabilities: resolution. Ignoring this device.") and mutter/GNOME never
sees the pen regardless of the kernel working — evtest sees everything,
the desktop sees nothing. Fix pending in `wacom_i2c` probe (set axis
resolution); until then the compositor-level checks (cursor
alignment/orientation) are unreachable even though every kernel-side box
is ticked.

**Resolution fix shipped and verified 2026-08-23 (linux r32, kernel
`0adceb59`):** `wacom_i2c_probe` now reads `touchscreen-x-mm`/
`touchscreen-y-mm` from the board and sets ABS_X/ABS_Y resolution from the
final maxima (the `wacom_w9000.c` pattern), and the jagar digitizer node
supplies `160`×`213` mm — against the firmware envelope that lands on
exactly **100 units/mm per axis**. Deployed through the same OTA cycle
(slot a, first-try boot) and confirmed live: evtest shows Resolution 100
under both axes, and `libinput list-devices` reports
`Capabilities: tablet`, `Size: 160x213mm` — libinput accepts the device
into the default seat, so mutter/GNOME finally has the pen.

**Calibration closed 2026-08-23 (linux r33/r34/r35).** Three live
findings, each fixed in the driver or the board node and each re-verified
on this device against the r35 boot: (1) the reported coordinates were
rotated 180 degrees from what is rendered — a bottom-left stroke landed
top-right — fixed with `touchscreen-inverted-x`/`-y` (kernel `29a427af`,
r33); (2) the firmware holds `data[3]` bit 4 set on every in-proximity
frame, which userspace read as a permanently held `BTN_STYLUS2`, so every
stroke was a right-drag and GNOME Settings' test area drew nothing —
boards can now opt out via `wacom,no-barrel-switch2` and jagar does (same
commit; `evtest` now lists `BTN_STYLUS` only); (3) pressure saturates at
**4095**, not the 8191 the node declared, so libinput normalised a
full-press to ~0.5 and the pen felt uselessly light (kernel `94e6773e`,
r34; `ABS_PRESSURE Max 4095` live). Corner taps also measured the active
area running ~1.5-2 mm past the visible glass on every side. The first
attempt shipped that as a `LIBINPUT_CALIBRATION_MATRIX` udev rule in the
device package (r62) and it did **not** work: libinput stores the property
on tablet-class devices but never applies it to their reported coordinates
(back-solving captured coordinates through the matrix gave raw values
~14000x outside the sensor range). The rule was withdrawn in r63 and the
remap moved into `wacom_i2c` itself — optional
`wacom,visible-{x,y}-{min,max}` properties describing the visible-glass
envelope in hardware-frame coordinates, which the driver maps and clamps
onto before reporting (kernel `94e25870`, r35; jagar fitted by
outlier-rejected least squares over five correspondence taps to x
0..15707 / y 312..21344 of 16008x21344). Live on this device: driver
`wacom_i2c` bound at 9-0009, `libinput list-devices` shows
`Capabilities: tablet`, `Size: 160x213mm`, `Calibration: identity
matrix`, and the running DT carries all four visible-area properties.

**Edge misalignment root-caused 2026-08-25 (kernel `2afa5c09`, linux r38;
eraser/libwacom in device r74).** The human check failed — strokes still
landed offset — and the cause was found in code, not on glass:
`touchscreen_parse_properties()` latches `prop.max_x/max_y` while the DT
fallback `touchscreen-size-x/y` (16320x21120) is on the axes, and the
probe's firmware-outranks-DT override restores the real 16008x21344 on the
axes but never refreshed `prop`, so `touchscreen_report_pos()` reflected
the inverted axes around 16319/21119. Net: reported X spanned 311..16319
against a declared 0..16008 and Y spanned -225..21119 — a ~3 mm dead band
at one edge of each axis, the cursor never reaching the opposite edges,
and the glass center nearly aligned (which is why the error read as an
"edge" problem). The r35 window fit was captured through that skewed chain
and back-solved with the declared maxima, so its recorded "hardware frame"
sits offset by (-311, +225); r38 refreshes `prop.max_*` after the override
and shifts the jagar window into true frame: x 311..16018 / y 87..21119.
Compile-checked (W=1) and DTB-verified only — hardware verification needs
the r38 boot.

Separately, the eraser end: the kernel has delivered `BTN_TOOL_RUBBER`
since r31, but only Wayland tablet-v2 clients ever see tool types
(ordinary apps get pointer emulation, where both pen ends look identical),
and libwacom had no entry for `i2c:056a:0000`, so GNOME classified an
anonymous external tablet. Device r74 ships `daylight-dc1.tablet`
(IntegratedIn=Display, generic-with-eraser styli) — verified live:
`libwacom-list-local-devices` names "Daylight DC-1 Pen" with the General
Pen + Eraser styli after a driver rebind. Rnote and Xournal++
(tablet-v2 clients: pressure plus automatic eraser switching) are
installed on the device for verification.

**Eraser-as-pen root-caused 2026-08-26 (linux r41, kernel `050e66ab`;
compile-checked only, hands-on flip check pending).** In real use,
flipping the pen to the eraser end produced pen-tip strokes: `wacom_i2c`
chose `BTN_TOOL_PEN` vs `BTN_TOOL_RUBBER` only on the frame that entered
proximity and ignored every later ERASER/INVERT flag change, and this
firmware holds `IN_PROXIMITY` through a natural-speed flip. Raw evdev
captures looked healthy only because slow, deliberate test flips drop
proximity long enough for the entry latch to re-arm. The driver now
evaluates the tool bits every frame and, on a mid-proximity change,
releases the old tool bit before pressing the new one so userspace never
sees two tools at once.

**Calibration trap (found 2026-08-26).** GNOME Control Center's tablet
calibrator measures taps *through* the active mutter mapping, so one bad
calibration compounds on every retry: the device had accumulated a
degenerate `org.gnome.desktop.peripherals.tablets.056a:0000 area` (~0.2%
span, negative width/height) that made the whole glass map to a few
pixels. Reset with `dconf reset .../area`. With the kernel-side visible-
window remap delivering exact visible-glass geometry at identity
calibration, no userspace calibration should ever be needed here — do not
run the g-c-c calibrator on this device.

Wiring reference: measured i2c9 @11eb3000 addr `0x09`, IRQ GPIO9
level-low, reset GPIO88 active-low (driver-owned via `reset-gpios`), vdd =
WACOM-1V8 (GPIO150), 3V3 rail always-on.

## Power key

Phone-like sleep/wake toggle as of 2026-08-23: a short press locks the
screen shield and DPMS-offs the panel, the next short press wakes to the
lock screen, and a ≥2 s hold opens GNOME's power menu (restart / power
off). gnome-shell-mobile grabs the key as a mutter keybinding — so logind's
`HandlePowerKey=ignore` never applies — and its `powerManager.js` maps
`power-button-action='nothing'` onto `'blank'`; with `lock-enabled=true`
the blank action locks before fading out, the wake press cancels the
running action instead of starting a new one (no flap), and an untouched
lock screen re-darkens after a hardcoded 10 s. Suspend stays unreachable
by design (`CanSuspend=no`, s2idle aborts with unfreezable tasks). Shipped
via the gschema override in the device package; the event path
(mtk-pmic-keys → libinput) is proven by the working menu grab.

**Regression + fix 2026-08-24 (device r67):** the upstream upgrade to
gnome-session 999950.1 emptied the power menu — GNOME 50's gnome-session
changed `org.gnome.SessionManager.CanShutdown` from returning a boolean to
a uint32 availability enum, the 48-based shell's proxy rejects the `(u)`
reply (`returned type "(u)", but expected "(b)"`, reproduced with a gjs
proxy against the live bus), `_updateHaveShutdown` treats the error as
"unavailable", and Power Off *and* Restart both vanish (`_updatePowerOff`
gates the two together). The rest of the chain is version-compatible
(Shutdown/Reboot signatures unchanged; gnome-session 50 calls the shell's
EndSessionDialog with the same `(uuu ao)` Open and `Confirmed*` signal
names; logind availability reads back as 3 = available without
authentication), so the `dc1-session-compat@denv.it` extension in the
device package patches that one method with a signature-agnostic GDBus
call. Drop the extension when gnome-shell-mobile rebases onto GNOME ≥ 50.

**Logout trap found and fixed 2026-08-25 (device r68):** logging out to
activate the r67 fix stranded the device on the GDM greeter. Two causes
compound: GDM fires `AutomaticLogin=dc1` only once per gdm *daemon* start,
so a normal logout lands on a password prompt instead of re-autologin; and
the greeter had no on-screen keyboard on a tablet with no built-in one, so
that prompt could not be typed at all. The greeter's dconf profile
(`/usr/share/dconf/profile/gdm`) reads only the gdm user db and
`greeter-dconf-defaults`, neither of which carries a11y keys, so it falls
back to the *schema default* — which is what
`screen-keyboard-enabled=true` in the device package's gschema override
now sets (verified: `sudo -u gdm-greeter DCONF_PROFILE=gdm gsettings get`
reports `true`). Recovery from a stranded greeter, if it ever happens
again, is `systemctl restart gdm` from a root shell (restarting the daemon
re-arms autologin); this needs a channel the greeter itself cannot give
you, which is why the OSK default matters.
