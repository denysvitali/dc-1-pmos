# Service resource controls

Kernel package r66 adds built-in CPU, I/O and PID cgroup controllers through
`resource-control.config`. The kernel recipe checks every required value
after Kconfig resolution and before packaging the resolved configuration.
The source pin, device tree, initramfs and suspend policy are unchanged.

The previous r65 kernel exposed only the memory controller. Consequently,
systemd could record `CPUWeight` and `TasksMax` settings without enforcing
them, and logged missing `pids.max` files. The new fragment enables CPU
weights and bandwidth control, block-I/O throttling and process limits.
It does not configure a particular service's limits or enable a weighted
I/O scheduler.

After booting the new kernel, check:

```sh
cat /sys/fs/cgroup/cgroup.controllers
cat /sys/fs/cgroup/system.slice/cgroup.controllers
systemctl show dc1-update.service -p CPUWeight -p Nice -p TasksMax
```

The root controller list must include `cpu io memory pids`. Verify actual
`cpu.weight`, `cpu.max`, `io.max` and `pids.max` values in a bounded test
service before claiming live enforcement. A resolved configuration or a
successful package build alone does not establish that the new kernel booted.

`python3 scripts/tests/test_resource_control_live.py` checks controller
availability without changing policy. After boot, run it as root with
`--execute --device /dev/sdc57` on the DC-1 to create a disposable service.
The service checks CPU weight/quota, memory and I/O limits, then proves the
task limit by observing `fork()` return `EAGAIN` in a bounded loop. It has a
20-second runtime limit and cleans up its children. Exit 77 means required
controllers are unavailable, not a successful enforcement test. This checks
configured I/O limits; it does not measure disk throughput under contention.

See the [kernel guide](../kernel-development.md) for installation and rollback,
and the [Linux cgroup documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
for controller semantics.
