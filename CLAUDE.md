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

Public development is scoped to `denysvitali/dc-1-pmos` and
`denysvitali/dc-1-linux-kernel`. Private repositories and local lab material
are out of scope. Do not import private documentation, hardware evidence,
recovery logs, handoff notes, or internal state into either public repository.

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

The kernel recipe also emits `linux-postmarketos-mediatek-mt6789-modules`.
The main APK depends on that exact version; the subpackage owns the whole
`/lib/modules` tree and kmod indexes. `usb-host.config` pins optional dock
drivers to `=m`, with controller/gadget/basic HID/storage built in. Preserve
both y and m checks after Kconfig. Export, installed-version parity, signing
and local-update rollback must cover all four APKs. The installer stages only
its explicit legacy gadget-module allowlist, never the whole module tree.
See `docs/usb-docking.md` for the acceptance boundary.

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

## Build flow and artifact contract

For native kernel-only development, `scripts/kernel-local.sh build` retains
the pmbootstrap toolchain chroot and compiler cache. `install` installs the
verified local APK and deploys it through the existing A/B helper;
`build-install --reboot` combines the steps. See `docs/kernel-development.md`.
The local updater preserves the running slot's stub, DTB and ramdisk, so
device-tree/initramfs changes still require the full image workflow. Root-only
rollback images and transaction records live in `/var/lib/dc1/local-kernel`
and must never enter Git. A boot-time confirmation service checks the new
build or restores the old matching package after fallback.

The kernel overlay applies `sdcard.config` and `latency.config` to its pinned
base defconfig and requires their storage and high-resolution timer settings
to resolve built-in.
The resolved configuration is included in the kernel APK. The source archive
prefetcher handles the archive separately from this local config input.

`scripts/prepare.sh WORK` fetches only the pinned pmaports and pmbootstrap
commits, validates the overlay scope, copies the three recipes, and writes
`WORK/SOURCES`. `scripts/build-rootfs.sh [--validate-only]
[--verify-sources] WORK OUTPUT` prepares those sources, builds four
aarch64 packages from those three recipes, installs a non-deploying pmbootstrap
rootfs, shuts down the chroot, and calls `scripts/export-artifacts.sh`.

The rootfs builder must stay non-deploying: it uses `pmbootstrap install
--no-image --no-sshd --no-firewall --no-recommends`, never fastboot, ssh, scp,
or a block-device target. The build-time `dc1`/placeholder account state is
not a user secret; the installer provisions the real account and password.

The exporter produces a tar archive, a `jagar-root` ext4 image compressed as
zstd, exact-version copies of all four APKs, the kernel and DTB inputs under
`boot/`, `FILES.tsv`, the installed package/checksum inventory `PACKAGES.tsv`,
`SOURCES`, `PROVENANCE`, and `SHA256SUMS`. Its
`PROVENANCE` intentionally records `flash_method=none`,
`boot_image_included=false`, `deployable=rootfs-image-only`, and
`hardware_verified=false`; the CI release assembly adds the boot images later.

The final published release directory contains:

- `installer-boot.img` and `jagar-boot.img`;
- `jagar-rootfs.ext4.zst` and `jagar-rootfs.tar.gz`;
- the four exact-version APKs (kernel, kernel modules, device, Mutter);
- `dc1-install.sh`, `dc1-repair-apk.sh`, `dc1-apk.rsa.pub`,
  `PROVENANCE`, `SOURCES`, `FILES.tsv`, `PACKAGES.tsv`,
  signed `APKINDEX.tar.gz`, and one final `SHA256SUMS` covering all files.

Release assembly changes the exporter's rootfs-only provenance to
`flash_method=dc1-installer`, `boot_image_included=true`, and
`deployable=complete-installer-release`, and records the full release commit.
It must prove that the kernel APK, rootfs `Image.gz`, and both dtbswap boot
images contain the same kernel. A rolling release may not replace the bytes of
an existing APK filename; bump that recipe's `pkgrel` instead.

Do not claim that a green CI run proves booting. Releases deliberately say
`hardware_verified=false` until a separate hardware test has been performed.

### Installed-device convergence

Installed devices converge on the release without reflashing, and CI keeps
that path honest:

- `dc1-update.timer` (device package) runs `apk update`/`apk upgrade`
  after boot and weekly; its parity report compares the four overlay
  packages against the published `APKINDEX.tar.gz`. Opt-out is
  `/var/lib/dc1/no-auto-update`.
- `installer/host/dc1-repair-apk.sh` repairs pre-key installs
  (device package pkgrel < 45): it fetches `dc1-apk.rsa.pub` from the
  release and verifies it against that release's `SHA256SUMS`, installs it,
  writes `/etc/apk/repositories.d/dc1-pmos.list` only if absent, restores
  Alpine key links, then upgrades. It must never silently replace an
  existing differing key or repo list — both are trust decisions.
- Gate A (`scripts/export-artifacts.sh`) fails if the rootfs's installed
  versions of the four overlay packages differ from the shipped APKs, and
  records them in `PROVENANCE` as `package_*` lines. Gate B
  (`scripts/build-rootfs.sh`) fails if any upstream postmarketOS mirror
  serves one of the four packages at a version that does not strictly lose
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
- Network reachability must not trigger automatic reboots. The old service
  and post-switch-root deadman were removed; device r98 uses a unit condition
  and tmpfiles markers to retire copies from older boot images, including
  headless boots. Keep the hardware watchdog and rescue-path lease intact.
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
  tests, and `installer/gotools` build/vet/tests plus an arm64 build.
- `build` on `ubuntu-24.04-arm` runs natively, restores pmbootstrap source,
  package, and ccache caches, builds the pinned rootfs, builds `dtbswap`,
  creates both boot images, and assembles the artifact. Publishing events sign
  its APK index and verify the final manifest; pull requests omit the index.

The workflow runs for pushes to `main`, pull requests, and manual dispatch.
Pull requests upload a workflow artifact without `APKINDEX.tar.gz`: untrusted
PR code never receives or executes with `DC1_APK_PRIVATE_KEY`. A successful push to the
default branch publishes a retained `build-<github.run_number>` prerelease,
then refreshes `latest`. Runs queue with `queue: max` and are not canceled by
newer pushes. Published numbered assets are never replaced; reruns keep their
number and must match the existing manifest. Older runs cannot roll `latest`
backwards. Manual dispatch without a tag also uses a build number; a manual
`pmos-v*` tag publishes a retained prerelease without updating `latest`.
Installer images embed their release tag so their payload downloads remain
consistent when `latest` moves. See `docs/releases.md`.
Keep the `DC1_APK_PRIVATE_KEY` secret available
to publishing events; they must fail rather than publish an unsigned APK index.

No workflow step may quietly turn a docs-only change into a skipped build. The
cache is part of correctness: unchanged `pkgver-pkgrel` packages must remain
byte-identical so the package and matching boot image do not drift across
runs. `config_abuild` carries the cached local signing key; on restore,
`scripts/restore-local-apk-key.sh` must copy its public half into pmbootstrap's
derived `config_apk_keys` before package/rootfs work begins. Preserve that
handoff, the cache ownership handling, and the final SHA256 check.

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

## Focused references

Read the reference for the area you will change before editing it; its constraints
remain mandatory within that scope. Open relevant sections rather than loading
every reference. Verify current behavior in source and configuration.

- [Hardware and boot invariants](agent-reference/04-hardware-and-boot-invariants.md)
- [Repository map](agent-reference/05-repository-map.md)

Keep instruction files below 24 KiB and the inherited project chain below 28 KiB.
Move details into focused references instead of raising the context limit.
