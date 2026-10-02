# Contributing

This repository builds and documents a postmarketOS/Alpine port for the
Daylight DC-1. Before contributing code or hardware measurements, read
[CLAUDE.md](CLAUDE.md) (the operational instruction file — it applies to
every contributor, not only to tooling) and the
[README](README.md). Use the [documentation index](docs/README.md) to find
the relevant guide, and the [build guide](docs/building.md) to reproduce CI.

## Where truth lives

- [CLAUDE.md](CLAUDE.md) — build/packaging contract, boot and hardware
  invariants, CI contract, safety rules.
- [docs/hw/](docs/hw/) — per-subsystem measurement records. A hardware fact
  without a date and a "verified at" version is a rumor; add both.
- [docs/verification.md](docs/verification.md) — the ledger of what was
  verified where.
- [docs/roadmap.md](docs/roadmap.md) — open work, with runbooks.

## Local setup

Use a Linux host and start with a regular checkout:

```sh
git clone https://github.com/denysvitali/dc-1-pmos.git
cd dc-1-pmos
sh scripts/check.sh --help
sh scripts/check.sh --check-deps
```

The dependency check reports missing tools for local validation without
installing packages or requesting privileges. Add a check group to inspect
only its dependencies, for example `sh scripts/check.sh --check-deps go`.
Install the reported tools using your host's package manager. Go requirements
come from the two `go.mod` files; the first Go run may download its toolchain
or module dependencies.

Full image builds have additional dependencies and need pmbootstrap chroot
privileges; follow the [build guide](docs/building.md#host-and-dependencies).
Preparing pmaports or building a rootfs is unnecessary for documentation and
local regression checks. On the live tablet, prefer CI for full image builds.

## Validation gates

Run commands from the repository root. Start with the group matching the
change; multiple groups can be supplied in one invocation. The shared
[`scripts/check.sh`](scripts/check.sh) runner checks dependencies first and
keeps C, Go, and DT swap build outputs in temporary directories.

| Change | Relevant validation |
| --- | --- |
| Documentation | Check relative links, heading anchors, and command examples against their implementations; no image build is required |
| Shell scripts | `sh scripts/check.sh syntax`, then the affected packaging or installer tests |
| Package recipes, services, or rootfs export | `sh scripts/check.sh packaging installer`; include `c` for C changes |
| Installer or device C helpers | `sh scripts/check.sh c installer` |
| Boot-image or installer Go tools | `sh scripts/check.sh go` |
| DT swap stub | `sh scripts/check.sh dtbswap`; see the [toolchain requirements](docs/building.md#host-and-dependencies) |
| GitHub workflows | `actionlint`, or at least parse YAML; run the affected local check groups |

For changes spanning these components, run the complete local suite:

```sh
sh scripts/check.sh
```

These checks use fixtures and temporary files without accessing tablet
hardware or deploying images. The packaging and installer groups run
`scripts/verify.sh` and `installer/tests/run-tests.sh`; the Go group also
cross-compiles the installer tools for aarch64. Review any reported skipped
test cases before claiming full coverage.

After pushing, inspect the actual GitHub Actions run and report its observed
state. CI still builds every push to `main`, including documentation changes;
passing software checks does not establish a hardware boot.

## Packaging discipline

- `scripts/versions.env` pins `PMAPORTS_COMMIT`, `PMBOOTSTRAP_COMMIT`,
  `KERNEL_COMMIT`, and `SOURCE_DATE_EPOCH`. Do not float them.
- When a package recipe or its effective inputs change, bump that
  recipe's `pkgrel` — CI deliberately reuses an unchanged
  `pkgver-pkgrel`, and a stale cache can silently serve the old package.
- Three overlay recipes exist under `pmaports/device/testing/`;
  `scripts/prepare.sh` stages two into upstream `device/testing/` and
  `mutter-mobile` into the upstream systemd extra-repo location. Do not
  assume all three are ordinary device packages.
- Keep device-specific installation policy in `installer/` or build
  scripts, not in APKBUILDs.

## Documentation changes

Keep procedures in the installation/build guides and link to them from the
README. Keep current constraints and reproducible measurements in subsystem references,
with dates/versions where needed to bound a claim. Git retains development
history; remove superseded narratives and completed work. Put remaining
acceptance work in the roadmap. Remove superseded instructions rather than appending a
second, conflicting procedure. Check relative links and heading anchors after
moving a section, and compare command examples against the implementation.

## Public-repository rules

Changes here are scoped to the public `denysvitali/dc-1-pmos` repository and
its public kernel source, `denysvitali/dc-1-linux-kernel`. Private repositories
and lab notes are not contribution inputs.

Everything committed here is world-readable. Never commit or publish
Wi-Fi credentials, `authorized_keys`, private keys, password hashes,
device serials, factory partition dumps, recovery logs exposing internal
state, or proprietary Android blobs. MT7902 firmware and `regulatory.db`
must come from upstream at build time under exact size + SHA-256 pins.
The committed `boot/boot-signature.bin` is a one-off with recorded
provenance, not a precedent.

## Hardware measurements

Hardware testing can disrupt recovery access; follow the relevant subsystem
reference before testing on the tablet. The partition rules are absolute: normal work
never writes `preloader`, `lk`, `dtbo`, `vendor_boot`, or UFS boot LUNs.
When you verify (or refute) something on hardware: record it in the
matching `docs/hw/` page with the date and the running package versions
(`uname`'s build counter does not track pkgrel — ask apk), and update
[docs/verification.md](docs/verification.md). Display claims must be
measured against TE/DCS, not kernel logs — see
[docs/debugging.md](docs/debugging.md).

## Workflow

Work on `main` with focused diffs; commit when a coherent change is
complete; push when the requested work is done. Do not use destructive
Git commands (`reset --hard`, `checkout --`) without explicit approval.
Keep generated caches, downloaded firmware, APKs, and temporary images
out of Git — check `git status` after every build. Preserve pre-existing
worktree changes and stage only reviewed paths. Before committing, inspect
`git diff --cached --stat`, `git diff --cached --check`, and the complete
`git diff --cached`. Keep credentials and raw device captures outside the
checkout; ignored files are not a security boundary and can still be force-added.
