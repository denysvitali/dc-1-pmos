# installer/ — the DC-1 installation-mode and system-boot initramfs

Two secret-free images built by `build.sh` (no SSH keys, no credentials,
nothing secret-shaped — the tripwire in `build.sh` enforces it):

- **installer** (`installer-boot.img`) — installation mode: the on-device
  touch installer (Wi-Fi + rootfs download), plus USB gadget networking and
  the USB installer daemon as fallback. Flashed *temporarily* to `boot_a`.
- **system** (`jagar-boot.img`) — the real boot image: its initramfs finds
  and verifies the installed `jagar-root` filesystem and `switch_root`s into
  postmarketOS. The stock pmOS initramfs cannot be assumed to work on this
  LK boot chain (v4 image shape, label-based root, LK watchdog), which is
  why this one exists.

## End-user flow (on-device, primary)

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot   # installation mode
```

Everything else happens on the device's own display and touchscreen
(`src/tui.sh` driving `gotools/internal/ask` screens): pick a Wi-Fi
network from the scan, enter the passphrase / username / password /
hostname / timezone on the touch keyboard, and `src/netinstall.sh` downloads
`jagar-rootfs.ext4.zst` + `SHA256SUMS` + `jagar-boot.img` from the rolling
release over verified TLS, feeds the shared write core, provisions, writes
the verified boot image to `boot_a` and reboots into the installed system.
The password is hashed on-device (busybox `cryptpw`, sha512crypt);
credentials only ever exist in shell variables and mode-0600 tmpfs files,
and supplicant/DHCP logs stay in 0600 files under `/tmp/wifi` — never on
kmsg (which is streamed over USB).

### USB flow (fallback)

```sh
./host/dc1-install.sh --rootfs jagar-rootfs.ext4.zst --boot-image jagar-boot.img
```

`dc1-install.sh` asks for username, password, hostname, timezone, and
optional Wi-Fi credentials; hashes the password locally; streams the raw
ext4 image with its SHA-256 over the USB gadget network (CDC-ECM, device
172.16.42.1 / host 172.16.42.2); and, after the device reports success and
reboots into LK fastboot, flashes the real boot image over the installer.
The USB daemon runs even while the touch UI is up (a lock in
`src/writelib.sh` keeps the two transports from writing concurrently), so a
host can always take over a device in installation mode.

Tethered `fastboot boot <img>` (no flash) is **unverified** on this LK, which
is why the installer is flashed and later replaced.

## Device side, fail-closed by construction

`src/writelib.sh` is the single write/verify core; both transports
(`src/receive.sh` on TCP 5555 and `src/netinstall.sh`) go through it:

- target resolved **by GPT partition name** (`PARTNAME=userdata` in sysfs),
  required unique and ≥ 32 GiB — never a hardcoded `/dev/sdX`, and the
  `preloader`/`lk`/`dtbo`/`vendor_boot` partitions are untouchable by
  construction;
- the image's first MiB (the ext4 superblock) is held back and written
  **last**, only after the transport's verification predicate passed (USB:
  SHA-256 of the raw stream against the host header; network: SHA-256 of
  the complete downloaded `.zst` against the release `SHA256SUMS`, verified
  **before** the first byte is decompressed onto disk, plus a clean zstd
  exit), so an aborted transfer can never leave a mountable `jagar-root`
  filesystem;
- a failed device write (`dd`) is fatal and scrubs; the written filesystem
  must be ext4 labelled `jagar-root` (the label the boot initramfs mounts
  by) before it is mounted;
- online `resize2fs` to the full partition (non-fatal, loudly reported);
- `src/provision.sh` applies the answers as pure file edits (user rename or
  creation with uid/group preservation, shadow hash, hostname, timezone,
  Wi-Fi as NetworkManager keyfile / wpa_supplicant.conf / parked file,
  depending on what the rootfs carries — the shipped rootfs is built with
  `ui=console`, so the NetworkManager keyfile branch is the live path);
- the network install additionally writes the release's `jagar-boot.img`
  (SHA-256 verified, then read back and compared) to the GPT partition
  named `boot_a` — the same slot the user already flashed — and reboots
  into the system; the USB install instead ends with
  `dc1-reboot-fastboot` (boot mode nibble 3 in `0x10007024`) so the host
  can flash the boot image itself. That tool's source lives with the
  device package, which also installs it as
  `/usr/sbin/dc1-reboot-fastboot` on the installed system; it is compiled
  into both initramfses from the same file.

Progress is painted on the panel by `src/init.c` (from
`/tmp/installer-status`; suppressed while `/tmp/ui-active` marks a touch
screen as up) and streamed to the host on `/dev/ttyACM0`; a debug shell
listens on TCP 4444 and on the second ACM port.

## Why the touch UI is hand-rolled (`gotools/internal/ask`)

The obvious candidates cannot run against this device's pinned kernel:
postmarketOS **buffyboard** injects keys through `/dev/uinput`, and the
jagar kernel config does not enable `CONFIG_INPUT_UINPUT`; **unl0kr** is no
longer packaged in Alpine, shows only a hardcoded password prompt, and
needs libinput + libxkbcommon + a running udevd. `dc1-ask` is instead one
static binary (<1 MiB) with zero runtime dependencies, reusing the two
interfaces this installer already proves out: the framebuffer path from
`src/init.c` (fbdev-or-devmem + cached shadow buffer) and raw evdev from
the built-in touchscreen driver (`CONFIG_TOUCHSCREEN_ILITEK=y`,
`CONFIG_INPUT_EVDEV=y`). One screen per question: menu, text (QWERTY +
symbols on-screen keyboard), secret (masked), info. If it cannot acquire
the framebuffer or a touchscreen it exits and the USB flow remains — the
touch UI is an addition, never a dependency.

## System boot image (`jagar-boot.img`)

`src/system/init.c` (PID 1) + `src/system/boot.sh`, sharing
`src/partlib.sh` with the installer:

- resolve userdata by GPT `PARTNAME` (unique, ≥ 32 GiB), retrying up to 60 s
  for the late UFS probe;
- require ext4 labelled `jagar-root`; `e2fsck -p` if e2fsck is staged in the
  image, otherwise skip with a logged note (the fs was SHA-256-verified at
  install time and ext4 journals ordinary unclean shutdowns);
- mount, verify `/sbin/init`, move `/dev` `/proc` `/sys`, `switch_root`;
- **any** mismatch drops to a rescue shell on tty1/ttyS0/console — nothing
  is ever written.

**Watchdog decision**: LK arms the SoC watchdog and the kernel does not
auto-pet it, so PID 1 forks a petter that holds `/dev/watchdog` open and
pets every 10 s **forever, across the switch_root** (it only needs its
already-open fd). It is deliberately the *sole* owner: `/dev/watchdog` is
single-open, and whether this driver honours magic-close (vs `nowayout`)
has never been measured, so a close-and-reopen handover to an in-rootfs
watchdog daemon risks either EBUSY or an unstoppable timer. Consequence: a
kernel hang still resets the board (the petter dies with it); a
userspace-only hang does not auto-reset. Revisit if the driver's magic-close
semantics get measured on hardware. The OpenRC `watchdog` service is NOT
enabled by provision.sh for this reason.

## Building

```sh
sudo ./build.sh                          # both initramfs cpios only
sudo env KERNEL_IMAGE=Image.gz MODDIR=mods ./build.sh
                                         # + installer-boot.img + jagar-boot.img
```

Needs `lz4` (the boot chain requires a legacy-frame LZ4 cpio), `curl` and
`xz` (build-time downloads), and network on the first run. Everything
fetched is cached under `dl/` (gitignored, never committed) and verified
before use:

- **MT7902 firmware** (`WIFI_RAM_CODE_MT7902_1.bin`,
  `WIFI_MT7902_patch_mcu_1_1_hdr.bin`) from upstream linux-firmware (tag
  `20260622`) and the signed **wireless-regdb 2026.05.30** pair — each
  pinned by exact size + SHA-256, fail-closed. A same-named file with a
  different hash (the stock Android blobs pass the legacy handshake and
  then fail mainline mt76's UNI commands) fails the build.
- **Alpine edge/main aarch64 apks**, pinned by exact version in `build.sh`
  (`ALPINE_APKS`): busybox-static (the image's `/bin/busybox`, provides
  `blkid`/`cryptpw`/`udhcpc` — Ubuntu's busybox-static lacks `blkid`),
  curl + its full shared-library closure, zstd, wpa_supplicant + libraries,
  the musl loader, and the CA bundle. Only named files are staged, a
  `readelf` DT_NEEDED closure check fails the build if Alpine's dependency
  graph drifts, and a version bump on the mirror 404s the pinned URL so
  the build fails closed until the pin is updated deliberately.

`BUSYBOX=` overrides the busybox binary (must be static; the applet check
enforces `nc sha256sum base64 blkid awk switch_root cryptpw udhcpc` and
friends when the build host can execute it — prefer the native aarch64 CI).
Both boot images are packed by `../boot/repack-boot.sh` (Android header v4,
gzip kernel, AVB0 signature page). The artifact names `installer-boot.img`
and `jagar-boot.img` are load-bearing — the host script, the on-device
installer, and CI depend on them.

The **system** image stays minimal: no firmware, no network userland —
the installed rootfs carries its own (upstream, pinned) MT7902 firmware
via `linux-firmware-mediatek`.

## Tests

```sh
sh tests/run-tests.sh
```

Offline only: `sh -n` over every script, answer validation and generation
(host and TUI variants), provisioning against a fake rootfs, header
parsing, userdata resolution against a fake sysfs tree, the shared write
core against file targets (held-back superblock, scrub-on-reject, commit
label checks), SHA256SUMS / HTTP-Date parsing, and wpa_supplicant config
quoting + permissions.
