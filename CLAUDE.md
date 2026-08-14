# dc-1-pmos

Public repository for running postmarketOS / Alpine Linux on the Daylight DC-1
(`jagar`, MediaTek MT8781/MT6789). Two jobs:

1. **Document** how to install and run Linux on the DC-1.
2. **Build** everything needed to do so — kernel apk, device apk, rootfs, and a
   bootable installer image — from source, on every commit, on public GitHub
   runners, published as a rolling GitHub release.

The end-user flow this repo targets: a handful of `fastboot` commands put the
device into **installation mode** (our installer initramfs), the installer asks
for username, password, and Wi-Fi credentials, then writes and configures the
system. No secrets are ever baked into published artifacts.

## THIS REPOSITORY IS PUBLIC

Everything committed here is world-readable. Non-negotiable rules:

- **Never** commit: Wi-Fi credentials, `authorized_keys`, private keys,
  device serials, factory partition dumps, or proprietary Android blobs.
- MT7902 Wi-Fi/BT firmware and `regulatory.db` come from **upstream
  linux-firmware / wireless-regdb only**, downloaded at build time and pinned
  by size + SHA-256. Never commit the blobs themselves; never accept
  same-named stock Android blobs (they pass the handshake and then fail
  mainline mt76's UNI commands).
- The private sibling repo `../dc-1-linux` is **read-only source material**.
  Take only building blocks (scripts, sources, configs), never documentation,
  hardware evidence, recovery logs, `HANDOFF.md`/`TODO.md`/`history.md`
  content, or anything referencing its internal state.

## Sources of truth

- Kernel: https://github.com/denysvitali/dc-1-linux-kernel, branch `jagar`.
  Pinned by commit in `scripts/versions.env`
  (`KERNEL_COMMIT`). Kernel builds use clang/LLVM/LLD 20 via kbuild's
  prefix form (`LLVM=/usr/lib/llvm20/bin/` + explicit `LD=/usr/bin/ld.lld`;
  Alpine ships no `ld.lld-20`).
  The boot-proven compiler boundary was clang 19, but Alpine edge dropped
  the clang19 package (2026-08), so 20 is the closest buildable toolchain;
  do not move it further without reason.
- pmaports + pmbootstrap: upstream postmarketOS GitLab, pinned by commit in
  `scripts/versions.env`. Our two overlay packages
  (`device-daylight-jagar`, `linux-postmarketos-mediatek-mt6789`) live in
  `pmaports/device/testing/` here, laid out exactly as they would land
  upstream — **upstreamability is a design goal**: keep APKBUILDs
  conventional, keep device-specific hacks in the installer, not the
  packages.

## Layout

- `pmaports/device/testing/` — the two pmaports overlay packages, in
  upstream layout.
- `scripts/` — pinned-source preparation, rootfs build, artifact export,
  image creation, `versions.env`, offline tests.
- `installer/` — the installation-mode initramfs: builder, init + rc
  sources, and the interactive installer (username/password/Wi-Fi prompts,
  rootfs write, first-boot provisioning).
- `boot/` — Android boot-image v4 tooling: `mkboot` (Go) and the repack
  script owning the LK invariants (gzip kernel, legacy-frame LZ4 ramdisk,
  non-zero 4096-byte AVB0 signature page).
- `docs/` — user-facing installation and status documentation.
- `.github/workflows/` — CI.

## Hardware invariants (cost boot cycles to learn; do not re-derive)

- The DC-1 boots via MediaTek LK with A/B slots. `fastboot` is available from
  LK. There is **no recovery channel without a running kernel**: the
  authenticated preloader does not accept a download agent for storage
  writes. Never instruct users to write `preloader`, `lk`, `dtbo`,
  `vendor_boot`, or UFS boot LUNs in the normal install path.
- Boot images are Android header **v4**, gzip kernel, legacy-frame LZ4
  ramdisk, with a non-zero AVB0 signature page. `pmbootstrap flasher` and
  generic pmOS boot deployment do not reproduce this;
  `deviceinfo_flash_method="none"` is deliberate and required.
- The persistent root is the ext4 filesystem **labelled `jagar-root`** on
  `userdata`. The label is load-bearing: the initramfs finds root by label
  and falls back to the recovery shell otherwise.
- Kernel config must keep `CONFIG_BINFMT_SCRIPT`, `CONFIG_EPOLL`,
  `CONFIG_SIGNALFD`, `CONFIG_TIMERFD`, `CONFIG_EVENTFD` (udhcpc hook + BlueZ
  need them; failures are silent).

## CI

- Public GitHub runners only. Use `ubuntu-24.04-arm` for aarch64 work
  (native, no qemu binfmt); `ubuntu-24.04` for x86 lint/static jobs.
- Every push builds; a rolling prerelease publishes artifacts so users can
  always fetch the latest build. pmbootstrap skips unchanged
  `pkgver-pkgrel` — **bump `pkgrel` when you change a build recipe** or the
  cached package is silently reused.
- ccache must be routed explicitly (`CC="ccache clang-20"`); Alpine's ccache
  shims cover gcc names only, so a PATH-based LLVM build silently misses the
  cache. Keep the positive controls: fail if ccache saw zero compiles when a
  kernel was built.
- A green build proves compilation, not booting. Releases record
  `hardware_verified=false`.

## Definition of done

- Shell: `sh -n` every script; scripts are POSIX sh unless they say
  otherwise.
- Python: `python3 -m py_compile`; run `scripts/tests/` and
  `installer/tests/` offline tests.
- Go (`boot/mkboot`): `go build ./... && go vet ./... && go test ./...`.
- Workflows: `actionlint` (or at minimum a YAML parse).
- After push: check the Actions run; don't claim green without looking.

## Working agreements

- Commit and push to `main` after completing work; no feature branches.
- Keep diffs minimal; no reformatting of untouched code.
- When editing anything under `pmaports/`, ask "would upstream take this
  as-is?" — if not, move the logic elsewhere.
