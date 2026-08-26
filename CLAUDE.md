# dc-1-pmos

Public repository for running postmarketOS / Alpine Linux on the Daylight DC-1
(`jagar`, MediaTek MT8781/MT6789). It has two coupled purposes:

1. Document a safe, reproducible installation and operating path.
2. Build the kernel package, device package, desktop compositor package,
   root filesystem, boot images, and installer from pinned source on public
   GitHub runners.

The supported end-user flow is: flash `installer-boot.img` to `boot_a`, boot
the installation-mode initramfs, provide an account and optional Wi-Fi
credentials, then let the installer write `userdata` and the real boot image.
The on-device path is primary; `installer/host/dc1-install.sh` is the USB
network fallback. Build artifacts contain no user-provided credentials.

## Session and machine safety

Start by checking `hostname` and `git status`. If the hostname is `dc1`, this
is the DC-1 itself, not a disposable workstation or CI runner:

- The system is Alpine/postmarketOS on native aarch64; builds do not need qemu.
- There is no system-wide `ssh` client. The user-mode client is
  `/home/dc1/.local/alpine-root/usr/bin/ssh`; GitHub access uses the per-repo
  aliases in `~/.ssh/config`: `github-dc1-pmos`, `github-dc1-linux`, and
  `github-dc1-linux-kernel`.
- `sudo` needs an interactive password. Do not design a command that depends
  on unattended sudo unless the caller has explicitly arranged it.
- Do not reboot, kill services, fill the filesystem, or manipulate partitions
  casually. Losing the running kernel can remove the only recovery channel.

Preserve existing worktree changes. This repository's normal working agreement
is to work directly on `main`, keep diffs focused, commit, and push `main` when
the requested work is complete. Never use destructive Git commands such as
`reset --hard` or `checkout --` without explicit approval.

`AGENTS.md` is a tracked symlink to this file. Edit `CLAUDE.md`; do not replace
the symlink with a second independent instruction file.

## Public-repository rules

Everything committed here is world-readable. Never commit or publish:

- Wi-Fi credentials, `authorized_keys`, private keys, password hashes,
  device serials, factory partition dumps, recovery logs containing internal
  state, or proprietary Android blobs.
- A same-named stock Android Wi-Fi/Bluetooth blob. MT7902 firmware and
  `regulatory.db` must come from upstream `linux-firmware` and
  `wireless-regdb`, fetched at build time and checked by exact size and
  SHA-256. Stock files can pass the old firmware handshake and still fail
  mainline mt76 UNI commands.

The committed `boot/boot-signature.bin` is an explicit, vendor-derived 4096
byte AVB0 boot-signature page with recorded provenance; it is not permission to
add other vendor partitions or blobs. Preserve its hash and provenance if the
boot-image code changes.

The private sibling repository `../dc-1-linux` is read-only source material.
Take reusable code or configuration only. Do not copy its documentation,
hardware evidence, recovery logs, `HANDOFF.md`, `TODO.md`, `history.md`, or
anything that exposes its internal state.

The CI-only `DC1_APK_PRIVATE_KEY` signs the published `APKINDEX.tar.gz`. It
must exist only in the GitHub secret/environment and temporary files created by
the signing script. The public key is intentionally committed at
`pmaports/device/testing/device-daylight-jagar/dc1-apk.rsa.pub`.

## Pinned sources and package overlays

`scripts/versions.env` is the source manifest. It pins `PMAPORTS_COMMIT`,
`PMBOOTSTRAP_COMMIT`, `KERNEL_COMMIT`, and `SOURCE_DATE_EPOCH`. Do not replace
these with floating branches when reproducing a build.

- Kernel source: `https://github.com/denysvitali/dc-1-linux-kernel`, branch
  `jagar`, at `KERNEL_COMMIT`.
- pmaports and pmbootstrap: upstream postmarketOS GitLab checkouts at their
  pinned commits.
- Local pmaports overlay: three recipes currently exist under
  `pmaports/device/testing/`:
  `device-daylight-jagar`,
  `linux-postmarketos-mediatek-mt6789`, and `mutter-mobile`.
- `scripts/prepare.sh` copies the first two into upstream
  `device/testing/`, but places `mutter-mobile` in the upstream
  `extra-repos/systemd/mutter-mobile` location expected by pmbootstrap. Do
  not assume all three are ordinary device packages.

The packages should remain conventional and upstreamable. Keep device-specific
installation policy in `installer/` or the build scripts, not in an APKBUILD
merely because it is convenient. When a package build recipe or its effective
inputs change, bump that recipe's `pkgrel`; pmbootstrap/CI deliberately reuses
an unchanged `pkgver-pkgrel`, and the cached package can otherwise be silently
reused. `scripts/verify.sh` checks the overlay, checksums, pins, and safety
properties.

The kernel compiler boundary is deliberate and must not drift without a
measured reason:

- Kernel C and host LLVM tools use clang/LLVM 20 with
  `LLVM=/usr/lib/llvm20/bin/`, `LD=/usr/bin/ld.lld`, and
  `HOSTLD=/usr/bin/ld.lld`.
- Kernel and host compiler commands route explicitly through
  `CC="ccache clang-20"` and `HOSTCC="ccache clang-20"`; a PATH-only ccache
  setup misses clang on Alpine.
- The DTB pass uses `HOSTCC=gcc`, serially, because the pinned source's
  `fdtoverlay` is unreliable with clang 20. This does not change the kernel
  compiler boundary.
- The APKBUILD sets `CCACHE_DIR=/home/pmos/.ccache` and fails if ccache sees
  zero compiles. Keep that positive control.

## Hardware and boot invariants

These facts cost boot cycles to establish. Treat them as load-bearing unless a
new hardware measurement and documentation update supersede them.

### Partitions, slots, and authentication

- The device boots through MediaTek LK with A/B slots and exposes fastboot
  from LK. There is no general recovery channel without a running kernel.
  The authenticated preloader does not accept an arbitrary download agent for
  storage writes. A vendor-signed agent and auth blob exist only for the
  narrowly documented `misc` BCB recovery path and must never be committed.
- Normal installation may write `boot_a`, `userdata`, and the required A/B
  boot-control data in `misc`. Never tell users to write `preloader`, `lk`,
  `dtbo`, `vendor_boot`, or UFS boot LUNs in the normal path.
- `lk` and `dtbo` are authenticated. `boot` and `vendor_boot` are not, but an
  unsigned `dtbo` can kill a slot before Linux starts. Do not experiment with
  signed partitions on hardware.
- The persistent root is an ext4 filesystem labelled exactly `jagar-root` on
  `userdata`. The system initramfs finds it by label and otherwise enters the
  rescue path. `deviceinfo_flash_method="none"` is intentional: generic
  `pmbootstrap flasher` deployment is not valid for this device.

### Device-tree delivery

The kernel DT does **not** come from `vendor_boot`. LK constructs the runtime
tree from its signed `lk_main_dtb` inside `lk`, merged with signed `dtbo`.
The separate DTB in `vendor_boot` never reaches Linux; writing
`vendor_boot` is a no-op for DT delivery.

The hardware-proven mainline route is `boot/dtbswap`:

1. LK starts the kernel slot with its original FDT address in arm64 `x0`.
2. The freestanding stub in `boot/dtbswap` receives that handoff and jumps to
   `[stub | our DTB | real kernel Image]` with our DTB instead.
3. Its fail-safe paths return LK's original FDT, so a bad swap should fall
   back to stock DT behavior.

Both `installer-boot.img` and `jagar-boot.img` are always built with this
payload — `installer/build.sh` requires `KERNEL_DTB` whenever it builds boot
images, there is no plain/stock-DT image path, and CI plus the host
installer assert the payload on both images. Installation mode
originally shipped on the stock DT, but hardware evidence (issue #1,
2026-08-24) showed a unit where the stock-DT installer black-screens with no
USB gadget while a dtbswap installer works; the initramfs GCE gate accepts
both DT node names (`10228000.gce` stock, `10228000.mailbox` mainline), so
the installer image carries the mainline tree too. The normal install still
flashes only `jagar-boot.img` after the rootfs is written. Nothing ships or
writes `jagar-vendor_boot` images: LK
ignores vendor_boot's DTB (see the invariant above), so a vendor_boot image
cannot deliver a device tree, and every flash path structurally refuses a
plain (non-dtbswap) `jagar-boot.img`.

There are stale vendor_boot-as-DT comments in older prose and workflow/tooling
comments. When touching those files, align them with `boot/dtbswap/README.md`,
`docs/installation.md`, and this section; do not revive the old vendor_boot
path merely to make the comments agree.

### Boot image shape and diagnostics

- Android boot header v4, gzip kernel, legacy-frame LZ4 ramdisk, and a
  non-zero 4096-byte AVB0 signature page are required. `boot/repack-boot.sh`
  owns the pipeline invariants; `boot/mkboot` is the Go parser/packer and
  byte-identical verifier.
- LK builds the complete kernel command line itself. The boot-image header's
  `cmdline` field is not a reliable slot marker or diagnostic channel.
- LK's current-boot log is readable because `CONFIG_STRICT_DEVMEM` is off:

      dd if=/dev/mem bs=4096 skip=$((0x7ffbf000/4096)) count=64

  This ring is reset before LK falls back, so it normally contains the slot
  that succeeded. A failed slot's persisted log is in `expdb`. Prefer these
  logs over inferring failure from silence; pstore is not a reliable channel
  for this port.

### Kernel configuration and hardware notes

Keep `CONFIG_BINFMT_SCRIPT`, `CONFIG_EPOLL`, `CONFIG_SIGNALFD`,
`CONFIG_TIMERFD`, and `CONFIG_EVENTFD`; the udhcpc hook, installer, and BlueZ
depend on them and failures can be silent.

The sensor buses are SCP-connected but reachable from the AP when the pins are
re-muxed and nothing drives the SCP:

- GPIO142/143, AP i2c6 at `0x1101a000`, exposes the MCube MC3416 at `0x4c`
  (`mcube,mc3416`, `drivers/iio/accel/mc3230.c`).
- GPIO132/133, AP i2c1 at `0x11e01000`, exposes an ambient-light/proximity part
  at `0x49`. The AP now owns that bus for controlled bring-up; the sensor stays
  unbound because the MN29 register protocol is still unidentified.

Do not add an AP sensor node while also adding an SCP/sensorhub owner for the
same pins. There is still no gyro or magnetometer; the hall switch is directly
AP-wired and declared in the DTS since kernel `3d3de59a5` (live as an input
device). The panel scanout is 180 degrees from the
glass. If a future DTS `rotation = <180>` property is added, remove the same
180-degree compensation from the accelerometer `mount-matrix` in that change
to avoid double rotation.

Audio invariants (measured 2026-08-17..22):

- Speakers: RT9101 amp behind the codec headphone buffers
  (`HPL`/`HPR Mux` = `LoudSPK Playback`), enabled by the machine driver's
  `Ext_Speaker_Amp` widget (VIBR rail + GPIO158/159). The known-good mixer
  sequence lives in `dc1-audio` and is mirrored by the UCM verb; keep the
  two in sync.
- Microphones: two two-wire digital DMICs on AIN0/AIN2. Capture front end
  is UL1 (ALSA device 9, `Capture_1`). `Mic Type Mux` must stay `DMIC`
  (any other value records digital silence) and `MTKAIF_DMIC` must stay
  `Off` — the codec delivers PCM over MTKAIF, and forcing raw-DMIC
  interpretation does not change or improve capture. There is no headset
  jack, no analog mic, and no JackControl; do not model ACC/DCC/PGA input
  paths.
- GNOME audio needs both: the `55-dc1-audio.conf` WirePlumber fragment
  (Alpine's `pulseaudio-wireplumber` disables `hardware.audio`, which
  stops ALSA enumeration entirely) and the `pipewire-pulse` package
  (the image's PulseAudio backend never starts under systemd, so without
  it there is no server at `$XDG_RUNTIME_DIR/pulse/native` and
  gnome-shell/g-c-c get connection refused).
- WirePlumber 0.5.15 `scripts/monitors/alsa.lua` concatenates a nil
  `node.name` when adapter bind fails (transient EBUSY on `hw:0,0`),
  which kills the ALSA monitor and leaves GNOME on Dummy Output. Do
  not fork that versioned script. `dc1-fix-wireplumber-alsa` reapplies
  a one-line `tostring()` guard from post-install/post-upgrade and from
  the apk trigger on the file, so a wireplumber upgrade cannot restore
  the crash.

Display/DSI invariants (measured 2026-08-24):

- **Kernel logs do not prove the panel is lit.** Short DCS writes complete
  host-side without a panel ACK, so the whole pipeline can report a clean
  power-on -- `production power sequence complete`, `first DSI frame
  complete`, frame-done IRQs -- while the glass is uniformly white. White
  is the resting state of this normally-white LCD with the backlight on
  and no drive.
- The only trustworthy liveness signals are the TE line on GPIO83
  (`gpiomon -c gpiochip0 83`; ~200 edges/2 s when the panel TCON runs, 0
  when it does not) and a DCS read of `0x0a`, where `0x9c` is
  booster|sleep-out|normal|display-on. Verify display work against those,
  never against dmesg.
- A DCS read that times out latches the DSI handoff state machine into its
  failed phase, and the pipeline then refuses every re-enable until
  reboot. Only probe a state you are willing to lose.
- `DSI_SW_CTL_EN` in MIPI-TX must be **clear** while the link is running:
  it parks a lane under software control and disconnects its pad from the
  DSI controller. All five lanes matter -- D0/D1/D2/CK and the real D3
  block at `0x0544`. LK leaves the PLL running, so
  `mtk_mipi_tx_pll_prepare()` early-returns on boot and its cold path is
  exercised only by a DPMS off/on cycle; a bug living there is invisible
  until something relights the panel.
- The bezel overlaps the outer ~10 device px of the 1200x1600 panel on
  every edge, and the lit area's corners are rounded (~30-40 px radius);
  measured 2026-08-25 with on-glass calibration rulers. The full mode is
  correct -- do not shrink the DSI timings to compensate. Edge-flush UI is
  handled by the `dc1-safe-area` shell extension in the device package;
  other shipped UI should keep a >=12 device px margin (~40 px in
  corners).

## Repository map

- `pmaports/device/testing/` — the three local APKBUILD overlays and their
  package files. The device package carries the charging-mode units and
  scripts (see Charging mode under Installed-device convergence). The
  mutter overlay is staged into the upstream systemd extra
  repo by `scripts/prepare.sh`.
- `scripts/` — pinned checkout preparation, pmbootstrap rootfs/package build,
  artifact export, deterministic ext4 creation, rootfs archive creation,
  signed APK index creation, verification, and offline tests.
- `installer/build.sh` — creates both initramfs images and, when given
  `KERNEL_IMAGE` plus the mandatory `KERNEL_DTB`, the two dtbswap Android
  boot images. It also downloads and verifies
  public upstream firmware and pinned Alpine runtime packages into a local,
  gitignored cache.
- `installer/gotools/` — the CGO-free multi-call Go userland (`dc1tools`),
  used by installer PID 1 and the system-initramfs helpers.
- `installer/src/` — C entry points, POSIX initramfs scripts, system-init
  sources, vendored UAPI headers, and the touch/network/write paths.
- `installer/host/` — host-side USB/fastboot fallback installer.
- `installer/tests/` — offline shell tests and syntax gate for installer,
  host, and initramfs scripts.
- `boot/dtbswap/` — freestanding arm64 DT handoff stub and packer.
- `boot/mkboot/` — Go Android boot/vendor_boot v4 tooling and Python verifier.
- `boot/repack-boot.sh` — minimal production boot-image packer.
- `docs/` — installation, status, debugging (`docs/debugging.md`), and the
  narrowly scoped preloader-recovery procedure. `docs/status.md` is the
  compact verdict table plus board reference; the per-subsystem
  measurement records live in `docs/hw/` (`display`, `input`, `audio`,
  `wireless`, `usb`, `power`, `suspend`, `thermal`, `sensors`, `storage`)
  and `docs/gnome.md` (desktop stack). `docs/roadmap.md` is the
  definition-of-done with hardware-session runbooks, `docs/verification.md`
  the verified-at ledger, `docs/security.md` the debug-channel exposure
  matrix, and `docs/power.md` the user-facing battery/charging guide.
  `README.md` is the user-facing quickstart and safety warning.
- `tools/i2cbb/` — hardware probe utility retained for controlled
  re-measurement; it is not a normal build dependency.
- `.github/workflows/build.yml` — the complete verify/build/release contract.
- `.github/workflows/claude-review.yml` and `claude-review-comment.yml` —
  privilege-separated Claude Code PR review (untrusted reviewer job, trusted
  comment poster); see the CI contract section.

## Build flow and artifact contract

`scripts/prepare.sh WORK` fetches only the pinned pmaports and pmbootstrap
commits, validates the overlay scope, copies the three recipes, and writes
`WORK/SOURCES`. `scripts/build-rootfs.sh [--validate-only]
[--verify-sources] WORK OUTPUT` prepares those sources, builds the three
aarch64 packages, installs a non-deploying pmbootstrap rootfs, shuts down the
chroot, and calls `scripts/export-artifacts.sh`.

The rootfs builder must stay non-deploying: it uses `pmbootstrap install
--no-image --no-sshd --no-firewall --no-recommends`, never fastboot, ssh, scp,
or a block-device target. The build-time `dc1`/placeholder account state is
not a user secret; the installer provisions the real account and password.

The exporter produces a tar archive, a `jagar-root` ext4 image compressed as
zstd, exact-version copies of all three APKs, the kernel and DTB inputs under
`boot/`, `FILES.tsv`, `SOURCES`, `PROVENANCE`, and `SHA256SUMS`. Its
`PROVENANCE` intentionally records `flash_method=none`,
`boot_image_included=false`, `deployable=rootfs-image-only`, and
`hardware_verified=false`; the CI release assembly adds the boot images later.

The final release directory contains:

- `installer-boot.img` and `jagar-boot.img`;
- `jagar-rootfs.ext4.zst` and `jagar-rootfs.tar.gz`;
- the three exact-version APKs;
- `dc1-install.sh`, `dc1-repair-apk.sh`, `dc1-apk.rsa.pub`,
  `PROVENANCE`, `SOURCES`, `FILES.tsv`,
  signed `APKINDEX.tar.gz`, and one final `SHA256SUMS` covering all files.

Do not claim that a green CI run proves booting. Releases deliberately say
`hardware_verified=false` until a separate hardware test has been performed.

### Installed-device convergence

Installed devices converge on the release without reflashing, and CI keeps
that path honest:

- `dc1-update.timer` (device package) runs `apk update`/`apk upgrade`
  after boot and weekly; its parity report compares the three overlay
  packages against the published `APKINDEX.tar.gz`. Opt-out is
  `/var/lib/dc1/no-auto-update`.
- `installer/host/dc1-repair-apk.sh` repairs pre-key installs
  (device package pkgrel < 45): it fetches `dc1-apk.rsa.pub` from the
  release and verifies it against that release's `SHA256SUMS`, installs it,
  writes `/etc/apk/repositories.d/dc1-pmos.list` only if absent, restores
  Alpine key links, then upgrades. It must never silently replace an
  existing differing key or repo list — both are trust decisions.
- Gate A (`scripts/export-artifacts.sh`) fails if the rootfs's installed
  versions of the three overlay packages differ from the shipped APKs, and
  records them in `PROVENANCE` as `package_*` lines. Gate B
  (`scripts/build-rootfs.sh`) fails if any upstream postmarketOS mirror
  serves one of the three packages at a version that does not strictly lose
  to ours — bump pkgrel rather than bypassing it. Version ordering for both
  comes from `scripts/apk_version_compare.py`, which matches apk-tools 3.x
  exactly (validated against on-device `apk version -t`).

### Charging mode (device pkgrel >= 79)

Plugging USB power into a cleanly-powered-off device boots the headless
`dc1-charging.target` instead of the desktop: panel/network/desktop stay
off while charging proceeds autonomously in hardware/kernel (MT6375 CC/CV
to 4350 mV; kernel raises AICR to 1.5 A and ICHG to 3.15 A once VBUS appears;
PD contracts settle in-kernel). Constraints future changes must preserve:

- Detection is firmware-first: LK writes a fresh console ring each boot
  at physical `0x7ffbf000` (256 KiB, DT node `log-store@7ffbf000`,
  root-readable via `/dev/mem` — `CONFIG_STRICT_DEVMEM` is off). The
  `dc1-charging-generator` takes the LAST `BOOT_REASON: <n>` line (MTK
  enum: 0 power key, 1 USB charger, 2 RTC, 3 watchdog, 4/5 warm-reboot
  bypass, 8 kpanic), voting only when the tail marker `jump to linux
  kernel 64Bit` shows the ring reached the handoff — stale/partial rings
  don't vote. Reason 1 + VBUS enters charging mode authoritatively;
  reasons 3/4/5 NEVER enter it even with a fresh flag — a docked warm
  reboot must reach the desktop, and that asymmetry is what makes the
  power-key exit work. Reasons 0/2/8/unknown/unreadable fall back to the
  flag path.
- Flag lifecycle: `dc1-poweroff-flag.service` writes
  `/var/lib/dc1/poweroff-clean` (epoch timestamp) via ExecStop on every
  shutdown without reboot markers (`/run/systemd/reboot`/`kexec` absent);
  reboots never leave the flag. It is consumed on every boot, expires
  after 7 days, and only decides when the boot-reason readout cannot.
  Generators never mutate this state (they re-run on daemon-reload).
- All four gates must hold: `/var/lib/dc1/no-charging-mode` absent; VBUS
  present (`/sys/class/power_supply/mt6375-charger/online` = 1 — charger
  drivers are built-in, so sysfs exists before generators run);
  `/var/lib/dc1/first-boot-apps-done` present (an unprovisioned system
  ALWAYS boots to the desktop — a fresh install rebooting with the flash
  cable attached would otherwise wake as dark glass); and reason==1 or a
  fresh clean-poweroff flag.
- Any future headless target must stand down `dc1-boot-watchdog` by
  keeping `/run/dc1-boot-watchdog.pat` present (an existence-based pat);
  otherwise ~600 s of unreachability reboots into a loop with fastboot
  escalation — unrecoverable on a dumb charger.
- The power key needs its own evdev reader (`/usr/sbin/dc1-pwrkey`):
  logind ignores the power key globally on this device
  (`/etc/systemd/logind.conf.d/10-dc1-power.conf`), and `/etc` drop-ins
  outrank `/run`, so a volatile logind override is impossible.
- Opt-out is `touch /var/lib/dc1/no-charging-mode`; journal tag
  `dc1-charging`. The ring mechanism is verified live (a real boot
  printed `BOOT_REASON: 4` + WDT bypass; five expdb cold power-key boots
  show 0), but the charger==1 mapping owes one calibration session
  (power off, plug USB, confirm the ring shows 1; optionally pin MT6358
  CHRIN via debugfs regmap) — NOT hardware-verified until then. Do not
  plumb the boot reason through dtbswap: stub changes are the
  highest-risk class here.

## CI contract

`.github/workflows/build.yml` runs without path filters:

- `verify` on `ubuntu-24.04` (x86) runs `scripts/verify.sh`, all offline
  installer tests, installer/device C smoke builds, `boot/mkboot` Go build/vet/
  tests, `installer/gotools` build/vet/tests plus an arm64 build, and the
  Python boot-tool syntax check.
- `build` on `ubuntu-24.04-arm` runs natively, restores pmbootstrap source,
  package, and ccache caches, builds the pinned rootfs, builds `dtbswap`,
  creates both boot images, assembles the release, signs its APK index, and
  verifies the final manifest.

The workflow runs for pushes to `main`, pull requests, and manual dispatch.
Pull requests upload a workflow artifact. A push to the default branch
publishes/replaces the rolling prerelease `latest`; manual dispatch without a
tag can do the same on the default branch. A manual `pmos-v*` tag publishes a
prerelease with that version. Keep the `DC1_APK_PRIVATE_KEY` secret available;
the build must fail rather than publish an unsigned APK index.

No workflow step may quietly turn a docs-only change into a skipped build. The
cache is part of correctness: unchanged `pkgver-pkgrel` packages must remain
byte-identical so the package and matching boot image do not drift across
runs. Preserve the cache ownership handling and the final SHA256 check.

`claude-review.yml` plus `claude-review-comment.yml` give every pull request
an automated Claude Code review. The split is a security boundary and must
stay: the `pull_request` review job treats all PR content as untrusted, so it
runs with `contents: read` only, `persist-credentials: false`, no secrets
(OpenCode Zen's free `x-preview-f-free` model is keyless through a
loopback-only llm-proxy container), and a read-only Claude toolset
(Read/Grep/Glob; no Bash, writes, or web tools), producing only an artifact.
The trusted `workflow_run` poster is the only holder of
`pull-requests: write`; it re-validates the artifact's PR number against the
reviewed head SHA and posts the review body strictly as data. Do not move
write permissions or secrets into the review job, and do not switch it to
`pull_request_target`.

## Required validation

Before handing off a change, run the narrowest relevant checks and then the
full offline gates when practical:

```sh
sh -n scripts/*.sh installer/build.sh installer/src/*.sh \
  installer/src/system/*.sh installer/host/*.sh installer/tests/*.sh
sh scripts/verify.sh
sh installer/tests/run-tests.sh

(cd boot/mkboot && go build ./... && go vet ./... && go test ./...)
(cd installer/gotools && CGO_ENABLED=0 go build ./... && \
  go vet ./... && go test ./...)
make -C boot/dtbswap
```

`installer/tests/run-tests.sh` is the authoritative installer syntax/test
runner and includes the host scripts. `scripts/verify.sh` runs the packaging,
source/checksum, rootfs archive, ext4, and artifact-export gates. Workflow
YAML should pass `actionlint` when available; otherwise at minimum parse it
with a YAML parser. After pushing, inspect the actual GitHub Actions run and
do not report it green without checking its result.

## Change discipline

- Use POSIX `sh` for scripts unless a file explicitly requires another shell;
  retain `set -eu` and fail-closed validation in build paths.
- Keep generated caches, downloaded firmware, Alpine APKs, and temporary
  images out of Git. Check `git status` after every build.
- Keep installer deployment code separate from package recipes and build
  exporters. Builders must write regular output files only, never select slots
  or write partitions.
- When changing a boot image, re-check the v4 header, gzip kernel, legacy LZ4
  ramdisk, signature page, DT swap payload, and exact artifact hashes. Treat a
  hardware boot as expensive and preserve the known fallback path.
- Update this file when package count, runner/toolchain, release contents,
  partition behavior, or measured hardware invariants change. Keep the
  instruction file operational and evidence-based; do not copy private lab
  history into this public repository.
