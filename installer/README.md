# installer/ — the DC-1 installation-mode and system-boot initramfs

Two minimal, secret-free images built by `build.sh` (no Wi-Fi firmware, no
SSH keys, nothing credential-shaped):

- **installer** (`installer-boot.img`) — installation mode: console + USB
  gadget networking + the installer daemon, flashed *temporarily* to `boot_a`.
- **system** (`jagar-boot.img`) — the real boot image: its initramfs finds
  and verifies the installed `jagar-root` filesystem and `switch_root`s into
  postmarketOS. The stock pmOS initramfs cannot be assumed to work on this
  LK boot chain (v4 image shape, label-based root, LK watchdog), which is
  why this one exists.

## End-user flow

```sh
fastboot flash boot_a installer-boot.img && fastboot reboot   # installation mode
./host/dc1-install.sh --rootfs jagar-rootfs.ext4.zst --boot-image jagar-boot.img
```

`dc1-install.sh` asks for username, password, hostname, timezone, and
optional Wi-Fi credentials; hashes the password locally; streams the raw
ext4 image with its SHA-256 over the USB gadget network (CDC-ECM, device
172.16.42.1 / host 172.16.42.2); and, after the device reports success and
reboots into LK fastboot, flashes the real boot image over the installer.

Tethered `fastboot boot <img>` (no flash) is **unverified** on this LK, which
is why the installer is flashed and later replaced.

## Device side, fail-closed by construction

`src/receive.sh` (TCP 5555, one session at a time):

- target resolved **by GPT partition name** (`PARTNAME=userdata` in sysfs),
  required unique and ≥ 32 GiB — never a hardcoded `/dev/sdX`, and the
  `preloader`/`lk`/`dtbo`/`vendor_boot`/`boot` partitions are untouchable by
  construction;
- the image's first MiB (the ext4 superblock) is held back and written
  **last**, only after the SHA-256 of the whole stream verified, so an
  aborted transfer can never leave a mountable `jagar-root` filesystem;
- the written filesystem must be ext4 labelled `jagar-root` (the label the
  boot initramfs mounts by) before it is mounted;
- online `resize2fs` to the full partition (non-fatal, loudly reported);
- `src/provision.sh` applies the answers as pure file edits (user rename or
  creation with uid/group preservation, shadow hash, hostname, timezone,
  Wi-Fi as NetworkManager keyfile / wpa_supplicant.conf / parked file,
  depending on what the rootfs carries — the shipped rootfs is built with
  `ui=console`, so the NetworkManager keyfile branch is the live path);
- ends with `rebootbl` (BCB `boot-fastboot`) so the host can flash the real
  boot image.

Progress is painted on the panel by `src/init.c` (from
`/tmp/installer-status`) and streamed to the host on `/dev/ttyACM0`; a debug
shell listens on TCP 4444 and on the second ACM port.

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

Needs a **static** aarch64 busybox (`BUSYBOX=`, default
`/bin/busybox.static`) with the `nc sha256sum base64 blkid awk switch_root`
applets, and `lz4` (the boot chain requires a legacy-frame LZ4 cpio). Both
boot images are packed by `../boot/repack-boot.sh` (Android header v4, gzip
kernel, AVB0 signature page). The artifact names `installer-boot.img` and
`jagar-boot.img` are load-bearing — the host script and CI depend on them.

No Wi-Fi firmware ships in this image on purpose: the transfer runs over the
same USB cable fastboot used, and the installed rootfs carries its own
(upstream, pinned) MT7902 firmware.

## Tests

```sh
sh tests/run-tests.sh
```

Offline only: answer validation and generation, provisioning against a fake
rootfs, header parsing, and the userdata resolution logic against a fake
sysfs tree.
