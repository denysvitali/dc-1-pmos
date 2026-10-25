# Waydroid on the DC-1

Waydroid runs Android apps inside the Linux desktop. The kernel recipe includes
its Binder, compatibility and networking requirements in
[`waydroid.config`](../pmaports/device/testing/linux-postmarketos-mediatek-mt6789/waydroid.config).
Android installation is opt-in; the system image does not install or start it.

**The tested Android image needs interpreter mode to avoid a system-server
crash.** Startup took about two minutes, and apps can be slow. GPU rendering,
Android web browsing and Brydge keyboard input worked on one DC-1 running Nura
edge; GNOME and Tailscale kept working.

## Kernel requirements

| Configuration | Purpose |
| --- | --- |
| Binder IPC and binderfs | Android IPC and Binder devices |
| Loop and overlay | Android image mounts and writable layers |
| Bridge, veth and nftables inet | Container networking and the packaged host firewall rules |
| ARM32 compatibility and legacy time syscalls | The ARM64 image also runs 32-bit vendor services |
| POSIX message queues | Container IPC support |
| IPv4/IPv6 policy routing | Android's per-network routing tables |
| Legacy xtables, matches and targets | Android netd filtering, NAT, marking and accounting |

The fragment records all explicit settings and their built-in/module values.
These were tested together, not minimized one option at a time. Binder is
built-in-only in this kernel; auxiliary drivers are modules. The package checks
that Kconfig preserves every requested value. Kernel C, device trees and the
pinned source revision are unchanged by this configuration addition.

If building a local kernel, follow [kernel development](kernel-development.md).
Keep matching kernel and modules APKs together and preserve a proven fallback
slot. The [original experiment](https://github.com/muness/alpine-desktop-apps/tree/13dd331/experiments/waydroid)
contains the separately tested timed-recovery procedure and manual rollback
helper. Those scripts and installer adjustments are not part of this repository.
Do not assume the ordinary kernel confirmation service waits for an Android test.

## Install Android

Use a Wayland desktop session. Install the native packages as root:

```sh
apk add waydroid waydroid-systemd waydroid-nftrules unzip
systemctl mask waydroid-container.service
```

The trial used Waydroid `1.6.3-r0` and these official Android 13 / Lineage 20
images:

| Image | Filename | SHA256 |
| --- | --- | --- |
| System | `lineage-20.0-20260927-VANILLA-waydroid_arm64-system.zip` | `5fb8179ed4455f45919c5a2bfbfdd1591619295994ad321217f03bb1dcfc53a7` |
| Vendor | `lineage-20.0-20261022-MAINLINE-waydroid_arm64-vendor.zip` | `89d5fb9a5c977adcc9fc7755483d3762c397b9c8579524f9d1df052b51c83fb3` |

Download from Waydroid's official [system image directory](https://sourceforge.net/projects/waydroid/files/images/system/lineage/waydroid_arm64/)
and [vendor image directory](https://sourceforge.net/projects/waydroid/files/images/vendor/waydroid_arm64/).
Check both hashes, then extract `system.img` and `vendor.img` into
`/usr/share/waydroid-extra/images`. Back up configuration and userdata before
replacing an existing Android installation.

Initialize as root:

```sh
waydroid init -s VANILLA
```

Check that initialization uses the preinstalled images. Add these entries to
the existing `[properties]` section in `/var/lib/waydroid/waydroid.cfg`:

```ini
dalvik.vm.extra-opts = -Xint
dalvik.vm.usejit = false
```

Both flags are required for the working interpreter configuration. Default ART
and JIT-off alone crashed `system_server`. [Waydroid issue #2040](https://github.com/waydroid/waydroid/issues/2040)
reports a related ARM64 Alpine crash; the cause is unresolved.

Make the config readable by the desktop user and regenerate it as root:

```sh
chmod 644 /var/lib/waydroid/waydroid.cfg
waydroid upgrade -o
```

Enable the packaged nftables include by linking
`/usr/share/nftables.avail/51_waydroid.nft` into `/etc/nftables.d/51_waydroid.nft`.
Validate with `nft -c -f` and load with `nft -f` if its rules are absent. Preserve
your existing firewall rules. Load the legacy table modules as root:

```sh
for module in iptable_filter iptable_nat iptable_mangle iptable_raw \
              ip6table_filter ip6table_nat ip6table_mangle ip6table_raw; do
    modprobe "$module"
done
systemctl unmask waydroid-container.service
systemctl start waydroid-container.service
```

As your desktop user:

```sh
waydroid show-full-ui
```

After checking Android, enable `waydroid-container.service` at boot. To keep the
Android user session on demand, create
`~/.config/autostart/waydroid-session.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Waydroid Session
Hidden=true
```

## Check the installation

As root, check `waydroid shell getprop sys.boot_completed` returns `1` and
`waydroid shell -- dumpsys SurfaceFlinger` reports the GPU renderer. The trial
reported Mali-G57 MC2 / Panfrost / Mesa 26.0.8. Open an HTTPS page inside Android,
test touch and typing, then check host browsing and any VPN.

Read command output: `waydroid shell` did not reliably return an Android command's
failure status to the host.

A mode `600` config prevented the desktop Binder helper from reading it. After
fixing permissions, restarting the Android session restored Brydge typing:

```sh
waydroid session stop
waydroid show-full-ui
```

To hide Android's screen keyboard while using hardware input, run as root:

```sh
waydroid shell -- settings put secure show_ime_with_hard_keyboard 0
```

Set it to `1` to restore the screen keyboard. Waydroid exposes a persistent
virtual hardware keyboard, so Bluetooth disconnection does not reliably switch
this preference back.

## Install apps

As your desktop user:

```sh
waydroid app install /path/to/application.apk
```

[Aurora Store](https://f-droid.org/packages/com.aurora.store/) and
[F-Droid](https://f-droid.org/) provide app stores. Aurora 4.8.4 and F-Droid 2.0.2
installed in the trial; Aurora reached sign-in. Downloads through the stores
were not tested. Aurora supports anonymous access to Google Play apps but does
not install Google Play services. GApps requires a separate setup.

## Test scope

On 2026-10-25, a local `7.2.0-rc5-waydroid4` kernel, packaged as
`7.2_rc5_git20260819-r71`, booted with this config fragment. It used the pinned
kernel source plus the existing recipe patches and original device trees.
It was not the upstream r68 APK produced by this change.

GPU rendering, Android DNS/HTTPS, host networking, Tailscale health, keyboard
typing and rollback to the original r67 kernel passed. The first kernel4 boot
fell back without a Linux journal; later boots succeeded. The cause is unknown.
Physical touch/gesture confirmation, audio, camera, suspend, DRM, Play Integrity
and long-term stability remain untested. Updates to the pinned Android images
are manual.
