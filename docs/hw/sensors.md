# Sensors

Deep-dive for the status-table row *Sensors* (accelerometer, hall switch,
ambient-light part, orientation chain) in [README.md](../../README.md#hardware-support-at-a-glance).

## Bus ownership

The sensor buses are reachable from the AP with their AP pinmux. The unused
SCP node is disabled so no sensorhub firmware can compete for the pins.

- GPIO142/143, AP i2c6 at `0x1101a000`, exposes the MCube MC3416 at
  `0x4c` (`mcube,mc3416`, `drivers/iio/accel/mc3230.c`).
- GPIO132/133, AP i2c1 at `0x11e01000`, exposes the MN29005-compatible
  ambient-light part at `0x49`, revision `0x1288`, through the native IIO driver.

Do not add an AP sensor node while also adding an SCP/sensorhub owner for
the same pins. There is still no gyro or magnetometer.

## Accelerometer and orientation

Device r97 changes `dc1-orientation` to an event-driven GLib main loop:
SensorProxy property changes, Mutter monitor changes/name replacement, and
GNOME's rotation-lock setting trigger updates. No steady-state poll remains;
only failed peer operations retry after one second. It reclaims the sensor
on SensorProxy restart and compares live display state on Mutter restart,
including when the sensor orientation itself has not changed. Nine offline
tests cover these paths, burst coalescing, lock/unlock, mode preservation,
and cleanup. On 2026-09-12 the live session's full-monitor queries dropped
from 20 per five seconds to zero while stationary; lock/unlock triggered
one query. This verifies event delivery and idle work removal, not the
still-owed physical tilt and logout/login tests below.

**Accelerometer works on the mainline tree** (verified 2026-08-19,
re-measured 2026-08-22): `iio:device0 name=mc3416` reads a clean 1 g
vector and `iio-sensor-proxy` reports `HasAccelerometer: true` with a
live orientation property.

**The hall switch is in the DTS** — kernel `3d3de59a5` (2026-08-18) added
it as vendor-compatible `hall-switch` backed by
`drivers/input/misc/hall-switch.c` (deliberately not gpio-keys),
interrupt `&pio 1 1`, `CONFIG_INPUT_HALL_SWITCH=y` — live today as
`input2`/event2, and one of the board's enabled wakeup sources.

The desktop chain ships complete: the SensorProxy D-Bus activation file
(device pkgrel=34, fixing Alpine's policy-only aport), the polkit claim
rule (pkgrel≥71: unconditional — the installer renames the provisioned
user and gdm's greeter runs as `gdm-greeter`, so a username match denied
both; sensor readings are world-readable in sysfs anyway),
gnome-settings-daemon-mobile, and the persistent `dc1-orientation` user
bridge (active on 2026-08-22; pkgrel≥71 enables it statically for every
user manager — including the gdm greeter, whose post-logout login screen
otherwise sat on the raw 180°-off scanout with tilt ignored — defaults
`undefined` orientation to the glass-upright transform, and re-drives a
respawned compositor by comparing against Mutter's live transform instead
of a cached one). The bridge honors GNOME's `orientation-lock` setting,
leaving the current transform untouched while locked and catching up to the
live sensor orientation when unlocked. One measured gap from that session:
mutter-mobile's orientation manager never claimed the sensor on the observed
boot, so rotation currently runs bridge-driven as an instant flip, and whether the
patched-Mutter animated transition ever engages is unknown — **the
physical tilt test has still never been performed** and remains the last
unverified link (runbook in [../roadmap.md](../roadmap.md)).

**2026-08-22 evening audit — tilt-test readiness all green on the running
build:** the sanity paths pass exactly as the runbook requires (`mc3416`
at the expected sysfs path, mount matrix exact-match and world-readable,
`HasAccelerometer=true` with live `AccelerometerOrientation`/
`AccelerometerTilt`, `dc1-orientation` bridge active since boot). Two
measurement caveats for whoever runs the tilt test: the driver-reported
`in_accel_scale` implies ~10 g for a resting 1 g vector, so judge poses
by sign/dominance, never magnitude; and `~/.config/monitors.xml` persists
`upside_down` while the live mutter transform is 90° — expected under
bridge-driven rotation, but remember it when interpreting results.
Systemic limitation worth fixing eventually: journals are root-owned and
the default user is not in `systemd-journal`, so nothing journal-based
(e.g. counting `ClaimAccelerometer`) is verifiable without root.

Mount matrix on record: `0, -1, 0; -1, 0, 0; 0, 0, -1`. Note the panel's
physical scanout is 180° from the glass; if a future DTS
`rotation = <180>` property is added, remove the same 180° compensation
from this mount-matrix in that change to avoid double rotation.

## Ambient light at i2c1 `0x49`

The `mn29005` IIO driver supports fixed-gain raw ambient-light counts for
revision `0x1288`. Its protocol source is the GPL driver published by
[OnePlusOSS at commit 48f1797695e24d46986a7c87dd91dd21cbf8c342](https://github.com/OnePlusOSS/android_kernel_oneplus_mt6893/tree/48f1797695e24d46986a7c87dd91dd21cbf8c342/drivers/misc/mediatek/sensor/2.0/mn29005).
The register-address read of `0x03` independently returned `0x88 0x12`
on the DC-1. The physical package marking has not been inspected; the
name identifies the matching public protocol. Firmware, Android libraries
and a sensorhub service are not runtime dependencies.

The kernel builds `CONFIG_MN29005=m` and adds `light-sensor@49` to the
existing AP i2c1 controller. The OF match table and exported module alias
let the normal udev coldplug path load the driver. No custom service,
debugfs check or userspace `new_device` write is needed for normal boot.

The node reuses `mediatek,mn29xxxals` from the public protocol driver; the
native driver's revision check narrows support to `0x1288`. AP pinctrl retains
GPIO132/133 and the unused SCP sensorhub node is explicitly disabled so it
cannot later compete for the sensor buses. The accelerometer's i2c6 setup is
unchanged. A full image with the updated DTB is required; a kernel-only update
preserves the old DTB and will not discover this sensor. Do not manually create
a second client when the DT node already owns address `0x49`.

The driver accepts only address `0x49`, revision `0x1288`, and an idle/off
baseline. It uses a fixed ALS preset from the public driver, bounds readiness
polling to 500 ms, serializes reads, and restores the captured control,
configuration and thresholds after each sample. Restoration includes register
readback. A failed restoration latches a fault and blocks further activation.
It does not enable the proximity emitter, claim an interrupt, expose buffered
samples or report lux, distance or threshold events.

Read raw counts by discovering the IIO device by name:

```sh
for device in /sys/bus/iio/devices/iio:device*; do
    [ "$(cat "$device/name")" = mn29005 ] || continue
    cat "$device/in_illuminance_raw"
done
```

To prevent automatic loading on subsequent boots, add `blacklist mn29005` to
an owner-managed file under `/etc/modprobe.d/`. With module unloading disabled,
already loaded code remains resident until reboot. A bound client can be
unbound through `/sys/bus/i2c/drivers/mn29005/unbind` after stopping sensor
readers. This does not delete the DT-owned client.
Do not use I2C `delete_device` for it. Remove the blacklist to opt back in.

Do not run `dc1-mn29-probe`, raw I2C tools or a second driver while the client
is bound. The legacy helper reads the current address only; its output is
not a light measurement. Earlier periodic byte sequences were a static
register window and are superseded by the combined register transactions.

### Evidence and remaining acceptance

The [kernel repository fault-injection harness](https://github.com/denysvitali/dc-1-linux-kernel/blob/d842efacd1751f0862b9306fa9fdc4a5e3461970/tools/testing/iio/test_mn29005.py)
executes the driver C with negative and short I2C transfers at 42 failure points.
It checks PM reference balance, identity and ownership refusals, readiness
flags, saturation, timeout, restoration
readback and fault latching. These tests do not simulate a physical stuck bus.
The compiled DTB and module aliases must agree on the sensor compatible,
and the DTB must retain AP pinctrl and a disabled SCP.

Native measurements on 2026-10-28 responded to owner-controlled lighting
with 10-sample medians of 3,152 and 552 counts; the ranges did not overlap.
The sensor is behind the display, so this establishes a light response,
not absolute lux or spectral accuracy.

Kernel/modules r82 (Linux 7.2.13 build #83) and device r120 completed a
guarded local boot on 2026-10-28. The module loaded from its DT node before
desktop discovery, SensorProxy reported an ambient sensor, and the owner
confirmed normal display and touch. Fifty reads completed without errors;
p95 latency was 43.862 ms and maximum latency was 44.888 ms. Every read
returned to runtime suspend, the accelerometer returned samples, and kernel
taint remained zero with no matching sensor/I2C faults in the boot log.

That test used the same driver source on a newer kernel than this repository's
current base, in a local continuity image preserving the previous boot DT
except for the sensor node and SCP status. It does not qualify the normal
published full-image DT. Published-image coldplug, real bus-error recovery,
suspend/resume with an agreed wake path, and electrical idle/active power
measurement remain open. Preserve the working fallback and coordinate codec
activity before these tests. Do not turn on general sleep policy to qualify
the sensor.

Calibration belongs above the raw channel. Neutral offset `0` and gain `1`
preserve counts; an adjusted value can use `max(0, raw - offset) * gain`.
Reference measurements through the display are needed before calling the
result lux. Automatic brightness needs separate policy qualification. Proximity requires
separate evidence for emitter wiring, safe drive settings and measurement
meaning before implementation.

### GNOME automatic brightness

GNOME Mobile 48 implements automatic brightness in
`org.gnome.Shell.SensorDaemon`, using `iio-sensor-proxy` and the
`org.gnome.settings-daemon.plugins.power ambient-enabled` setting. The
standard settings-daemon algorithm is not the implementation used here.
The Shell service uses a lux-to-nits curve; raw counts reported by SensorProxy
as lux are still uncalibrated and require separate calibration/policy work.

With iio-sensor-proxy 3.9, a sensor attached after login can leave GNOME with
cached `HasAmbientLight=false`: the proxy sends availability changes only to
clients that already claimed the sensor. A client that saw no sensor has no
reason to claim it. In the bounded live test, restarting the Shell sensor
service after attachment restored polling and changed the white frontlight
from 89 to 105, then the test restored 89. This proves the read/write path,
not the calibration or suitability of the curve for a reflective display.

DT/module coldplug passed on the local build #83 image described above.
The original Shell sensor-service process followed changing readings without
a restart: the white frontlight rose from 10 to 255, then fell to 193 as
readings dropped. Its log recorded the automatic adjustments. The test
restored white to 10, amber to 2, and automatic brightness to disabled; the
amber channel remained at 2 throughout.

Coldplug does not repair the proxy's late-attachment notification bug.
No GNOME or SensorProxy package patch is included in this driver change.
The reflective response and dual-frontlight behavior need separate
qualification. See [frontlight](display.md#frontlight).
