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

## Validation gates

Run the narrowest relevant checks, then the full offline gates before
handing off:

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

Workflow YAML should pass `actionlint` when available. After pushing,
inspect the actual GitHub Actions run — do not report it green without
checking its result.

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
README. Keep dated measurements in the subsystem records; old evidence remains
useful when its version and limitations are explicit. Put remaining acceptance
work in the roadmap. Remove superseded instructions rather than appending a
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

A hardware boot is expensive and this device has no recovery channel
without a running kernel. The partition rules are absolute: normal work
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
