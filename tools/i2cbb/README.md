# `i2cbb` — bit-bang I²C over the GPIO character device

Probes an I²C bus whose AP controller is **not** enabled in the device tree,
by driving SCL/SDA directly through `/dev/gpiochipN` (uapi v2). Open-drain is
emulated the usual way: "high" releases the line to input and lets the pin's
own pull-up drive it, "low" drives it as output-0.

```sh
cc -Wall -Wextra -O2 -o i2cbb i2cbb.c
./i2cbb <chip> <scl-offset> <sda-offset> [addr]   # no addr -> scan 0x08..0x77
```

This is the tool that retracted the "the sensors are unreachable from the AP"
claim. Both SCP bus pin pairs are dual-function, so re-muxing them to their AP
function and bit-banging found, on 2026-08-16:

- **i2c6** (GPIO142/143, func 1 `SCL6/SDA6`) — mCube **MC3416 accelerometer at
  0x4c**, since given a real DT node and driven by `mc3230.c`.
- **i2c1** (GPIO132/133, func 1 `SCL1/SDA1`) — an ambient-light/proximity part
  at **0x49**, which still has no mainline driver and so stays undeclared.
  Re-probing that part is the reason this tool is kept.

Only safe while nothing drives the SCP — see the SCP/sensor invariant in
`CLAUDE.md` before pointing it at either bus.

`gpio_uapi.h` is Linux's `<linux/gpio.h>` uapi header (GPL-2.0 WITH
Linux-syscall-note), vendored with the `__u*` typedefs it needs to build
against a plain libc, exactly as `installer/src/uapi/` does for DRM.
