# Waydroid Manager

Optional GTK4 app for installing, opening and removing Android on the DC-1.
See the [user guide](../../docs/waydroid.md) for installation and recovery.
Kernel support is separate: [PR #14](https://github.com/denysvitali/dc-1-pmos/pull/14).

The installer adds the manager and its dependencies only. Android installation
requires an explicit action and polkit authentication. The backend handles
verified downloads, resumable transfers, interpreter settings and diagnostics.
The existing `dc1-waydroid-setup` command remains an alias for compatibility.
`waydroid.config` lists required kernel options; it does not build a kernel.

Run regression tests without changing the host:

```sh
python3 -m unittest discover -s tools/waydroid-manager/setup -v
```

The two download integration tests require `aria2c`; otherwise they skip.
