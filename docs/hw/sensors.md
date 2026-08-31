# Sensors — measurement record

Deep-dive for the status-table row *Sensors* (accelerometer, hall switch,
ambient-light part, orientation chain) in [README.md](../../README.md#hardware-support-at-a-glance).
Newest facts last.

## Bus ownership

The sensor buses are SCP-connected but reachable from the AP when the
pins are re-muxed; the SCP node is enabled with only its mailbox driver
bound and the core stays halted (wake requests time out), so no firmware
owns the pins:

- GPIO142/143, AP i2c6 at `0x1101a000`, exposes the MCube MC3416 at
  `0x4c` (`mcube,mc3416`, `drivers/iio/accel/mc3230.c`).
- GPIO132/133, AP i2c1 at `0x11e01000`, exposes an ambient-light/
  proximity part at `0x49`. The bus is now claimed by the AP for controlled
  bring-up, but the sensor itself remains deliberately unbound.

Do not add an AP sensor node while also adding an SCP/sensorhub owner for
the same pins. There is still no gyro or magnetometer.

## Accelerometer and orientation

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

## Ambient-light / proximity part at i2c1 `0x49`

**Identification documented 2026-08-22; protocol still unknown:** the part
is pinned only to family level — the board-specific tinysys SCP sensorhub
firmware read from this device's own UFS names its sole ALS/PS driver
family `mn29xxx` beside standalone `memsic` (MEMSic) strings, which also
positively exclude stk/tmd/apds/ltr/epl candidates. A same-day live probe
(bit-banged through `/dev/gpiochip0` with nothing driving the SCP) found
exactly one ACKing device at `0x49`, but it NAKs every write-data byte
and returns constant bytes — no register protocol reachable, hence no
ID-register read, hence no exact part number and no basis for a driver
candidate; the kernel tree carries no driver for any MN29 part. Caveat:
the probe ran before any SCP initialization, so AP-side behaviour may
differ once that domain runs — do not conclude the part is broken from AP
probes alone.

**2026-08-28 AP path verified:** the shipped DT enables AP i2c1 and
muxes GPIO132/133 to SCL1/SDA1, using the same measured AP-bus-ownership
approach as i2c6. The sensor has no child node or compatible: an exact MN29
part identity and register protocol are still missing, and a guessed binding
could change its mode without any safe way back. The device package ships
root-only `dc1-mn29-probe` (`sudo dc1-mn29-probe`), which checks only the
address ACK on `/dev/i2c-1`; it never writes a byte. The original r81/r85
helper used a zero-length message with a null buffer, which `i2c-mt65xx`
rejects locally with `-EINVAL`; its `no ACK` result on the first r50 boot was
therefore not a bus measurement. The corrected r86 helper performs a one-byte
read and reports the actual ioctl error. Built directly from the r86
source and run on that same boot, it returned `ACK at i2c1 0x49 (read 0x00)`.
A repeat returned `0x27`; the byte is whatever the sensor's current internal
pointer exposes and has no protocol meaning yet. The ACK closes
controller/pinmux reachability without writing or changing sensor state. It
does not provide ambient light or proximity readings; protocol identification
and a real driver remain open.

The mainboard carries a connector explicitly labelled Light Sensor
(Daylight publishes nothing about sensors).

**2026-08-31 source audit and read-only measurement:** the [public MT8781 vendor
kernel](https://gitlab.com/ubports/porting/reference-device-ports/halium13/volla-tablet/android_kernel_volla_mt8781)
contains the Linux-side MediaTek sensorhub transport and represents
light/proximity as single-value sensorhub events, but it contains no
`mn29xxx` physical driver or register definitions. That driver is compiled
into the closed SCP firmware, so the vendor kernel cannot establish a direct
AP-I2C register map. [MEMSIC's public datasheet
catalogue](https://www.memsic.com/datasheets) likewise has no MN29 part. The
direct-I2C path therefore remains unidentified.

Device package r94 extends `dc1-mn29-probe` with bounded read-only sampling:

```sh
sudo dc1-mn29-probe --samples 100 --interval-ms 100
```

The helper still performs only current-address reads: it sends no register
address and writes no data byte. On the live device, 1,024 back-to-back reads
were exactly periodic every 256 bytes (zero mismatches across three complete
comparisons). A second 256-byte pass sampled at 100 ms intervals matched the
first byte-for-byte, so the sequence remained fixed for 25.5 seconds. The
current-address operation is therefore walking a static 256-byte register or
configuration window; it is not returning a live light sample. This rules out
a truthful read-only IIO prototype from the present evidence. The exact part
and SCP register protocol remain mandatory before binding a child node or
issuing a register-address write.
