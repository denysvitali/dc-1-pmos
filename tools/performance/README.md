# DC-1 performance measurements

`gpu-frame.c` measures completion of eight alpha-blended, fullscreen quads
in a 1200×1600 RGBA offscreen framebuffer. It uses GLES2 and surfaceless EGL,
does not open a window, and does not change clocks, display settings, or power
management. Run as the desktop user with access to the render node.

Build with the installed C compiler and EGL/GLES development packages:

```sh
cc -O2 -Wall -Wextra -Werror -o /tmp/dc1-gpu-frame \
  tools/performance/gpu-frame.c $(pkg-config --cflags --libs egl glesv2)
/tmp/dc1-gpu-frame 120 0
/tmp/dc1-gpu-frame 120 20
/tmp/dc1-gpu-frame 60 100
```

Arguments are sample count (1–1000, default 60) and idle milliseconds between
samples (0–1000, default 100). Ten untimed frames warm the shader cache first.
Each sample clears the framebuffer, draws eight layers, and waits with
`glFinish()`. The clock includes CPU submission, scheduling, GPU wake and
rendering, and completion wait. A final pixel readback checks that drawing
actually happened. GL/EGL failures and invalid arguments fail the run.

Use all three modes: continuous rendering exercises sustained throughput;
20 ms gaps exercise intermittent work below the shipped 50 ms autosuspend
delay; 100 ms gaps give the GPU a chance to suspend. Other desktop activity
can keep it awake, so a gap alone does not prove a suspend/resume transition.
Check `renderer` for Mali/Panfrost: software-rendered results are not GPU
measurements. Compare the complete p50/p95/maximum results across repeated
runs, keeping desktop activity and thermals comparable. Run CPU loads and
builds separately from GPU measurements.

This is **not** a compositor, input-latency, presentation, display-liveness,
or FPS test. It does not model texture sampling, fractional scaling, damage,
rotation, or scanout. A fast result cannot prove a smooth desktop or lit glass.

## Frequency comparisons

Read the actual persisted choice before testing. Package updates preserve
it, even when it is below the current shipped default:

```sh
/usr/libexec/dc1-gpu-freq status
cat /var/lib/dc1/gpu-freq.conf
```

Use Settings → GPU or the existing polkit helper to select a preset:

```sh
pkexec /usr/libexec/dc1-gpu-freq set 812000000 1100000000
```

This command changes and **persists** the floor/ceiling. Record the old pair
and restore it with `set OLD_MIN OLD_MAX` when an experiment finishes unless
the new choice is intended to remain. Keep `dc1-gpu-freq` as the single writer.
A floor comparison with the same 1.1 GHz ceiling allows the governor to boost;
it is not a fixed-clock comparison. Thermal cooling remains in control.

For long-tail stalls, sample the GPU's
`/sys/devices/platform/soc/13000000.gpu/power/runtime_status` alongside the
probe process's `/proc/PID/wchan` (when permitted). A completion wait that
coincides with `resuming` is evidence to investigate runtime PM, not proof
of a particular faulty driver function. Keep tracing and power-domain changes
for a separately controlled hardware session.

## CPU and display context

Run `python3 tools/performance/timer-wake.py` before and after a kernel
timer change. It measures 100 actual sleeps each at requested 20, 200, and
1000 µs and reports median/p95/maximum latency, clock resolution, and the
process's timer slack. It does not change scheduling or timer slack. Expect
some slack and scheduler overhead; compare runs without concurrent builds.
The pre-r57 kernel lacked `CONFIG_HIGH_RES_TIMERS`, so all three requests
took approximately 4 ms. A nanosecond timestamp API alone does not establish
nanosecond wake precision. Kernel r57 enables high-resolution timers without
changing HZ=250, preemption, CPU/GPU clocks, or GPU autosuspend.

Read each `/sys/devices/system/cpu/cpufreq/policy*/` directory's
`scaling_governor`, `scaling_min_freq`, `scaling_max_freq`, and
`scaling_cur_freq`. Idle clocks alone do not show a performance limit;
verify that each cluster reaches its ceiling under a short load. Inspect the
compositor's CPU affinity and cgroup restrictions before changing scheduling.
`powerprofilesctl list` may report only a `placeholder` driver, so the GNOME
profile label alone is insufficient evidence of CPU tuning.

Read the compositor configuration without changing the display:

```sh
gsettings get org.gnome.mutter experimental-features
gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
  --object-path /org/gnome/Mutter/DisplayConfig \
  --method org.gnome.Mutter.DisplayConfig.GetCurrentState
```

The advertised refresh rate is not measured presentation cadence. Preserve
the [display invariants](../../docs/hw/display.md) and measure real frame
presentation separately before changing refresh, rotation, or compositor policy.
