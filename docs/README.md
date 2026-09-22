# Documentation

The [project README](../README.md) summarizes support and installation risk.
Use these guides for procedures; use the dated hardware records to assess
what has actually been tested. A successful build is not hardware validation.

## Install and use

| Guide | Covers |
| --- | --- |
| [Installation](installation.md) | Prerequisites, unlocking, on-device and Linux-host installation, updates, buttons, charging mode, and recovery limits |
| [USB docking](usb-docking.md) | Driver coverage, modules package, dock compatibility and acceptance tests |
| [Battery and charging](power.md) | Charge profiles, battery percentage limitations, and owner controls |
| [GNOME desktop](gnome.md) | Desktop components, settings, integration, and remaining session checks |
| [Debugging](debugging.md) | Installer diagnostics, USB consoles, boot failures, and safe collection of evidence |
| [Security and debug channels](security.md) | Which channels are exposed in each boot mode and what access they grant |
| [Last-resort preloader recovery](preloader-recovery.md) | The limited `misc` repair path; requires vendor files not distributed here |

## Build and contribute

| Guide | Covers |
| --- | --- |
| [Building from pinned sources](building.md) | Host requirements, rootfs exports, boot images, and CI release assembly |
| [Local kernel development](kernel-development.md) | Native kernel-only build, installation, and rollback workflow |
| [Contributing](../CONTRIBUTING.md) | Validation, package versioning, public-data rules, and review discipline |
| [Operational instructions](../CLAUDE.md) | Build, boot, hardware, and CI invariants (`AGENTS.md` links to this file) |
| [Roadmap](roadmap.md) | Open acceptance work and hardware-session runbooks |
| [Verification ledger](verification.md) | Dated results, tested package versions, and unverified claims |

## Hardware references

[Hardware architecture and specification](hardware.md) explains the board,
DT delivery, and A/B update model. Subsystem records retain measured results
and their limits; their older versions are evidence, not the current source pins.

| Subsystem | Record |
| --- | --- |
| Display, GPU, and front light | [Display](hw/display.md) |
| Touch, pen, and buttons | [Input](hw/input.md) |
| Speakers and microphones | [Audio](hw/audio.md) |
| Wi-Fi and Bluetooth | [Wireless](hw/wireless.md) |
| USB gadget, host, and Type-C roles | [USB](hw/usb.md) |
| Fuel gauge, chargers, PD, and RTC | [Power hardware](hw/power.md) |
| Suspend and wake | [Suspend](hw/suspend.md) |
| Thermal zones and cooling | [Thermal](hw/thermal.md) |
| Accelerometer and other sensors | [Sensors](hw/sensors.md) |
| UFS and microSD | [Storage](hw/storage.md) |

## Source map

| Directory | Purpose |
| --- | --- |
| [`pmaports/device/testing/`](../pmaports/device/testing/) | Device, kernel, and Mutter package overlays; `prepare.sh` stages Mutter into the upstream systemd extra repository |
| [`scripts/`](../scripts/) | Source pins, checkout preparation, package/rootfs builds, exports, signing, and offline verification |
| [`installer/`](../installer/README.md) | Installer and system initramfs, touch UI, USB host fallback, and offline tests |
| [`boot/`](../boot/README.md) | DT swap payload and Android boot-image packing and verification |
| [`tools/performance/`](../tools/performance/README.md) | GPU throughput, idle-gap latency, and compositor measurement tools |
| [`tools/i2cbb/`](../tools/i2cbb/README.md) | Controlled hardware re-measurement utility; not a build dependency |
| [Build workflow](../.github/workflows/build.yml) | Complete public-runner verification, build, and release contract |

Kernel source lives in the public
[`denysvitali/dc-1-linux-kernel`](https://github.com/denysvitali/dc-1-linux-kernel)
repository, branch `jagar`. The exact revision used here is in
[`scripts/versions.env`](../scripts/versions.env). Private lab repositories,
raw captures, credentials, and vendor downloads are not documentation inputs.
