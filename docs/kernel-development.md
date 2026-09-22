# Local kernel builds on the DC-1

Run from this repository as your normal user:

```sh
./scripts/kernel-local.sh build
./scripts/kernel-local.sh install
# Or build, install and reboot in one invocation:
./scripts/kernel-local.sh build-install --reboot
```

The script prepares the pinned pmbootstrap/pmaports sources under `work/`,
checks the source archive checksum, retains the compiler chroot with `--lax`,
and reuses ccache. `DC1_KERNEL_WORK` selects another workspace. Installation
uses sudo; build-only never installs a package on the host or flashes a slot.
The installed system must provide Python 3, Go, systemd, apk-tools 3, lz4, cpio,
`dc1-slotctl`, and the repository's current `dc1-boot-sync` implementation.

Increment the kernel APKBUILD's `pkgrel` whenever its effective inputs change.
An unchanged package version is deliberately reused. Source changes still
require updating the pinned kernel commit/archive checksum and
`scripts/versions.env`; editing the sibling kernel checkout alone does not
change this package. `sdcard.config` adds built-in storage requirements to
the pinned defconfig; `latency.config` requires high-resolution timers for
GPU wake and desktop scheduling precision. The recipe verifies the resolved
values from both fragments, and packages the resulting configuration.

The kernel recipe emits a separate `-modules` APK and requires its exact
version. Keep both APKs together for local installation. `usb-host.config`
checks that optional dock drivers remain modules and the recovery controller
and gadget remain built in. Both packages are backed up for rollback; the
updater also handles returning to an older kernel with unsplit modules.

The installer is for **kernel-only updates**: it preserves the running slot's
dtbswap stub, device tree, ramdisk and signature. Use the full image build
workflow for device-tree or initramfs changes. It refuses ambiguous running
kernel identities, an unproven fallback, a mismatched installed kernel,
missing SD-card configuration, or an unavailable matching rollback APK in
`/var/cache/apk` or a retained local transaction. The new build banner must
differ from the running one.
It also refuses a ramdisk containing kernel modules, which would need to be
rebuilt against the new kernel instead of copied into the new boot image.

Before writing, it stages and verifies the package, backs up both boot images
and the previous matching kernel/modules packages under `/var/lib/dc1/local-kernel/`, and
checks the repacked image with `mkboot` and the kernel-parity verifier.
The rollback APK's control checksum must match the installed package database;
its archive integrity and kernel bytes are checked before it is retained.
Rollback uses that authenticated copy even when CI's ephemeral package-signing
public key is no longer available locally.
These root-only records may contain private ramdisk configuration and must
never be committed. Package scripts are suppressed for this transaction;
the existing boot deployer instead consumes the verified local boot image,
checks readback, and arms the inactive slot for one try. A separate check
then asserts that the fallback image stayed unchanged. Runtime masks prevent
the automatic updater and boot-sync services racing installation; those
masks disappear on reboot.

On the next boot, `dc1-local-kernel-confirm.service` verifies the candidate's
full build banner, installed/boot kernel hashes, installed modules identity, MMC host and available
filesystems before marking its slot successful. When the same SD card is
still inserted, it also verifies an existing kernel filesystem mount or
performs a temporary read-only mount (ext4 uses `noload` to avoid journal
replay). Card removal is recorded as a skipped mount check. If the old kernel
boots, it restores the backed-up package, including its matching modules.
Fallback also creates `/var/lib/dc1/no-auto-update`, preventing the scheduled
updater from immediately reinstalling a failed candidate. Remove that marker
only after reviewing the failure and preparing a corrected kernel.

Check the result after reboot:

```sh
sudo cat /var/lib/dc1/local-kernel/last-result
sudo systemctl status dc1-local-kernel-confirm.service
uname -v
ls /dev/mmcblk*
```

If installation stops with a pending transaction, inspect its root-only
`pending.json`, boot state and journal before retrying or rebooting. The
script refuses to overwrite a pending transaction. Installation without
`--reboot` leaves the verified new slot armed and prints the records path.
