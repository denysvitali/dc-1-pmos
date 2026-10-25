# Waydroid on the DC-1

Run Android apps inside the DC-1's Linux desktop with Waydroid. Install it
separately using the steps below.

**The tested Android image crashes unless it uses interpreter mode.** Startup
took about two minutes; expect slower apps. The [test results](#test-results)
list what worked and what remains unchecked.

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

[`waydroid.config`](../pmaports/device/testing/linux-postmarketos-mediatek-mt6789/waydroid.config)
contains the exact settings. Binder is built in; auxiliary drivers are modules.
The package checks that Kconfig preserves those values. We tested the settings
as a set, without measuring which individual options could be removed.

For a local build, follow [kernel development](kernel-development.md). Keep the
kernel and matching modules APKs together and preserve a proven fallback slot.
The [original experiment](https://github.com/muness/alpine-desktop-apps/tree/13dd331/experiments/waydroid)
provides timed recovery and manual rollback scripts. They require its installer
adjustments. This repository's normal confirmation service confirms the kernel
before you test Android.

The kernel exposes its build configuration at `/proc/config.gz`, so the setup
app can check requirements directly.

## Install Android

The separate experimental [Waydroid Setup app](https://github.com/muness/alpine-desktop-apps/tree/main/experiments/waydroid#setup-app)
provides image selection, progress, a copyable diagnostic report and removal.
It requires the Waydroid-capable kernel to be installed and booted first.
The instructions below install **Vanilla Android without Google Play services**.
The app also offers GApps with Google Play. The owner has confirmed both images
work on the DC-1.

Use a Wayland desktop session. Install the native packages as root:

```sh
apk add waydroid waydroid-systemd waydroid-nftrules unzip
systemctl mask waydroid-container.service
```

We used Waydroid `1.6.3-r0` with these official Android 13 / Lineage 20 images:

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

Keep both flags: disabling JIT alone still crashed `system_server`. [Waydroid issue #2040](https://github.com/waydroid/waydroid/issues/2040)
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
`waydroid shell -- dumpsys SurfaceFlinger` reports the GPU renderer. Open an HTTPS page inside Android,
test touch and typing, then check host browsing and any VPN.

Read the output, not just the exit status: `waydroid shell` sometimes returned
success when the Android command failed.

If the Brydge does not type, check that `waydroid.cfg` has mode `644`, then
restart the session. This restored typing after a Binder helper permission error:

```sh
waydroid session stop
waydroid show-full-ui
```

To hide Android's screen keyboard, open **Android Settings → System →
Languages & input → Physical keyboard** and turn **Use on-screen keyboard**
off. Turn it back on to restore the screen keyboard. This is separate from
GNOME's screen keyboard.

For scripts, the equivalent command is (run as root):

```sh
waydroid shell -- settings put secure show_ime_with_hard_keyboard 0
```

Set it to `1` to restore the screen keyboard. Waydroid keeps its virtual
hardware keyboard present even when the Brydge disconnects.

## Install apps

As your desktop user:

```sh
waydroid app install /path/to/application.apk
```

[Aurora Store](https://f-droid.org/packages/com.aurora.store/) offers Google Play
apps, including anonymous access. [F-Droid](https://f-droid.org/) offers
open-source apps. Neither supplies Google Play services; install GApps
separately if your apps need them.

## Test results

Tested on one DC-1 running Nura edge on 2026-10-25, with local kernel
`7.2.0-rc5-waydroid4` / APK `7.2_rc5_git20260819-r71`. That build used this
fragment, the pinned source and existing patches, and the original device trees.
The upstream r68 APK still needs a hardware test.

| Check | Result |
| --- | --- |
| Config export (`7.2.0-rc5-waydroid5`, local r72) | Booted; `/proc/config.gz` matches the packaged config; setup check passes |
| Android boot and graphics | Passed; Mali-G57 MC2 / Panfrost / Mesa 26.0.8 |
| Android DNS and HTTPS | Passed |
| GNOME, host networking and Tailscale | Kept working |
| Brydge typing | Passed after the session restart above |
| Timed fallback and manual rollback | Restored the original r67 kernel and packages |
| Aurora 4.8.4 and F-Droid 2.0.2 | Installed; Aurora reached sign-in. Store downloads untested. |

Physical touch/gestures, audio, camera, suspend,
DRM, Play Integrity and long-term stability remain untested.

Update the pinned Android images manually; automatic image updates are not configured.
