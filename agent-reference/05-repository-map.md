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
- `boot/mkboot/` — Go Android boot v3/v4 tooling with a
  byte-identical round-trip verifier.
- `boot/repack-boot.sh` — minimal production boot-image packer.
- `docs/README.md` — documentation index and source map; `docs/building.md`
  explains build requirements, pinned inputs, and the export/release boundary.
- `docs/` — installation, debugging (`docs/debugging.md`), and the narrowly
  scoped preloader-recovery procedure. `README.md` contains the compact verdict
  table; `docs/hardware.md` records the boot/update architecture and sourced
  board specification; the per-subsystem
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

