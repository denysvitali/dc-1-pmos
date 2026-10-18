# Security and exposure — what listens where

Installed systems use authenticated login paths. Device package r109 removes
the old raw TCP/USB root-shell service and USB kernel-log streamer, including
their OpenRC and systemd enablement. Its upgrade helper stops the old service
and removes its shipped files, stale links and any `/dev/null` mask.

The current system initramfs source configures USB rescue only after a failed
boot. Older boot images still contain their earlier pre-handoff serial debug
channels until replaced; a userspace package upgrade cannot change a ramdisk.
Installer mode remains a separate physical recovery environment.

The table describes shipped defaults. Local SSH/Tailscale/firewall policy can
restrict them further. USB gadget configuration is measured device-side, but
host-side ECM/SSH reachability remains a pending end-to-end check.

## Exposure matrix — installed system

| Channel | Binds to | Authentication | Reachable via | How to close |
| --- | --- | --- | --- | --- |
| sshd, TCP 22 | `0.0.0.0` + `[::]` (all interfaces) | Password of the account created at install (sshd defaults; no `PermitRootLogin`/`PasswordAuthentication` overrides are shipped) | Wi-Fi; USB is configured device-side but host reachability remains unverified | `systemctl disable --now sshd`, or restrict with a `ListenAddress`/firewall |
| DNS `127.0.0.53`/`127.0.0.54:53`, LLMNR 5355 | loopback / all (LLMNR) | n/a (systemd-resolved) | LLMNR is link-local multicast | `LLMNR=no` in resolved.conf |

SSHD is enabled by installer provisioning (`apply_sshd`) so authenticated
access remains available if the desktop fails. Password quality and SSH
authentication policy must be configured for the intended deployment.

USB ACM functions may remain enumerated for compatibility with older gadget
trees, but no installed-system shell or log-stream service opens them.
Removing live configfs gadget objects can wedge this hardware; retirement
does not tear down or rebuild a bound USB gadget.

## Exposure matrix — installer mode (installation initramfs)

| Channel | Binds to | Authentication |
| --- | --- | --- |
| sshd, TCP 22 | `172.16.42.1` (usb0) only | root, **blank password** |
| Root shell, TCP 4444 | `172.16.42.1` only | none |
| Installer protocol, TCP 5555 | `172.16.42.1` only | **None**; stream size and SHA-256 are integrity checks, not authentication |
| sh on ttyGS1/ttyACM0/ttyS0/tty1 | USB serial / console | none |

Installer mode is a transient recovery environment on a USB link-local
address. The touch path joins Wi-Fi after credentials are given, but all
three TCP listeners remain bound to `172.16.42.1`, never a wildcard or the
wireless address. The installer daemon waits for that address before it
starts and closes a session after 60 seconds without socket progress. TCP
5555 is deliberately unauthenticated: anyone with physical USB data access
while installation mode is running can request an install and erase
`userdata`. The protocol verifies exact bytes and scrubs a failed image; it
does not identify the host. The installed system contains none of the
installer credentials.

## What is *not* exposed

- The installed kernel enables Landlock and the BPF LSM so desktop indexers
  and `systemd-nsresourced` can apply their intended local sandboxes. BPF JIT,
  perf, kprobe events, and ftrace are present as BPF-LSM dependencies, while
  unprivileged BPF defaults off. SysRq also defaults off until Alpine applies
  its restricted mask (`16`, emergency filesystem sync only).
- Kernel core-dump support is enabled for systemd's configured crash handler.
  Dumps can contain process memory and must be treated as private diagnostic
  data; none are included in build artifacts or release collection paths.
- Published artifacts contain no user-provided credentials: the build
  signs only its APK index, `PROVENANCE` records pins, and the installer
  provisions the real account and password on-device (hashed at rest
  from the first moment). The build-time placeholder account is not a
  user secret.
- No proprietary blobs ship; firmware is fetched from upstream
  linux-firmware/wireless-regdb at build time under size + SHA-256 pins.
- Charging mode excludes USB networking, its DHCP server, NetworkManager,
  wpa_supplicant and sshd. Press power to boot normally for authenticated
  access; no raw USB login channel is provided while charging.

## If you want a quieter device

```sh
# Close SSH only if another authenticated login path is available:
systemctl disable --now sshd
```

Re-enabling any of these later requires a working login path — do not
close every channel at once unless you are confident in the surviving
one.
