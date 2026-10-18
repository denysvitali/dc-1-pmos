# GNOME desktop integration

The image runs GNOME Mobile on Wayland with systemd and Panfrost acceleration.
A working development session does not prove fresh installation or the
logout/login cycle; see [acceptance work](roadmap.md).

## Provisioning and package compatibility

The installer supplies a libelogind-to-libsystemd compatibility symlink and
musl search path through `apply_libelogind_shim`. Keep the redirect ahead of
the real libelogind when required by GDM. Remove it only after validating the
installed GDM's systemd session registration without it.

`apply_gdm_wayland_only` sets `WaylandEnable=true` and `XorgEnable=false`
while preserving autologin configuration. The image has no Xorg fallback.

The rootfs builder constrains `accountsservice<999` and
`libaccountsservice<999` in `/etc/apk/world` to avoid the postmarketOS fork's
library/typelib mismatch. Remove the constraints only after checking the
library soname, typelib, GDM and shell together.

ModemManager stays dormant because the tablet has no cellular modem. External
modem users can opt in with `/var/lib/dc1/enable-modemmanager`. The device's
NetworkManager override preserves WWAN routing policy while omitting an
unsupported key.

## Orientation and session lifecycle

The device package supplies `gnome-settings-daemon-mobile`, a SensorProxy
polkit rule and a persistent orientation bridge. The bridge:

- reacts to sensor, Mutter and orientation-lock notifications;
- reacquires Mutter after greeter/session replacement;
- coalesces updates and retries failures;
- honors rotation lock and applies the latest pose after unlocking;
- applies transforms only while the GNOME session is active and the display
  is awake, then catches up on activation/wake.

Keep that last gate: monitor reconfiguration while blanked can retain scanout
buffers and exhaust the shared CMA pool. Do not restore static GNOME/Sway
transforms that override sensor orientation. See [sensors](hw/sensors.md) for
mounting and physical-pose acceptance.

## Device controls and shell integration

| Component | Purpose / constraint |
| --- | --- |
| `dc1-safe-area` | Insets UI from the bezel and rounded corners; lifts the unlock sheet above the OSK by padding the parent of `_stack`, not the background actor. Physical lock-screen acceptance remains pending. |
| `dc1-session-compat` | Reads the shutdown capability through a signature-tolerant GDBus call. Recheck whether the installed shell/session pair still needs it before removal. |
| Greeter schema override | Enables the on-screen keyboard so logout does not require a physical keyboard. |
| GPU settings | Uses the helper/polkit path for min/max changes; periodic current-frequency reads run in a background worker. See [display](hw/display.md). |
| Charging Profile | Shows PD and charger state, selects charge current, and controls charging mode, automatic updates and opt-in automatic sleep. Contract selection remains in kernel TCPM. See [power](power.md). |
| Mutter `kms-modifiers` | Allows tiled Panfrost intermediates. 60 Hz remains preferred; landscape requires a GPU blit. |
| Native PDF viewer | Chromium downloads PDFs for Papers to avoid costly browser rendering. |

The 48.mobile.0 native `St.Button.get_pressed()` getter passes the button to
`clutter_press_gesture_get_pressed()` instead of its click gesture. It returns
false and emits a critical even for valid buttons. `dc1-session-compat`
routes both JavaScript method and property reads through the real click
gesture when that API is present, restoring the original descriptors when
disabled. GJS's optimized property access would otherwise call the same
broken native getter. This repairs pressed-state handling without changing
touch calibration, gesture thresholds or event delivery. Remove the workaround
when the mobile shell fixes its native getter.

Run `gjs -m scripts/tests/test_dc1_button_pressed.js` for the offline state
and cleanup checks. On the tablet,
`sh scripts/tests/test_dc1_button_pressed_native.sh` compares both access
paths against an actual Clutter click gesture in an isolated headless Mutter
context. It does not replace the owner compositor. On the affected build the
negative control emits two criticals; the patched reads emit none.

## Chromium positional writes

Chromium 155's component file-patcher sandbox traps `pwritev2`. musl 1.2.6
uses that syscall with `RWF_NOAPPEND` when applications call `pwrite()` or
`pwritev()`, so the sandbox terminates the process before musl can fall back.
The observed utility was `patch.mojom.FilePatcher`, not the browser process.

`/etc/chromium/dc1-pwrite.conf` preloads a small compatibility library only
for Chromium and its children. It uses the legacy positional-write syscalls
already supported by the sandbox, preserves cancellation points and refuses
`O_APPEND` descriptors with `EOPNOTSUPP`, matching musl's fallback rather than
silently writing at the wrong offset. Component updates and seccomp remain
enabled. Restart all Chromium processes to load it. Other applications use
the normal libc implementation. Remove the configuration and library after
the Chromium sandbox handles musl's new probe.

`python3 scripts/tests/test_chromium_pwrite.py` tests real writes while
seccomp traps `pwritev2`, including a fatal negative control, large offsets,
descriptor errors, append handling and thread cancellation. This establishes
syscall compatibility; a successful component-update transaction is a
separate runtime check. The upstream implementations are
[musl pwrite](https://git.musl-libc.org/cgit/musl/tree/src/unistd/pwrite.c) and
[Chromium's service policy](https://github.com/chromium/chromium/blob/155.0.8059.39/sandbox/policy/linux/bpf_service_policy_linux.cc).

## Chromium WebGPU

The device package installs `/etc/chromium/dc1-webgpu.conf`. Alpine's launcher
reads it after `chromium.conf`; it selects ANGLE GLES and Dawn's OpenGL ES
backend, and forces WebGPU compatibility mode for default adapter requests.
Quit all Chromium windows and reopen the browser after installing the update;
launching another window in an existing process does not apply new flags.

Mali-G57 has working Panfrost GLES 3.1 but no supported Mesa Vulkan driver.
Chromium's default Linux WebGPU backend therefore cannot provide an adapter.
Installing `mesa-vulkan-panfrost` or enabling Vulkan cannot fix that hardware
support gap. See Mesa's [GPU support table](https://docs.mesa3d.org/drivers/panfrost.html).

Compatibility mode runs shaders on the Mali GPU, but has fewer features and
limits than core WebGPU. Applications requiring `core-features-and-limits`,
`shader-f16` or other unavailable features can still fail. The configuration
does not enable Chromium's unsafe WebGPU switch or disable its sandbox flags.
Alpine's `CHROMIUM_USER_FLAGS` and explicit command-line arguments can override
these defaults. Google's Chrome binary is not installed on the Alpine tablet.

Verify execution with the [WebGPU check](../tools/performance/README.md#webgpu-execution-check),
and check `chrome://gpu` for Mali/Panfrost and enabled WebGPU. Adapter creation
alone is insufficient; the check validates compute and pixel readback.
See the [measured result](hw/display.md#chromium-webgpu-compatibility-mode).

## Acceptance

Verify a fresh published-rootfs install through provisioning, first login and
first update. Separately test logout to the Wayland greeter, OSK login,
extension recovery, rotation in all four poses, and lock-screen typing with
the keyboard visible. Use a working recovery channel before ending the owner
session. Record the tested artifact versions in [verification](verification.md).
