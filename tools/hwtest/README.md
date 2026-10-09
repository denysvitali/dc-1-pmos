# DC-1 hardware tester

`hwtest` measures the **running tablet**, not the repository's support table.
It is a standalone Go tool using the standard library, with no package or
kernel deployment. Linux arm64 (the tablet) and amd64 are supported.

## Build and run

From the repository root:

```sh
go -C tools/hwtest build -o /tmp/dc1-hwtest .
/tmp/dc1-hwtest -list
/tmp/dc1-hwtest
/tmp/dc1-hwtest -only power,sensors
/tmp/dc1-hwtest -json > /tmp/dc1-hwtest-results.json
```

Run unprivileged first. Device permissions can cause `SKIP`; root is optional,
not required for the whole suite. Review a report before sharing it. Reports
omit network addresses, SSIDs, Bluetooth peers, serials, raw kernel messages,
and microphone samples, but still describe local hardware and system state.
Do not commit generated reports or captures.

Exit status: `0` means no `FAIL` results, **not hardware acceptance**; `1` means
one or more checks failed; `2` means invalid arguments/output error; `130`
means interruption. JSON is an array of `group`, `name`, `status`, and `detail`;
progress goes to stderr. `-only` and `-skip` accept comma-separated group names.

## What results establish

| Group | Default observations | Still not established |
| --- | --- | --- |
| platform | Model, matching module directory, CPUs/RAM, frequency policies, selected running Kconfig bits when exposed, log signature counts, failed units | Boot-image provenance, memory integrity, sustained CPU performance |
| thermal | Temperature plausibility and cooling-state readback | Calibration accuracy, effective thermal throttling, pack-temperature protection |
| display | DSI registration/mode/state, Panfrost registration/node access, GPU OPP readback, white/amber brightness and blanking settings | Lit glass, GPU rendering correctness, frame pacing, emitted light |
| input | Board input registration/capabilities and available read-only axis ioctls | Physical touch, pen, button, or hall events without operator action |
| sensors | Accelerometer gravity sample, mount matrix, ADC readability, bound I2C inventory | Desktop rotation, ADC calibration, ambient-light/proximity protocol |
| power | Gauge/charger consistency, Type-C/PD interfaces, RTC tick/skew, suspend plumbing, watchdog holder visibility | Charge-current safety, PD electrical compliance, suspend/resume, watchdog expiry recovery |
| wifi | Driver, link/address availability, counters | Throughput, RF reliability, Internet access without an explicit target |
| bluetooth | Controller transport/rfkill/HCI state when permitted | Discovery, pairing, audio, RF reliability |
| usb | UDC/gadget binding, ECM carrier, host-device enumeration | End-to-end data transfer, role-transition reliability, VBUS limits |
| storage | Root mount/space and block/MMC interfaces | Media integrity or filesystem durability from enumeration alone |
| audio | ALSA playback/capture interfaces and audio-service queries | Audible sound or intelligible microphone capture |

`PASS` applies **only to the named observation**. `INFO` is context; `SKIP`
means unavailable or deliberately untested, never a pass. `WARN` needs
investigation or additional context. `FAIL` can mean a violated expectation,
an invalid/unreadable required reading, or failed operator test—not necessarily
broken silicon. A kernel-log signature can describe a historical boot event.
A clock already at its maximum need not transition during the load test.

## Explicit optional tests

```sh
# Three-second bounded CPU load (thermal preflight/abort) and a <=1 MiB
# temporary root-filesystem round trip. Not a benchmark or endurance test.
/tmp/dc1-hwtest -only platform,storage -active

# Local terminal needed. Follow prompts for input events, five physical
# accelerometer poses, and connecting a PC for USB ECM carrier.
# Input grabs temporarily keep tested board input events away from GNOME.
sudo /tmp/dc1-hwtest -only input,sensors,usb -interactive

# One TCP connection to an endpoint you control/are authorized to test.
# Literal IP and numeric port only; no DNS, payload, fallback or public probe.
# Interface binding may need root; an inability to bind causes SKIP.
/tmp/dc1-hwtest -only wifi -network-target 192.0.2.10:443

# Explicit permission for up to two seconds of raw PCM in memory.
# Only signal statistics are reported; samples are neither saved nor played.
/tmp/dc1-hwtest -only audio -allow-microphone
```

`-allow-sound` requires `-interactive`; playback currently always skips because
there is no validated quiet route. It never changes mixers to make a probe
work. Microphone access can be denied/busy or yield silence if the current
route is not configured; the tool does not override its owner. The pose test
compares clear signed-axis dominance independently of magnitude calibration;
out-of-range magnitude is a warning, not proof that orientation sensing failed.

Touch counting starts only after a complete all-fingers-up frame. It counts
unique tracking IDs at completed frame boundaries, not transient slot updates.
An unchanged first slot can remain unknown after draining, so the reported
contact count is a conservative lower bound and may undercount. Pen-tip contact
requires pen-tool and contact states active together in a completed frame;
axis reach does not establish drawing alignment.

No mode automatically suspends, reboots, opens/pings the watchdog, writes
partitions, changes USB roles/gadget objects, modifies RTC alarms, sweeps
brightness, adjusts frequency limits, stops services, scans Bluetooth, or
probes unknown I2C protocols. The active storage test writes only a bounded
temporary regular file. Audio/network permission is separate from `-active`.

## Offline validation

```sh
sh scripts/check.sh go
go -C tools/hwtest test ./...
```

The shared Go check builds/vets/tests this module and cross-compiles Linux
arm64/amd64 binaries. Tests use synthetic trees, not live hardware. To inspect
a fixture manually:

```sh
/tmp/dc1-hwtest -root /path/to/fixture -only thermal -json
```

Relocated roots forbid commands, device opens/ioctls, networking, and all
optional stimulus flags. Read helpers reject symlink escapes. Fixtures are
trusted synthetic test data, not a sandbox for malicious trees (filesystem
races or special files are not supported). Static RTC fixtures do not prove
ticking. Offline tests and CI do not prove a hardware boot.
