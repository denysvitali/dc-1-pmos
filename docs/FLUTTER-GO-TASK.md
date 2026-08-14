# Task: DC-1 on-device UI — Flutter (frontend) + Go (backend)

## Mission
Build the DC-1's touch UI: a Flutter app running as a Wayland client under Sway
on the installed postmarketOS system, backed by a static Go binary. Start with a
minimal HW-accelerated "first light" window, then the onboarding flow
(Wi-Fi → identity → hostname → timezone → done), packaged as a conventional
pmaports apk.

## Repo and current state
- Repo: `github.com/denysvitali/dc-1-pmos`, branch `main`. **Public.** Never
  commit secrets.
- The display/compositor stack is already wired and building green: `ui=sway`,
  `mesa-dri-gallium` + `font-dejavu` + `openssh-server` in
  `scripts/build-rootfs.sh` `extra_packages`; the device package
  `pmaports/device/testing/device-daylight-jagar/` ships `dc1-display-gate`,
  `dc1-frontlight`, `dc1-usb-gadget`, `dc1-debug-shell`, and `dc1-sway.conf` →
  `/etc/sway/config.d/00-dc1-output.conf`.
- **Do not re-derive the display gate, the USB gadget, or the provisioning.**
  Those are done.
- Read these for exact behavior to replicate, not reimplement:
  - `installer/src/tui.sh` — the onboarding screens + validation rules (below).
  - `installer/src/provision.sh` — user/hostname/timezone/wifi application (the
    Go backend reuses its *apply* logic, not a rewrite).
  - `installer/src/wifi.sh` — Wi-Fi semantics, but note: the installed system
    uses **NetworkManager**, so Go controls Wi-Fi via `nmcli`, not raw
    wpa_supplicant.

## Locked architecture (do not relitigate)
- **Flutter renders via the GTK3 embedder** (`flutter-gtk`) → libepoxy/EGL →
  Mesa Panfrost GLES 3.1 (Mali-G57). **Not** flutter-pi (glibc, fights Sway for
  DRM master). **Not** Vulkan (PanVK non-conformant on G57). Run with
  `GDK_BACKEND=wayland`, `MESA_LOADER_DRIVER_OVERRIDE=panfrost`,
  `WLR_RENDERER=gles2` (unset `WLR_RENDERER_ALLOW_SOFTWARE`; llvmpipe is a
  failure, not a fallback).
- **Compositor: Sway** (the device needs a statusbar/background later; sway is
  already the DRM master).
- **Go backend = one static binary** `dc1-backend`, `GOOS=linux GOARCH=arm64
  CGO_ENABLED=0` (no libc dep; runs on musl).
- **IPC = plain HTTP/JSON over a Unix domain socket** (e.g.
  `/run/dc1-ui.sock`), plus one NDJSON progress stream. Never bind TCP; the USB
  host and future Wi-Fi must not reach the control plane.
- **Where it lives:** the installed rootfs, run at first boot. The initramfs is
  too small for Flutter (~150 MB).

## Exact package versions (Alpine edge, aarch64)
Runtime (into the shipped rootfs): `flutter-gtk=3.38.4-r2` (runtime embedder +
deps only).
Build-only (in the pmbootstrap chroot, never shipped):
`flutter-desktop=3.38.4-r2` (pulls `flutter-common`, `flutter-tool`,
`dart-sdk`).
Compositor/GPU (already pulled): `sway=1.12-r0`, `swaybg=1.2.2-r0`,
`wlroots0.20=0.20.2-r1`, `seatd=0.9.3-r1`, `elogind=255.24-r0`,
`libinput=1.31.3-r0`, `mesa-egl=26.1.6-r0`, `mesa-dri-gallium=26.1.6-r0`,
`font-dejavu=2.37-r6`.

## Phase 1 — Minimal Flutter "first light" (smallest verifiable unit)
1. One-file `lib/main.dart`: a `MaterialApp` with a colored `Scaffold` (e.g.
   background `0xFF101418`, a bold "DC-1" title). Nothing else. No backend, no
   networking.
2. Build **inside the pmbootstrap Alpine aarch64 chroot** (musl), NOT the
   ubuntu runner (glibc-hosted `flutter build` produces a glibc-linked bundle
   that can't dlopen Alpine's musl `libflutter_linux_gtk.so`):
   ```sh
   apk add flutter-desktop
   flutter create --platforms=linux dc1_shell
   # replace lib/main.dart with the scaffold above
   cd dc1_shell && flutter build linux --release
   ```
   Artifact: `build/linux/arm64/release/bundle/` (`app`, `lib/libapp.so`,
   `lib/libflutter_linux_gtk.so`, `data/flutter_assets/`).
3. Package it so it can be installed to e.g. `/usr/lib/dc1-ui/` and launched by
   Sway (`exec /usr/lib/dc1-ui/app` in
   `/etc/sway/config.d/00-dc1-output.conf` or a small wrapper).
4. **Acceptance:** the app binary runs; offline test asserts the bundle
   contents and that `flutter-gtk` (not `flutter-common`/`dart-sdk`) is the
   only Flutter package in the shipped rootfs. **Hardware proof (renderer
   string contains "Panfrost"/Mali-G57, not llvmpipe) is a separate step and
   may be blocked on display bring-up — do not block on it.**

## Phase 2 — Go backend + IPC contract
Static `dc1-backend` (top-level `ui/`), CGO_ENABLED=0. Scope is **onboarding
only** — do NOT re-implement the installer's write/download/USB logic (that
stays shell, byte-compatible with the frozen host `dc1-install.sh`).

Endpoints (all on the Unix socket):
- `GET /wifi/scan` → JSON list of SSIDs (via
  `nmcli -t -f SSID,SIGNAL device wifi list`).
- `POST /wifi/connect` `{ssid, psk}` → connect via NetworkManager; PSK never on
  an argv that gets logged — use a stdin/`nmcli`-safe form, and keep it out of
  logs/kmsg.
- `POST /onboard` `{user, password, hostname, timezone}` → validate (rules
  below), hash password on-device via
  `printf '%s' "$pw" | cryptpw -m sha512 -P 0` (stdin, never argv), then apply
  using the same logic as `provision.sh` (user rename/create, `/etc/hostname`,
  `/etc/localtime`, NetworkManager keyfile). Gate by an idempotent marker
  `/var/lib/dc1-installer/provisioned`.
- `GET /events` → NDJSON progress stream for the UI.

Secrets: password/PSK live only in `[]byte` (zeroed after use) + mode-0600
files; never echoed, never on argv, never in logs. This is a **public** repo —
no credentials in any committed artifact.

## Phase 3 — Onboarding screens (exact, from `tui.sh`)
Screens in order: (1) Wi-Fi — scan/pick/manual SSID/rescan/back; (2) PSK
(8–63); (3) username; (4) password ×2 (match); (5) hostname; (6) timezone
(UTC / Europe/Zurich / Europe/Berlin / Europe/London / America/New_York /
America/Los_Angeles / Asia/Tokyo / "type another"); (7) confirm; (8) progress
(FETCHING / DOWNLOADING / VERIFYING / WRITING / COMPLETE / FAILED).

Validation rules (mirror `tui.sh` exactly — a typo must be caught on-screen,
not after a destructive step):
- username: reject `root`/`nobody`; `[a-z_]` or `[a-z_][a-z0-9_-]*`, ≤32.
- hostname: reject trailing `-`; `[a-z0-9]` or `[a-z0-9][a-z0-9-]*`, ≤63.
- timezone: non-empty, no `..`, no leading/trailing `/`, chars
  `[A-Za-z0-9_+/-]`.
- PSK: 8–63. SSID: ≤32, no newline.

## Phase 4 — Packaging (upstreamable)
Create `pmaports/device/testing/dc1-ui/APKBUILD` (or similar) that:
- `depends="flutter-gtk=3.38.4-r2"` (exact pin — a bare `flutter-gtk` drifts
  when Alpine bumps it).
- Installs the prebuilt Flutter bundle + the static `dc1-backend` + any
  `openrc` service for first-boot launch.
- Records the exact `flutter-gtk` apk **size + SHA-256** and fails the build on
  drift (same fail-closed pattern the repo already uses for the kernel and
  installer apks).
- Bump `pkgrel` on every recipe change.

## Invariants (do not break)
- The USB install fallback (`DC1-INSTALL-V1` on TCP 5555, `receive.sh`) must
  keep working.
- The display gate opens at **runtime only** — never during early boot (that
  DOES NOT BOOT).
- One proven boot slot (`boot_b`) is always left untouched.
- `hardware_verified` stays `false` in release metadata until a window is
  physically seen.

## Definition of done (per phase)
- Shell/Go/Dart pass the repo's existing checks (`sh -n`, `go build/vet/test`,
  offline tests in `installer/tests/` + `scripts/tests/`).
- `scripts/verify.sh` still green; secret tripwire still clean.
- CI (`.github/workflows/build.yml`) green on the `ubuntu-24.04-arm` runner.
- No secrets in any committed file; `flutter-common`/`dart-sdk` are not in the
  shipped rootfs.

## Escalate, don't guess
- The display first-light on the installed system is **not yet
  hardware-verified** (separate open item). If the Flutter window can't be
  physically verified yet, build + package + offline-test it and flag it as
  blocked on that item — do not claim it works.
