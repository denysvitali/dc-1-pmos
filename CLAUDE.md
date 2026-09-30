# Working on dc-1-pmos

This public repository builds and documents postmarketOS / Alpine Linux for
Daylight DC-1 (`jagar`, MediaTek MT8781/MT6789). The supported installation
boots `installer-boot.img` from `boot_a`, provisions an account on-device,
then writes `userdata` and the system boot image. The USB host installer is
the fallback. Read [docs/README.md](docs/README.md) for the documentation map.

`AGENTS.md` is a tracked symlink to this file. Edit `CLAUDE.md`, preserve the
symlink, and keep these instructions about current behavior and constraints.
Implementation details belong in the relevant guide, not a running diary here.

## Start and finish a task

1. Check `hostname` and `git status`. Preserve existing worktree changes.
2. Read the relevant guide and implementation before editing. Work directly
   on `main`; keep changes focused and stage only the work you reviewed.
3. Run the checks appropriate to the change. Review the complete staged diff
   and `git diff --cached --check`; commit and push `main` when done.
4. After pushing, inspect the actual GitHub Actions run. Report its observed
   state; a green build does not prove a hardware boot.

Never use `reset --hard`, `checkout --`, or other destructive Git commands
without explicit approval. Keep generated caches, firmware, APKs, images and
raw device captures out of Git. Check status after builds.

If hostname is `dc1`, you are on the live tablet:

- Alpine/postmarketOS is native aarch64; no qemu is needed.
- Check `command -v ssh` rather than assuming a historical user-root path.
  Git uses the `github-dc1-pmos`, `github-dc1-linux`, and
  `github-dc1-linux-kernel` aliases in `~/.ssh/config`.
- `sudo` needs an interactive password; do not assume unattended access.
- Reboots, service shutdowns, partition writes and large builds can remove
  the only recovery channel. Do not perform them casually.

## Public data and trust

Work is scoped to `denysvitali/dc-1-pmos` and
`denysvitali/dc-1-linux-kernel`. Private repositories and local lab material
are not inputs to public changes.

Never publish credentials, `authorized_keys`, private keys, password hashes,
device serials, factory dumps, recovery logs containing internal state, or
proprietary Android blobs. Ignored files are not a security boundary.

MT7902 firmware and `regulatory.db` come from upstream `linux-firmware` and
`wireless-regdb` at build time, checked by exact size and SHA-256. A same-named
stock blob is not a substitute. Preserve the hash and provenance of the
explicit exception, `boot/boot-signature.bin` (4096-byte vendor-derived AVB0
page); it does not authorize adding other vendor data.

`DC1_APK_PRIVATE_KEY` belongs only in CI secrets and temporary signing files.
The committed `dc1-apk.rsa.pub` is public. Repository repair must refuse to
replace a differing existing key or repository list silently.

## Sources, packages and builds

`scripts/versions.env` pins pmaports, pmbootstrap, kernel and
`SOURCE_DATE_EPOCH`. Reproduce those commits, never floating branches. Kernel
source is the public kernel repository's `jagar` branch at `KERNEL_COMMIT`.

Three overlays produce four APKs:

| Recipe under `pmaports/device/testing/` | Staging / output |
| --- | --- |
| `device-daylight-jagar` | Upstream `device/testing/`; device APK |
| `linux-postmarketos-mediatek-mt6789` | Upstream `device/testing/`; kernel and modules APKs |
| `mutter-mobile` | Upstream `extra-repos/systemd/mutter-mobile`; compositor APK |

- Bump a recipe's `pkgrel` whenever its recipe or effective inputs change.
  CI reuses unchanged versions; an existing published APK filename must
  retain identical bytes.
- Keep recipes conventional. Use POSIX `sh` unless a script requires another
  shell; retain `set -eu` and fail-closed build validation. Installation policy belongs in `installer/`
  or build scripts.
- The modules APK owns all of `/lib/modules`, including kmod indexes; the
  kernel APK depends on its exact version. Export, signing, installed-version
  parity and rollback cover all four APKs.
- Keep `usb-host.config` optional dock drivers modular and essential
  controller/gadget/HID/storage drivers built in. Check both `y` and `m`
  after Kconfig. The installer stages only its gadget-module allowlist.
- Kernel C and host tools use LLVM 20: `LLVM=/usr/lib/llvm20/bin/`,
  `LD=/usr/bin/ld.lld`, `HOSTLD=/usr/bin/ld.lld`,
  `CC="ccache clang-20"`, `HOSTCC="ccache clang-20"`. DTB generation is
  serial with `HOSTCC=gcc`. Keep `CCACHE_DIR=/home/pmos/.ccache` and the
  positive check that ccache recorded compiles.
- Preserve the built-in settings from `sdcard.config` and `latency.config`,
  especially `CONFIG_HIGH_RES_TIMERS=y`. Ship the resolved kernel config.

The rootfs builder is non-deploying: `pmbootstrap install --no-image
--no-sshd --no-firewall --no-recommends`. Builders write regular files;
never use fastboot, SSH/SCP or block-device targets in the build path.

See [building](docs/building.md) for commands and artifact inventory,
[releases](docs/releases.md) for publication, and
[kernel development](docs/kernel-development.md) for local builds and rollback.
Local kernel updates preserve the running stub, DTB and ramdisk; DT/initramfs
changes require the full image workflow. Root-only rollback records stay
outside Git in `/var/lib/dc1/local-kernel`.

## Boot and partition boundaries

- Initial installation writes only `boot_a`, `userdata`, and required A/B
  boot-control data in `misc`. Installed updates use the inactive boot slot.
  Never introduce normal writes to `preloader`, `lk`, `dtbo`, `vendor_boot`
  or UFS boot LUNs. `lk` and `dtbo` are authenticated.
- Persistent root is ext4 labelled exactly `jagar-root` on `userdata`.
  Missing root enters rescue. `deviceinfo_flash_method="none"` is intentional;
  generic pmbootstrap flashing is not supported.
- LK supplies its signed DT plus signed overlay, not `vendor_boot`'s DTB.
  Both boot images must use `boot/dtbswap` to deliver our mainline DT.
  Require `KERNEL_DTB`, assert both payloads, and preserve the stub's fallback
  to LK's original FDT. No plain boot-image or vendor_boot deployment path.
- Boot images require header v4, gzip kernel, legacy-frame LZ4 ramdisk and a
  nonzero 4096-byte AVB0 signature page. `boot/repack-boot.sh` owns packing
  invariants; `boot/mkboot` verifies byte-identical round trips.
- The kernel APK, rootfs kernel and both boot images must contain the same
  kernel. Recheck this and final manifests when changing image assembly.
- LK constructs the command line; the header cmdline is not a reliable
  diagnostic or slot marker. Use the LK ring and persisted failure logs as
  described in [debugging](docs/debugging.md). Do not rely on pstore.

## Hardware constraints

Read the relevant [subsystem reference](docs/README.md#hardware-references)
before changing drivers, DTS, power policy or desktop integration.

| Area | Requirements to preserve |
| --- | --- |
| USB | `dr_mode = "otg"`; keep `g1` bound in host mode. Never remove configfs gadget objects to switch roles. MT6375 TCPM owns VBUS; retain jagar's host-only `mediatek,force-vbus-valid` override. PIO-only MUSB must not advertise `HCD_DMA`. Source PDO stays 5 V/500 mA pending electrical/thermal validation. |
| Display | Logs and frame IRQs do not prove lit glass. Verify TE GPIO83 or DCS `0x0a` (`0x9c`); a timed-out DCS read can prevent re-enable until reboot. Clear `DSI_SW_CTL_EN` on all five lanes, including D3 at `0x0544`. Keep full panel timings and the 60 Hz default. |
| Desktop geometry | Keep at least 12 device px at edges and about 40 px in corners. Lock-sheet OSK padding targets the parent of the unlock dialog's `_stack`, never its background-first child. |
| GPU | `dc1-gpu-freq` is the sole min/max writer; keep thermal cooling and autosuspend. Default floor is 812 MHz with 40 ms poll. Measure continuous and idle-gap p95/max using `tools/performance/`; throughput alone is not smoothness proof. |
| Battery | BQ78Z100 stays disabled until live ACK/protocol measurement. Keep calibrated `mt6358-fg` fallback and single-use clean-shutdown anchor (maximum ten minutes old). |
| Charging | Keep RT9471 disabled and active-low GPIO151 CE high until routing, current sharing, thermals and pack-temperature enforcement are established. Do not enable a second charger blindly. |
| Sensors | AP and SCP must not own the same pins. MC3416 uses AP i2c6; the unidentified i2c1 `0x49` part stays unbound. If DTS gains panel `rotation = <180>`, remove the matching accelerometer mount-matrix compensation. |
| Audio | Keep `dc1-audio` and UCM mixer sequences in sync. Speakers use LoudSPK headphone routes and `Ext_Speaker_Amp`; DMIC capture uses UL1/device 9, `Mic Type Mux=DMIC`, `MTKAIF_DMIC=Off`. No headset/analog-mic paths. |
| Audio services | Keep `55-dc1-audio.conf` and `pipewire-pulse`. Recheck the WirePlumber nil-name guard at upgrades; retain the idempotent fix/trigger rather than forking a versioned ALSA script. |
| Suspend | Keep sleep opt-in until current-build display resume and a wake path are proven. A watchdog is not a timed sleep recovery path. |

Preserve script/event support (`BINFMT_SCRIPT`, `EPOLL`, `SIGNALFD`, `TIMERFD`,
`EVENTFD`), built-in FUSE, Landlock/BPF LSM dependencies, securityfs, kernel
BTF, uinput/uhid, and Bluetooth RFCOMM/BNEP. Keep unprivileged BPF disabled
and the LocalSearch musl `LD_LIBRARY_PATH` drop-in for confined extractors.

### Headless charging and updates

- Charging mode requires VBUS, completed first-boot provisioning, no opt-out,
  and either authoritative charger boot reason or a fresh clean-poweroff flag.
- Read the last `BOOT_REASON` from the fresh LK ring only when its handoff
  tail marker is present. Reason 1 votes charging; reasons 3/4/5 force normal
  boot. Other/unreadable reasons use the flag fallback. Do not modify dtbswap
  to carry this information.
- Generators never consume state. Consume the flag once per boot; expire it
  after seven days. Reboots must not leave a clean-poweroff flag.
- Keep the dedicated charging-mode power-key reader: global logind policy
  ignores this key. Preserve `/var/lib/dc1/no-charging-mode` opt-out.
- Network loss never triggers an automatic reboot. Keep the hardware watchdog
  and rescue lease, and retirement of legacy reachability watchdogs.
- Automatic updates and parity checks cover all four overlays. Respect
  `/var/lib/dc1/no-auto-update`. Upstream versions must strictly lose to ours;
  bump `pkgrel` rather than bypassing the comparison gates.

## CI and release contract

`.github/workflows/build.yml` runs on every push to `main`, PR and dispatch,
without path filters. Verification is on x86 Ubuntu; builds are native arm64.
Preserve package/ccache reuse, cache ownership, local APK public-key restoration
into `config_apk_keys`, and final checksums.

PRs receive artifacts without the APK index and never receive signing secrets.
Publishing must fail without `DC1_APK_PRIVATE_KEY`. Retain immutable numbered
builds, prevent older runs moving `latest` backwards, and embed release tags
in installer images. See [releases](docs/releases.md) for dispatch/rerun rules.

Export provenance is rootfs-only (`flash_method=none`, no boot image).
Release assembly records `flash_method=dc1-installer`, boot images, complete
installer deployability and the full commit. Keep `hardware_verified=false`
until the exact published artifact set completes hardware acceptance.

Preserve the split Claude review workflows: untrusted PR review has read-only
permissions, no secrets, no persisted credentials and a read-only toolset;
the trusted `workflow_run` poster validates PR/head SHA and treats the body
as data. Never move secrets/write permissions into PR review or switch to
`pull_request_target`.

## Validation and documentation

Run narrow checks first, then relevant offline gates when practical:

```sh
sh -n scripts/*.sh installer/build.sh installer/src/*.sh \
  installer/src/system/*.sh installer/host/*.sh installer/tests/*.sh
sh scripts/verify.sh
sh installer/tests/run-tests.sh
(cd boot/mkboot && go build ./... && go vet ./... && go test ./...)
(cd installer/gotools && CGO_ENABLED=0 go build ./... && go vet ./... && go test ./...)
make -C boot/dtbswap
```

Use `actionlint` for workflow changes, or at least parse YAML. Documentation
edits need link/anchor and command checks, not a hardware boot.

Keep README focused on users, guides on procedures, subsystem references on
current constraints, and the roadmap on open acceptance work. Keep only
measurement dates/versions needed to bound a claim; Git retains the development
history. Remove superseded narratives and completed task lists. Update these
instructions when build, release, partition or hardware contracts change.
