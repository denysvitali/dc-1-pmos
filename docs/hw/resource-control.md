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
See the [kernel guide](../kernel-development.md) for installation and rollback,
and the [Linux cgroup documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
for controller semantics.
