# Local compositor profiling and frontlight readiness

## Status and scope

**Profiling is not ready on the inspected DC-1.** `sysprof-cli` and the
Sysprof development dependency were not installed; availability/installability
in a newly prepared pmbootstrap chroot has not been verified. No profiler
Mutter APK has been built, installed or hardware-tested. Kernel work must finish
before a heavy Mutter build. This is opt-in local staging, not a production
configuration change: the production recipe retains `-Dprofiler=false`.

**Frontlight readiness remains blocked.** No trustworthy current-session
composed-desktop presentation signal is integrated with either service manager.
The existing three-second safety grace is retained unchanged. TE, DPMS, process
existence, OVL/vblank interrupts and kernel handoff logs do not prove that the
current desktop's first composed frame has been displayed.

## Pinned source findings

Line references are to the Mutter source the production recipe pins:
`mutter-mobile` commit `0aac77bdf278473d271813ad841555c06bc83e7b`
(`51.1.mobile.21`, package `999951.1.21-r0`), read from an archive matching
the SHA-512 in `pmaports/device/testing/mutter-mobile/APKBUILD`. Recheck them
whenever that pin moves. No buffering patch or backport was added.

* `meson.build:432–455` requires `sysprof-capture-4 >= 3.37.2` with profiling
  enabled. With pkg-config capture support it also requires `sysprof-6` or
  `sysprof-4`, whose `datadir/dbus-1/interfaces` supplies
  `org.gnome.Sysprof3.Profiler.xml` for `src/meson.build`. Capture headers alone
  are insufficient. The staged recipe adds Alpine `sysprof-dev` and disables
  Meson wrap fallbacks. Confirm these `.pc` files and XML inside the actual
  build chroot before calling dependency resolution successful.
* `clutter/clutter/clutter-frame-clock.c:1400` already implements dynamic
  triple buffering. `want_triple_buffering()` returns false when it is
  debug-disabled, when the frame clock is passive, when the previous
  presentation was zero-copy, or when the maximum-update estimate is below the
  refresh interval. Source presence is not evidence that a particular live
  workload uses triple buffering.
* `clutter/clutter/clutter-stage-view.c:174–236` allocates the intermediate
  offscreen with `cogl_offscreen_new_from_formats()` and swaps its dimensions
  for rotated views. That call takes pixel formats and a size, not a DRM
  modifier, so Mesa chooses the storage layout. Separately,
  `src/backends/native/meta-onscreen-native.c:2743–2863` selects GBM onscreen
  modifiers, constrains shareable surfaces to LINEAR, and falls back to
  `gbm_bo_create()` without modifiers. Thus `kms-modifiers` being enabled does
  **not** establish the modifier/layout of rotation intermediates or prove a
  performance improvement. Do not infer either tiled or linear intermediate
  storage from that setting alone.

## Isolated staging and later build

Run from the repository root as the ordinary build user. Choose a **new path
outside this repository**, on storage with room for a separate chroot/build.
The cached distfiles are read-only inputs; copies, not links, are staged.

```sh
python3 scripts/mutter-profile-stage.py \
  "$HOME/dc1-mutter-profile-01" /path/to/production/cache_distfiles
python3 scripts/mutter-profile-stage.py --check "$HOME/dc1-mutter-profile-01"
python3 scripts/test-mutter-profile-stage.py
sh -n scripts/mutter-profile-build.sh
```

Staging verifies all three recipe checksums before writing, preserves the
orientation patch, copies the pinned source manifest, and records hashes in
`PROFILE.json`. It refuses existing destinations and production recipes whose
expected markers have changed. The local revision is
`1000000 + production_pkgrel * 1000 + PROFILE_GENERATION`, currently
`999951.1.21-r1000002`. Increment the generation for a changed profiling recipe;
never reuse an APK filename with different bytes. This high revision is
**local only**: do not publish it or add its repository to an installed device.

The production recipe pins `gnome-settings-daemon-mobile` and its `-dev`
package to Mutter's own revision. Only Mutter gets the local revision, so
staging rewrites those two pins to the revision the settings-daemon recipe
really builds; otherwise the build could not resolve its dependencies.
`gnome-shell-mobile` in turn pins `mutter-mobile` to the production revision,
so a profiler Mutter cannot replace the production one beside the published
Shell. Any deployment has to resolve that pin first; none is designed here.

Only after the kernel build is finished, disk/memory/thermal headroom has been
rechecked and interactive build privileges/network access are arranged:

```sh
sh scripts/mutter-profile-build.sh --build "$HOME/dc1-mutter-profile-01"
```

The wrapper claims a new `STAGE/build` directory, invokes the project's
`build-rootfs.sh --validate-only` preparation path, and replaces only its private
`pmaports/extra-repos/systemd/mutter-mobile` copy. Its config, APK/compiler
caches, chroot, signing key and package output are private to that stage. It
uses the project's key restoration helper and pinned pmbootstrap
`build --arch=aarch64 --lax mutter-mobile`. It never builds a rootfs, installs,
shuts down another chroot, restarts GNOME or deploys. Do not run `prepare.sh`
again on the profile stage: it would restore the production overlay. A failed
build leaves its directory for diagnosis; this one-shot wrapper refuses reuse.

The source inputs are pinned and checksummed; Alpine/pmOS build dependencies
still resolve through the project's configured mirrors. This is not a claim
of byte-reproducible dependency resolution across different dates. After a
successful build, retain resolved package versions and Meson logs locally;
verify `Profiler: true`, the resolved Sysprof dependencies, the generated
`HAVE_PROFILER` setting and APK metadata/debug subpackage before scheduling a
separate deployment session. No install command is provided here.

Focused tests are deliberately standalone: neither shared `scripts/verify.sh`
nor installer tests are modified by this local-only tooling change. Run the
explicit test command above; production CI inclusion is not claimed.

## Conditional bounded capture runbook

These commands are **not ready to run on the current production compositor**.
They apply only after a separately coordinated profiler-enabled deployment,
a matching installed CLI, verified session-bus profiler endpoint and an
approved capture session. Run as the desktop user, never root. Check
`sysprof-cli --version` and `sysprof-cli --help` first.

CLI semantics were checked in upstream Sysprof 48.0,
commit `392c6e96879a99ef996fc4e6f7bcc6a8034e4776`,
[`src/sysprof-cli/sysprof-cli.c`](https://github.com/GNOME/sysprof/blob/392c6e96879a99ef996fc4e6f7bcc6a8034e4776/src/sysprof-cli/sysprof-cli.c):
`--gnome-shell` connects to session name `org.gnome.Shell`, object
`/org/gnome/Sysprof3/Profiler`; the capture filename is positional; SIGINT asks
for asynchronous stop/flush. There is **no `--duration` option** in that version.
The inspected DC-1's BusyBox `timeout --help` supports `-s SIG`, `-k KILL_SECS`
and seconds as the first positional argument. Recheck both tools after updates.

After those prerequisites, a bounded 20-second attempt with five seconds for
cleanup is:

```sh
umask 077
capture_dir=$(mktemp -d "$HOME/dc1-sysprof.XXXXXX")
timeout -s INT -k 5 20 sysprof-cli --gnome-shell --no-perf --no-decode \
  --no-network --no-disk "$capture_dir/drag.syscap"
```

This is a maximum recording attempt, not a guarantee of 20 seconds of valid
samples: startup/authorization consume time. The timeout may report a nonzero
exit even after an orderly stop; check diagnostics and open the capture to
confirm Mutter marks. A kill/partial file is a failed capture, not a benchmark.
Do not use persistent Mutter tracing, which rejects D-Bus Stop. Do not use
`--power-profile` or deprecated `--no-throttle`: those change the test conditions.

Even with the above switches Sysprof may include process metadata, system logs,
paths, window-related annotations and graphics diagnostics. Use a cleared test
desktop with no sensitive documents, notifications or credentials. Keep captures
and logs local with private permissions; never commit or publish them.

Compare repeated bounded captures of an empty desktop, tiny-window drag,
large-window drag and an overview transition. Match orientation, scale,
refresh rate, GPU preset, kernel, applications, thermals and power source; record
those conditions separately. First compare tracing disabled/enabled overhead.
Then inspect frame-clock scheduling, redraw damage, CPU work and presentation
interval p50/p95/maximum/missed deadlines. Keep continuous and idle-gap GPU
probes separate as described in `tools/performance/README.md`. No concurrent
kernel/Mutter build and no FPS or end-to-end latency claim from offscreen GPU
throughput or advertised refresh alone.

## Frontlight readiness design and blocker

The systemd unit requires/starts after `dc1-display-gate.service` and orders
after `gdm.service`; its helper waits for `gnome-shell`. The OpenRC service
needs `dc1-display-gate`, orders after `tinydm`, and backgrounds its wait for
`sway`. Both bound process polling and then sleep three seconds before writing
brightness 10 to `lcd-backlight`. Ordering after a display manager does not prove
presentation. Consolidation was not performed: there is no verified readiness
signal to integrate, and foreground systemd versus background OpenRC plus
GNOME versus sway semantics must remain distinct.

Pinned Mutter `MetaWindowActor::first-frame` explicitly allows initially
hidden/obscured/different-workspace windows to trigger the signal. It is not a
visible desktop gate. `ClutterStage::presented` is an internal signal annotated
`(skip)` for introspection, emitted by `clutter_stage_view_notify_presented()`;
this source inspection does not establish a GNOME JS or systemd readiness API.
Even a backend presentation event requires validation of its output, flags,
frame counter and current-session ownership before it can drive frontlight.

A future integration needs a compositor-side bridge for the intended physical
output, tied to the current boot and session (including GDM/user-session
transitions), with monotonic event identity and stale-event rejection. It must
consume confirmed presentation of that session's composed stage, not an
arbitrary application's first frame, DPMS or a synthetic/headless completion.
A bounded wait must retain the present fallback/grace if the bridge is absent,
times out, crashes or changes session. GNOME and sway need separately verified
adapters and fake-clock/event tests for stale records, wrong output, duplicate
events, timeout and session replacement. Physical first-frame validation is a
separately coordinated hardware session. No GPIO/DCS probe was performed or is
prescribed by this change, and no boot-time speedup is claimed.
