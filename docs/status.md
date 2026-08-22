# Hardware support status — Daylight DC-1 (`jagar`)

Status of the mainline-based kernel port this repository packages. "Works"
means it has functioned on real hardware in earlier bring-up; it does **not**
mean the artifacts built by any given CI run were booted — releases carry
`hardware_verified=false`, and CI only proves the build compiles.

Every row below was re-checked against a running device on 2026-08-17. Two
rows that claimed "Works" did not survive that (Bluetooth and USB gadget); the
notes say what was actually measured. Most rows were tested at kernel pkgrel=20
/ device pkgrel=31. **The audio row was hardware-verified on 2026-08-17 at
kernel pkgrel=24 / device pkgrel=38**, which is the current pin: built-in
speakers produce audio, and the AFE survives multiple play cycles without
entering PM error state.

**As of 2026-08-19 the device boots the mainline device tree**, via the
`boot/dtbswap` stub: LK still builds its merged tree from the *signed*
`lk_main_dtb` + `dtbo` (neither replaceable — an unsigned `dtbo` fails
authentication and kills the slot before the kernel starts; both slots of
the development device were lost that way once), but `boot.img` is
unauthenticated, so a stub in its kernel slot receives LK's handoff and
jumps to the real kernel with our DTB, copying LK's runtime-patched
`bootargs`, initrd addresses and `/memory` from the merged tree.
Hardware-verified 2026-08-19: `/proc/device-tree/model` reads
`Daylight Computer DC-1`, DRM binds OVL/RDMA/DSI, and GNOME runs with
atomic modesetting. `vendor_boot` remains a no-op for the DT (its blob
never reaches the kernel — measured from LK's log on 2026-08-18).

**Losing the dtbo cuts both ways.** The signed dtbo was also the only thing
that *enabled* some hardware: the MT7902's SDIO host (`mmc@11240000`) exists
only through it, so the first mainline-DT boots had an empty
`/sys/bus/mmc/devices` and **no Wi-Fi** (measured 2026-08-19). Fixed the
same day in three layers, each hardware-verified: kernel `231fa88`
(transcribe the dtbo's host node into the board DTS), kernel `0c26bee`
(power the MSDC1 pad rails VCN18 + VMC — vendor `vioa/viob`, which mainline
mtk-sd never enables; with them off every pad read low), and pmos `0f63c60`
(stage the MT7902 firmware in the system initramfs, because the built-in
driver requests it at ~2.8 s, before the rootfs exists). The same pattern —
"the dtbo enabled it, the board DTS must now describe it" — is the first
thing to check for anything else that stops working on the mainline tree.

**Reachability watchdog (hardware-verified 2026-08-19).** A boot the
network cannot reach used to be unrecoverable without a key combo. The boot
image now self-deploys `dc1-boot-watchdog` into the installed system: while
an inbound shell connection exists — or a shell port listens and a probe
peer (USB host `172.16.42.2` or the Wi-Fi gateway) answers — it stays
quiet; after 10 unreachable minutes it reboots into LK fastboot via the
`WDT_NONRST_REG2` nibble (both the tool and the full unattended fire were
observed landing the device in fastboot). An initramfs deadman (15 min)
backstops the case where systemd never starts the service, and the rescue
path's deadman lease covers pre-switch_root failures. Opt out with
`touch /etc/dc1/boot-watchdog.disabled`.

The board NTC thermal zones and the hall switch were added to the mainline
DTS (kernel `3d3de59a5`) and now take effect on every dtbswap boot.

**What landed 2026-08-22.** Four changes shipped without hardware proof, and two things were measured live. In the kernel (commit `a2c27ab3bff1`, pinned the same day at linux pkgrel=28): every LVTS die zone gains a 105 °C hot trip, and the two board NTC zones gain their first-ever trips plus 2 s polling — compile-checked only, not yet booted on hardware. In the device package (pkgrel=57): the speaker-labeling UCM2 profile plus a WirePlumber profile override, parse-validated on-device but never executed through UCM on hardware. And the ambient-light part at i2c1 `0x49` received an identification dossier — MEMSic-family `mn29xxx` per the board's own SCP firmware strings, exact part unverified, node still undeclared. Later the same day, the dead pen was root-caused — `CONFIG_TOUCHSCREEN_WACOM_W9000` had never been enabled, so the DTS digitizer node sat unbound — and kernel `e2836cc1dcb4` (pinned at linux pkgrel=29) builds the mainline driver in; see Pen digitizer. Measured live the same day on the running pkgrel=27 build: microphone capture works over the codec's DMIC path (see Audio), and the 2026-08-20 cpufreq/LVTS-trips/GPU-cooling commits are all active (see Thermal). Checklists for the next hardware session close this page.

## GNOME on fresh installs: the verified-minimal shim set (2026-08-19)

A fresh install of this image could not start GNOME: the pmOS systemd
repository is mid-way through its GNOME 50 migration, so the image mixes
Alpine's gdm 48.0-r7 with pmOS's gnome-shell-mobile 999948.0-r4 and the pmOS
accountsservice fork. An on-device session established the exact minimal fix
set — GNOME up, clean reboot, zero failed units — and this repository now
codifies all five pieces so every fresh install gets them:

1. **libelogind → libsystemd shim** (installer provisioning,
   `apply_libelogind_shim`). Alpine's gdm links `libelogind.so.0`, and real
   elogind 255.24's session parser fails on systemd cgroups — gdm logs
   "Session never registered" and no session ever reaches the display.
   `/usr/local/lib/libelogind.so.0` is a symlink to `/lib/libsystemd.so.0`.
2. **musl loader path** (same function). `/etc/ld-musl-aarch64.path` lists
   `/usr/local/lib` before `/lib` and `/usr/lib`; without it the dynamic
   linker's default search order finds the real libelogind first and the
   shim never wins.
3. **Wayland-only gdm** (installer provisioning, `apply_gdm_wayland_only`).
   `WaylandEnable=true` + `XorgEnable=false` in `/etc/gdm/custom.conf`,
   with the packaged autologin block preserved. Otherwise any session
   failure falls back to an X11 greeter on an image that ships no Xorg and
   no X11 session files — SIGABRT until start-limit-hit.
4. **Accelerometer-driven orientation** (device package, pkgrel 56). Static
   GNOME and Sway 180° transforms were removed: they overrode the MC3416
   orientation reported through `iio-sensor-proxy`. The device package now
   also installs `gnome-settings-daemon-mobile`, which supplies the desktop
   orientation consumer. A device polkit rule permits the active `dc1` GNOME
   session to claim the accelerometer; without that, SensorProxy rejects the
   claim and reports orientation as `undefined`. The panel's physical scanout
   correction is supplied by the compositor's live sensor orientation, not a
   fixed monitor file. The device orientation bridge runs as a persistent
   user service and requests the compositor-owned rotation transition from the
   patched Mutter-Mobile package, avoiding a visible hard snap during rotation.
5. **accountsservice pin** (rootfs build, `scripts/build-rootfs.sh`). The
   pmOS fork `accountsservice-999923.13.9` ships a typelib referencing
   `libaccountsservice.so.0` while the installed gdm/gnome-shell link
   `.so.1`, so the shell's JS init throws. The build writes
   `accountsservice<999` + `libaccountsservice<999` into `/etc/apk/world`,
   which selects Alpine edge (26.27.3, the hardware-verified version) and —
   because world constraints are sticky — survives on-device `apk upgrade`.
   Temporary until the fork's typelib matches its library soname.

The shims themselves are hardware-verified; their delivery through the
installer and the rootfs build has not yet been exercised end-to-end on a
device. Two known risks:

- the gdm greeter path (the `gdm` user's own Wayland session) was observed
  once aborting with "no session desktop files installed" — after a user
  rename or a logout the greeter may still be broken even with the set
  above applied;
- screen orientation after removing the static transforms still needs a
  physical tilt test on hardware.

**What the switch would cost, audited 2026-08-17.** Every device with a driver
bound on the running (stock) tree was mapped back to its DT node and checked
against the built `mt8781-daylight-jagar.dtb`. Most of the 341 compatible
strings that differ are vendor-BSP nodes no mainline driver claims, and most of
the rest are naming differences for the same hardware — the stock tree's
`mediatek,mt6983-i2c`, `mediatek,disp_ovl0`, `mediatek,mt8781-sd` and
`mediatek,mt6366-keys` are our `mediatek,mt6789-i2c`, the mainline display
components, `mtk-msdc` and `mediatek,mt6358-keys`. The display bias regulator
that the diff also flags (`tps65132`) is present as `regulator@3e` with the
`ti,` prefix mainline requires. Only **two** bound devices would genuinely
disappear:

- **the hall switch** (`soc:odm:hall`, `gpio-keys`/`hall-switch`, `input2`) —
  live today and one of the board's enabled wakeup sources;
- **the two board NTC thermal zones** (`generic-adc-thermal`, `thermal-ntc1`
  and `thermal-ntc2`) — today the only thermal zones that read at all.

Both should be added to the mainline DTS before the switch, or it is a net
regression on those two.

✅ works on hardware &nbsp;·&nbsp; 🟡 partly working, with a known limitation
&nbsp;·&nbsp; 🚧 being worked on, not usable yet &nbsp;·&nbsp; ⬜ untouched

| Component | Status | Notes |
| --- | --- | --- |
| Display | ✅ Works | DSI panel; Wayland sessions (Sway, GNOME) run. Blank/unblank works: a DPMS off stops the pipeline at the proven boundary and a DPMS on replays the handoff (`production power sequence complete` → `first DSI frame complete`) in ~0.6 s, verified on device 2026-08-16. The frontlight is not the panel's DRM backlight — our mainline DT has no panel node, so DRM exposes no `panel orientation` property and no backlight phandle — so `dc1-screen-backlight` mirrors the connector's DPMS state onto both RT4539 `bl_power` files; without it a blanked panel stays evenly lit and reads as a wedged display. |
| GPU | ✅ Works | Mali-G57 MC2 via Panfrost, **now native on the mainline DT** (verified 2026-08-19): kernel `981870b` enables the dtsi `gpu` node at the proven 390 MHz / 850 mV point, panfrost binds at t=6.8 s from cold boot with no overlay and no probe poke, `renderD128` exists before the session starts, and gnome-shell logs `Created gbm renderer` (no llvmpipe). GPU devfreq cooling now binds through the LVTS ts3-0 map since kernel `0f6e730c92d6` (2026-08-20), live-verified 2026-08-22 — see Thermal. The overlay path below remains for stock-tree boots. `dc1-gpu` used to report failure while the GPU worked anyway: applying the runtime overlay only edits the live tree, and the platform device for the newly-enabled `mali` node is registered after that, so the `drivers_probe` poke issued straight after `modprobe` hit an empty platform bus and got `ENODEV` (measured 2026-08-17 at t=4.98 s; panfrost then bound at t=15.17 s off the kernel's own deferred-probe timeout). A red unit costs the ordering guarantee that gdm → mutter starts with a render node, so the poke is now retried until `renderD128` appears. Panfrost's old `Failed to register cooling device` log dates from when there was no thermal zone to bind to; the 2026-08-20 LVTS trips/maps fixed it (devfreq cooler live 2026-08-22) — see Thermal. |
| Touchscreen | ✅ Works | ILI2910, 10-point multitouch. |
| Pen digitizer | 🟡 Built, unverified | Wacom EMR digitizer on i2c9 `0x09` (`wacom,w9007a-lt03`), driven by the mainline `wacom_w9000` driver. The dead pen was root-caused 2026-08-22: the DTS node has been present all along (it registers as `9-0009` on the live tree), but `CONFIG_TOUCHSCREEN_WACOM_W9000` was never enabled in `jagar_defconfig`, so no driver bound — no input device and not one dmesg line. Kernel `e2836cc1dcb4` (linux pkgrel=29) builds it in next to the ILITEK option; probe itself is self-contained (enables the 1 V8 rail ~200 ms, runs a query handshake, parks the rails again until a reader opens the device). Everything past compile-check is unverified on hardware: whether the query answers, IRQ level-low on GPIO9, coordinates/range versus the glass, and which firmware variant this panel really carries — `w9007a-lt03` is the starting guess; if probe logs `Failed to query` or reports nonsense, try `wacom,w9007a-v1` then `wacom,w9002`. First-boot checklist below. |
| On-device UI | 🟡 Works, with local shims | Installer: touch UI (`dc1-ask`) drawn by PID 1, hardware-verified to boot and serve its menu. Desktop: GNOME Mobile on the panel, hardware-accelerated via Panfrost. **Currently held together by device-local shims** (restored 2026-08-19 after a day-long outage): the decisive one redirects `libelogind.so.0` to `libsystemd.so.0` — Alpine's gdm links elogind's client library, whose session parser returns garbage on a systemd cgroup layout, so gdm could never match a session to a display. Around it: a 48-era gjs/mozjs/ICU shadow stack under `/usr/local/lib` (edge's gjs 1.88 segfaults the 948 mobile shell), a pinned gnome-session 48, a hand-supplied `org.gnome.Shell.target` user unit, Wayland-only gdm (`XorgEnable=false`; no Xorg exists to fall back to), a gdm drop-in that waits for a DRM connector (gdm races mediatek-drm at boot; the card0/card1 order flips between boots and mutter's builtin-panel heuristic copes), and display-manager restart caps (a 1s-restart session crash-loop once starved the whole machine). Full inventory + removal conditions live in the private bench HANDOFF; all of it comes off once pmOS's systemd repo ships a coherent GNOME-50 mobile set (mid-migration as of 2026-08-19: session 999950 + shell 999948 + an uninstallable gdm 999950). The verified-minimal subset is now codified for fresh installs — see "GNOME on fresh installs" above. |
| Frontlight | ✅ Works | Dual RT4539 backlight drivers: `lcd-backlight` (white, i2c-5) and `lcd-backlight-amber` (amber, i2c-2). GNOME binds exactly one backlight device to the internal display — `gsd-power` takes the first `firmware` > `platform` > `raw` match, which is always the white one — so its Settings slider drives white alone. The amber channel gets its own quick-settings slider from the `dc1-warmth@denv.it` shell extension shipped in the device package: it holds amber at a chosen share of the white level, so it behaves as a colour temperature and the tint survives brightness changes. Writes go through logind's `Session.SetBrightness`, no root needed. |
| Power key | ✅ Works | Opens GNOME's power menu (restart / power off). It does **not** blank: gnome-shell-mobile grabs the key as a mutter keybinding — so logind's `HandlePowerKey=ignore` never applies — and its `powerManager.js` maps `power-button-action='nothing'` onto `'blank'`, so `'interactive'` is the only value that avoids a screen-off. Blanking itself is recoverable (press again), but the shell re-blanks a woken screen after a hardcoded 10 s whenever the screen shield is up, which is why `lock-enabled` is shipped false. |
| Wi-Fi | ✅ Works | MT7902 via mainline mt7921s, **on the mainline device tree**, cold-boot verified 2026-08-19: `mmc1` enumerates the chip at SDR104 at t=2.7 s, firmware loads from the system initramfs, `wlan0` associates at t=14 s with the provisioned credentials, and Tailscale comes up. Three fixes got it there after the dtbswap switch dropped the signed dtbo that used to enable it: the host node itself (kernel `231fa88`), the MSDC1 pad rails VCN18/VMC that vendor `vioa/viob-supply` powered and mainline mtk-sd does not (kernel `0c26bee` — with them off, pads muxed and card powered still read all-low), and the boot-time firmware race (pmos `0f63c60`, blobs staged in the initramfs the built-in driver reads at ~2.8 s). | Needs `CONFIG_FW_LOADER_COMPRESS_ZSTD` — linux-firmware ships the three MT7902 blobs `.zst`-compressed, and without it the loader reports `-2` for a file that is present, `hardware init failed`, and no `wlan0`. Carried by the pinned kernel since `ea54394`. |
| Bluetooth | 🚧 In progress | MT7902, same upstream firmware — but it did **not** work on any real boot, and the earlier "Works" here was wrong. `btmtksdio` is built in (`=y`), so it probes as soon as the SDIO function is enumerated, measured at t=1.75 s: before the root filesystem carrying `/lib/firmware` exists. `mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin` comes back `-2`, btmtk gives up with `Failed to setup 79xx firmware (-2)`, and `hci0` stays registered but never completes setup. Nothing looks broken — `/sys/class/bluetooth/hci0` and the rfkill switch are both present — while `bluetoothctl` answers `No default controller available`. The Wi-Fi half of the same chip survives the identical race only because mt7921s retries the load itself; btmtksdio makes one attempt. Confirmed by hand on 2026-08-17: one unbind/bind of `mmc1:0001:2` completed setup in 2.75 s and brought the controller up as `Daylight DC-1`. `dc1-bluetooth` (device pkgrel=34) does exactly that, ordered before bluetoothd. **Cold-boot verified 2026-08-17** at kernel pkgrel=24 / device pkgrel=38: the unit entered active 13 s into a boot that reached `graphical.target` at 17.9 s, and `bluetoothctl show` reports the controller up as `Daylight DC-1` with no manual intervention. Left In progress only because pairing and an audio profile (A2DP over the new sound card) have not been exercised. |
| USB gadget | 🚧 In progress | Serial console works (`/dev/ttyGS0`, `ttyGS1`); USB ethernet and SSH over USB did **not**, and the earlier "Works" here was wrong. `dc1-usb-gadget` reused the gadget the initramfs leaves behind on the assumption that it is "identical" to the one it builds. It is not: on a plain (non-installer) boot the handed-off `g1` carried `acm.0` and `acm.1` and no `ecm.0` at all (observed 2026-08-17), so rebinding the UDC produced the two ACM ttys and never a `usb0`. The service still reported success, because the wait for `usb0` ran in a background subshell that `exit 0`-ed when the interface was missing. Both are fixed in device pkgrel=34: the existing tree is completed in place (`ensure_ecm`) before the bind, and the `usb0` wait is in the foreground and fatal. Verified on device by reproducing the handoff state (UDC unbound, ACM-only tree) and running the new script: `ecm.0` was added and `usb0` came up at 172.16.42.1/24. It must be the **only** UDC owner: `usb-signaller` (from `postmarketos-usb-moded`) starts afterwards, cannot classify our functions, tries to switch the UDC to its own gadget, and wedges in configfs; the device package masks it and its three mode units. **Teardown is gone**, deliberately — see the next row. |
| configfs teardown | ✅ Resolved | The gadget teardown used to unbind the UDC, unlink the functions, then `rmdir` bottom-up, on the theory that the uninterruptible hangs came from removals arriving out of order. They do not. Measured on hardware 2026-08-17: with the UDC cleanly unbound, every function unlinked from `c.1`, the configs already removed, and **no process holding `/dev/ttyGS0` or `ttyGS1` open**, `rmdir functions/acm.0` still entered D state and stayed there. It cannot be signalled (`SIGKILL` was ignored), so the mount is wedged for the rest of the boot, and because it holds the parent directory's lock every later configfs access blocks behind it — a plain `find` over `usb_gadget/` hung immediately. That is the same wedge previously blamed on `usb-signaller`'s removal order, and it is what fails the suspend freezer, since a D-state task can never be frozen. So nothing removes gadget objects any more: `stop` unbinds the UDC and leaves the tree standing, and `start` reuses and completes it. Rebuilding the tree, if it is ever actually needed, means a reboot. |
| Internal storage | ✅ Works | UFS. |
| Battery | 🟡 Partial | Real current, charge and state of charge, from the MT6366 PMIC's FGADC coulomb counter (`mt6358-fg`) — it measures pack current through the sense element and integrates it in hardware. Verified on device 2026-08-16: capacity held at 32% across idle → 8 cores busy → idle while `current_now` tracked -126 → -245 → -128 mA, and charge integration came within 1% of the measured current over 60 s. Caveats: the state of charge is seeded from open-circuit voltage at boot (so it is re-seeded on every reboot) and measured against *design* capacity, since nothing here learns a real full-charge capacity. The pack's BQ78Z100 — which does all of that properly and persistently — still does not answer: every `bq27xxx-battery` read of `7-0055` returns `-ENXIO`. The bus is not the problem: the RT9471 at `0x53` on the same i2c-7 replies, a full scan finds only `0x53`, `0x55` NAKs both read and write addressing across 60 retries, and the bus measures 49.2 kHz against the 50 kHz the DT asks for. The vendor 5.10 tree was compared line by line — same bq27xxx glue, same pad tuning (RSEL_111 1k pull-up, applied and read back in hardware), byte-identical pinctrl rsel tables, equivalent controller quirks and AC timing — so nothing in software distinguishes us from the kernel that read `capacity 100` from that address. `mt6358-fg` stands aside automatically if the pack gauge ever reports `present=1`. Tracked as P7.1, now a hardware item: the pack connector's SMBus pair, or the gauge's own I²C block. **Charging was found not to work on 2026-08-21** — plugged in at 11%, the coulomb counter lost ~10.3 mAh over 150 s (−248 mA net) because the MT6375's input-current limit sat at the bootloader's static 500 mA and nothing negotiates a higher one: there is no Type-C/PD or BC1.2 driver on this platform (no `typec`, no extcon), so the charger never learns what the source can do, the whole input budget feeds VSYS under desktop load, and the pack subsidises the rest. The driver's `status="Charging"` only ever meant *charge-enable bit set + VBUS good*, which is why this hid behind a green-looking sysfs. Verified live over `/dev/i2c-5`: raising CHG_AICR 500 → 2000 mA flipped the pack from −250 mA to +233 mA immediately, reproduced across an A/B cycle of the same register, and pushing to 3000/3175 mA gained nothing more — the ~600 mA input ceiling observed is the adapter, not the limit. Kernel `4fde6edeac00` (pkgrel=21) renames the read-only telemetry driver to `mt6375-charger` and gives it one job beyond telemetry: raise CHG_AICR from the bootloader's 500 mA to 1.5 A once VBUS appears (one-shot poll; the 4.5 V MIVR regulation folds back if a weak source sags), plus a writable `input_current_limit` property for userspace override. Charge enable, watchdog, interrupts, and constant-charge current/voltage stay untouched — those are cell-level settings whose normal enforcer (the BQ78Z100) does not answer here. Status stays 🟡 until a boot of pkgrel=21 shows the raised limit end-to-end. **The fuel gauge itself was then found to under-report by almost exactly 2× (2026-08-21, ten-agent investigation + differential referee test):** the homegrown `mt6358_fg` transcribed MediaTek's FGADC LSBs (381.47 µA/current count, 190.735 µAs/charge count) without the vendor's per-board correction ×`DEFAULT_R_FG/r_fg_value` — and this board's factory configuration is a **5 mΩ shunt with a 1.01 charge trim**, proven from two artifacts on the unit itself: the factory gauge node in `vendor_boot_a` (`R_FG_VALUE=<5>`, `CAR_TUNE_VALUE=<101>`) and the stock kernel's own boot log preserved in `expdb` (`r_fg=50 car_tune=1010 DEFAULT_RFG=100`). Stepping the charger's ICHG target 500→900→500 mA gave dI(chip IBAT)/dI(FG) = **2.02**, and doubling reconciles every earlier anomaly — idle is really ~267 mA, eight spinning cores ~534 mA, and the discharge/charge numbers quoted above were all half-truths (the −250 mA discharge was ~−500 mA; the +233 mA plateau ~+466 mA; the 2026-08-16 "verified within 1%" check was circular, both sides sharing the missing factor). Kernel `d8ed2cdfd537` (pkgrel=22) applies the vendor correction as module parameters (`mt6358_fg.r_fg_milliohms=5`, `car_tune_permille=1010` — module params because the signed `lk`/`dtbo` cannot carry DT tuning), halves the pack-resistance estimate that had absorbed the same factor, and exposes raw latch counts at `.../power_supply/mt6358-fg/fgc_raw`. True charge behavior after the AICR fix: **~440 mA at the 500 mA target, ~880 mA if ICHG is raised to 900 mA — roughly 5–11%/h on the 8 Ah pack, roughly double what the gauge used to claim.** Residuals kept honest: the shunt was never ohmmetered (a constant-ratio board bypass would look identical remotely; read the marking at next power-off), and the ~13% gap between chip IBAT and the nominal ICHG target is unexplained. **Fast charge then became the default (kernel `6a12a0831485`, pkgrel=23):** stepping the ICHG target 500→1500→2000→2500 mA on hardware measured the pack taking 1.46 → 1.8 A while the input pinned at ~1.85 A with VIN sagging 5.0→4.78 V and the junction at only 34 °C — the wall adapter, not the device, is the ceiling. The VBUS one-shot policy now raises the fast-charge target to 2 A alongside the 1.5 A input limit, and `constant_charge_current` joined `input_current_limit` as writable sysfs, so the observed ~1.8 A (~22%/h, 0→80% in under 4 h) needs no manual register writes; a weaker source simply yields less through the MIVR foldback. **USB-C PD then came up (kernel `5e36dfcd3193`, pkgrel=24):** the MT6375's TCPCI bank at i2c-5 `0x4e` (Richtek VID `0x29cf`, PID `0x6375`) turns out to be a plain TCPCI controller that the bootloader had already left presenting Rd — which is why PD adapters were applying vSafe5V all along with nobody home to talk PD to. A new `tcpci_mt6375` driver runs the generic TCPCI/TCPM stack over it: vendor PHY/timing patch from the BSP driver, a software-node connector (the signed bootloader DT describes neither the bank nor an interrupt line) declaring sink-only fixed PDOs of 5 V/3A, 9 V/3A and 12 V/3A — everything above stays out because the charger's OVP buckets top out at 14.5 V — and alert polling at 15 ms instead of an IRQ. Settled contracts flow through TCPM's per-port power supply into the charger: OVP bucket above the contract voltage, MIVR 800 mV under it, AICR at the contracted current. Expected with a real PD adapter at 9–12 V: up to ~27 W in, pack branch hitting its 3.15 A ICHG ceiling ≈ **35–40%/h**. First boot of pkgrel=24 verified everything *except* PD: boot chain + slot fallback machinery clean, charge policy auto-applied at probe, calibrated gauge took the pack from ~15% to 99% overnight — but `/sys/class/typec` never appeared, because `CONFIG_USB` had never been set (only `USB_GADGET`), and `TYPEC_TCPM depends on USB`, so syncconfig silently dropped TCPM, TCPCI, and the MT6375 driver down the dependency chain. pkgrel=25 sets `CONFIG_USB=y` (kernel `55509d09d028`; musb becomes dual-role as a side effect) and is the first build where the Type-C stack actually ships. Still pending hardware verification: port appearance, contract formation under polling latency, 9 V transition. |
| Suspend/resume | 🟡 Partial | **A full s2idle cycle completed on 2026-08-19** (mainline DT): `echo mem` entered s2idle, the device woke (RTC alarm armed as backstop; a USB-gadget wakeup likely fired first), and `PM: suspend exit` returned rc=0 with the freezer clean. One wart: mt7921s failed its resume callback with -EIO, then mac80211 re-authenticated by itself ~2.5 s later and Wi-Fi came back with the same address — annoying, self-healing, unfixed. Panel state after resume not yet observed by a human. The sleep targets stay **masked** — unmasking trades remote reachability for battery and is an owner decision, now an informed one. The history: s2idle used to abort with `Freezing user space processes failed after 20.001 seconds (2 tasks refusing to freeze)`, twice per attempt, returning with the panel dark. Root-caused on 2026-08-16: the unfreezable tasks are not a suspend bug at all but `usb-signaller` stuck in `unlinkat(…, AT_REMOVEDIR)` on configfs (see USB gadget above), plus whatever later touched configfs and inherited its D state — an uninterruptible task can never be frozen. Masking `usb-signaller` removes that particular offender, but the 2026-08-17 teardown measurement (see the configfs row) shows the wedge is not specific to it: **any** `rmdir` of a gadget function object goes to D state, so the freezer would have kept failing for whoever ran one. Removing teardown entirely takes the blocker out for good. **The freezer is now fixed and measured.** `CONFIG_PM_DEBUG=y` (kernel pkgrel=22) brings `/sys/power/pm_test`, which stops the suspend sequence after freezing without touching devices — so the freezer can be exercised with the panel lit and no dark-screen recovery risk. Run on hardware 2026-08-17 at kernel pkgrel=24 (`echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state`): `Freezing user space processes completed (elapsed 0.003 seconds)`, `Freezing remaining freezable tasks completed (elapsed 0.002 seconds)`, held 5 s, `Restarting tasks: Done`, `PM: suspend exit`, return code 0. Against the previous failure — 20.001 s timeout, twice per attempt — that is the configfs teardown removal doing exactly what it was predicted to do. What remains is the rest of the sequence: `pm_test` escalates through `devices`, `platform`, `processors`, `core`, and only `core` is close to a real `mem`. Those levels do suspend devices, so the panel goes dark; the safety net is that this board has an **RTC wakealarm** (`/sys/class/rtc/rtc0/wakealarm`, an `rtc-s35390a` at i2c-8 0x30), so a timed wake can be armed before the attempt and the device comes back on its own even if nothing else can wake it. Other enabled wakeup sources today: the hall switch, the touch controller (`5-0034`), the USB gadget, and the MT7902 SDIO function. The sleep targets stay masked until a full cycle is observed. |
| Audio | ✅ Works | **Both speakers, correct L/R, balanced — hardware-verified 2026-08-20 — and microphone capture verified 2026-08-22.** The board mic is a digital DMIC microphone wired to the MT6366 codec: 5 s recorded from `hw:0,9` (`Capture_1`/UL1 front end) peaked at −29 dBFS broadband with zero mixer changes, and a control experiment flipping `Mic Type Mux` off DMIC recorded exact digital silence, proving the signal originates in the DMIC front end (`mt6358_dmic_enable` ran for exactly the capture window). There is no jack detection anywhere — zero `snd_jack`/`snd_soc_jack` registrations in codec or machine driver, no accdet platform device, no headphone switch in the input devices — so headset detect cannot work and there is no analog headset mic. Speakers took four kernel fixes from "dummy output": **power domain** — the AFE must attach `power-domains = <&spm MT6789_POWER_DOMAIN_AUDIO>` (`100b7a8c7`, pkgrel 16); without it the card probes but `hw_ptr` never advances and playback underruns to silence. **Right channel** — HPL → line-out buffer feeds the left speaker, HPR → DAC-R the right, and DAC-R must be powered up (`AUDDEC_ANA_CON0` = `0x30ff`, not mainline's `0x30f9`; vendor-matched `9c9f6ead`, pkgrel 17). **Balance** — the left channel rides two gain stages, so both channels ride the `Headphone` master gain (+8 dB, value 18; device pkgrel 48) and since `e1a31d1` (2026-08-20) Lineout adds a +2 dB trim (value 12, superseding the unity/value-10 pin recorded here before). **Channel swap** — the board wires HPL to the *right* speaker and HPR to the *left*, so the codec's downlink swap bit `AFE_DL_LR_SWAP` is set on the loudspeaker path (`586fc14`, pkgrel 20); the dead HPL re-mux alternative was reverted. The DAPM routing is applied at startup by `dc1-audio` via amixer. **Speaker-labeling fix packaged 2026-08-22, not yet verified on an installed system (device pkgrel=57):** the package now ships a real UCM2 profile (`conf.d/mt6789-mt6366/mt6789-mt6366.conf` + `HiFi.conf`; the explicit `File` include is mandatory — UCM auto-scan does not work on alsa-lib 1.2.16) whose EnableSequence mirrors `dc1-audio`'s proven amixer sequence (Headphone 18,18 / Lineout 12,12 / ADDA_DL_GAIN 65535), plus a WirePlumber `wireplumber.conf.d/55-dc1-audio.conf` fragment setting `wireplumber.profiles.main.hardware.audio=required`, overriding pulseaudio-wireplumber's audio-disabled default by later lexical merge order. Validated only to open/parse on-device (`alsaucm -c hw:0 list _verbs` → HiFi against installed alsa-lib 1.2.16); on the first install carrying pkgrel=57, ACP adoption should replace the bogus `analog-output-headphones: Headphones` port with `[Speaker] Speakers` (checklist at the bottom of this page). `PlaybackPCM hw:${CardId},0` assumes `pcmC0D0p Playback_1` is DL1 — confirm once with `speaker-test -D hw:0,0 -c2`. **Gain-clobbering race still open:** `/var/lib/alsa/asound.state` stores zeros, and on 2026-08-22 the live card read `Headphone`/`Lineout` = 0,0 despite `dc1-audio.service` active and ordered `After=alsa-restore.service`; UCM verb-enable will re-apply the gains whenever ACP adopts the profile — mitigated, not fixed. Bluetooth A2DP remains unexercised, and `hardware.bluetooth` stays disabled by the same stock WirePlumber fragment. |
| Sensors | 🟡 Partial | **Accelerometer works on the mainline tree** (verified 2026-08-19, re-measured 2026-08-22): `iio:device0 name=mc3416` reads a clean 1 g vector and `iio-sensor-proxy` reports `HasAccelerometer: true` with a live orientation property. **The hall switch is in the DTS** — kernel `3d3de59a5` (2026-08-18) added it as vendor-compatible `hall-switch` backed by `drivers/input/misc/hall-switch.c` (deliberately not gpio-keys), interrupt `&pio 1 1`, `CONFIG_INPUT_HALL_SWITCH=y` — live today as `input2`/event2. This corrects the stale claim repeated at the tail of earlier revisions that the hall switch was AP-wired but absent from the DTS. The desktop chain ships complete: the SensorProxy D-Bus activation file (device pkgrel=34, fixing Alpine's policy-only aport), the polkit claim rule for the `dc1` user, gnome-settings-daemon-mobile, and the persistent `dc1-orientation` user bridge (active on 2026-08-22). One measured gap from that session: mutter-mobile's orientation manager never claimed the sensor on the observed boot, so rotation currently runs bridge-driven as an instant flip, and whether the patched-Mutter animated transition ever engages is unknown — **the physical tilt test has still never been performed** and remains the last unverified link (checklist at the bottom of this page). **ALS identification documented 2026-08-22, node stays undeclared:** the ambient-light/proximity part at i2c1 `0x49` (GPIO132/133) is pinned only to family level — the board-specific tinysys SCP sensorhub firmware read from this device's own UFS names its sole ALS/PS driver family `mn29xxx` beside standalone `memsic` (MEMSic) strings, which also positively exclude stk/tmd/apds/ltr/epl candidates. A same-day live probe (bit-banged through `/dev/gpiochip0` with nothing driving the SCP) found exactly one ACKing device at `0x49`, but it NAKs every write-data byte and returns constant bytes — no register protocol reachable, hence no ID-register read, hence no exact part number and no basis for a driver candidate; the kernel tree carries no driver for any MN29 part. Caveat: the probe ran before any SCP initialization, so AP-side behaviour may differ once that domain runs — do not conclude the part is broken from AP probes alone. Still no gyro or magnetometer. History: both sensor buses hang off the SCP, but their pin pairs are dual-function and nothing drives the SCP (no mainline driver binds `mediatek,mt6789-tinysys-scp`), so the AP takes them — measured 2026-08-16 by re-muxing and bit-banging GPIO142/143 (i2c6, the MC3416 at 0x4c) and GPIO132/133 (i2c1, the 0x49 part); the original "needs a mainline SCP/sensorhub bring-up" claim stands retracted. Kernel `d8b24985b` (i2c6 + `accelerometer@4c`), `c4dc49faa` (`mcube,mc3416` 16-bit registers) and `e77962ed3` (defconfig) carried since pkgrel=22. |
| Thermal | 🟡 Partial | **Trips, cooling maps and CPU DVFS all exist now** — kernel `0f6e730c92d6` (LVTS trips + cooling maps), `ffc87512c0e2` (cpufreq-hw MT6789 variant) and defconfig `504b45c64ba0`, all 2026-08-20 and all in the pinned pkgrel=27 build running on 2026-08-22: live, nine of the thirteen LVTS zones carry passive 85000/hyst 2000 plus critical 113500 trips (`lvts-ts3-1/-ts3-2/-ts3-3/-ts4-0` critical-only), three cooling devices are registered (`cpufreq-cpu0`, `cpufreq-cpu6`, and a GPU devfreq cooler bound through the ts3-0 map), and DVFS is up (`scaling_driver=mtk-cpufreq-hw`, schedutil; policy0 = cpu0-5 at 500-2000 MHz, policy6 = cpu6-7 at 725-2200 MHz; power-allocator governor active). That closes the long-recorded "no trips, no cooling maps, no cpufreq at all" thermometer era. The DVFS design is deliberately regulator-free: MCUPM firmware owns the MT6366 vproc/vsram_proc rails and publishes the LUT/energy-model tables, and the kernel writes perf-state indexes only — the classic mediatek-cpufreq OPP/voltage route must not be attempted (no upstream mt6789 entry exists, and the vendor voltage tables live inside MCUPM firmware). **Landed 2026-08-22 in kernel `a2c27ab3bff1`, pinned at linux pkgrel=28, not yet booted**: every LVTS zone gains a 105000/hyst 8000 `hot` trip inserted before its existing critical in `mt6789.dtsi` (hot is notification-only — netlink/uevent; the dtsi change also applies to the emerald board that shares it), and the two board NTC zones gain their first-ever actuation capability: polling-delay/-passive raised 0→2000 ms plus `hot` 85000/hyst 5000 and `critical` 110000/hyst 2000 each (`generic-adc-thermal` has no IRQ path, so at polling 0 they could never evaluate any trip). Values follow the vendor policy extracted read-only from this device's authenticated partitions: stock DT carries no CPU trips at all (stock throttling is userspace-driven), one GPU passive stage with a devfreq map, and criticals at exactly 113500 everywhere — all preserved untouched. Validated by preprocessing + compiling the board DTS (exit 0; five pre-existing warnings, none thermal); the same-day pin bump (linux pkgrel 27→28) makes CI rebuild instead of silently reusing the cached package. Two honest risks: the NTC critical has no debounce — a single garbage ADC sample converting to ≥110 °C starts an immediate ordered poweroff (`CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0`) — and the four polling-0 LVTS zones rely solely on the LVTS hardware threshold IRQ. Kept history: LVTS reading verified 2026-08-19 (fuse calibration base `0x1a4` versus the vendor DT's misaligned `0x1b4`; no manual RCK needed, and the driver still refuses manual-RCK paths with `-EOPNOTSUPP` until that takeover is separately accepted); the NTC zones used to fail registration with `-ENODEV` until kernel `981870b` moved the shadowing dtsi `thermal-zones` block from `/soc` to the root node; occasional empty LVTS reads remain uninvestigated; `bq78z100-0` still disables itself (`Unable to get temperature`). First-boot checks for the trip work are in the next-session checklist at the bottom of this page. |

## Next hardware session: checklists from 2026-08-22

Three changes shipped without hardware proof. When a build carrying them
first boots, check the following — nothing here writes a partition or touches
slots; run as `dc1` unless a step says otherwise.

**First boot carrying the thermal trips (any kernel newer than pkgrel 27).**
`grep . /sys/class/thermal/thermal_zone*/trip_point_*_type` should show
105000 `hot` points on all thirteen `lvts-*` zones and, on `ap_ntc` /
`ltepa_ntc`, 85000 `hot` plus 110000 `critical`. Read an NTC zone twice about
two seconds apart — it must now refresh (polling 2000 ms). Warming the board
toward a hot trip should surface a `THERMAL_TRIP_UP` uevent/netlink event
(hot notifies userspace only; it throttles nothing by itself). Treat the NTC
critical as armed: crossing 110 °C powers the device off immediately, with no
debounce. If the NTC zones still show zero trips, the build predates the
diff.

**Audio labels (device ≥ 57).** `ls
/usr/share/alsa/ucm2/conf.d/mt6789-mt6366/` must show `HiFi.conf` and
`mt6789-mt6366.conf`, and `alsaucm -c hw:0 list _verbs` must print `HiFi`.
As the logged-in user, `systemctl --user restart wireplumber.service`, then
`wpctl status`: the sink port should read `[Speaker] Speakers` instead of
`analog-output-headphones`, and played audio must reach the internal RT9101
speakers. Once per hardware, `speaker-test -D hw:0,0 -c2` confirms PCM 0
really is DL1 (the UCM assumes `PlayDevN=0`). If the wireplumber journal says
`UCM not available for card`, apply the fallback relabel rule
(`node.description="Speakers"`, matched on `alsa.card_name="mt6789-mt6366"`,
never the numeric index) and bump the device pkgrel again. While checking,
note the live `Headphone`/`Lineout` gains — they were caught sitting at 0,0
on 2026-08-22 despite `dc1-audio` being active.

**Pen digitizer (kernel ≥ pkgrel 29).** After boot,
`readlink -f /sys/bus/i2c/devices/9-0009/driver` must end in `wacom_w9000`
(no driver bound means the build predates the diff), and dmesg should carry
one probe line of the form `wacom_w9000 9-0009: Wacom W9007A LT03 Digitizer
size X…Y…` — probe runs at boot regardless of readers, powering the 1 V8
rail for its ~200 ms query window. Then hover and draw with a pen while
watching `libinput debug-events` (or `evtest`) for a new device named
`Wacom W9007A LT03 Digitizer`: expect `BTN_TOOL_PEN` on approach,
`ABS_X`/`ABS_Y` tracking the glass, pressure, and the side button. If probe
logs `Failed to query`, the variant guess is wrong before anything else —
try `compatible = "wacom,w9007a-v1"` then `"wacom,w9002"` in
`mt8781-daylight-jagar.dts` (bump linux pkgrel each time) before suspecting
wiring: measured i2c9 @11eb3000 addr `0x09`, IRQ GPIO9 level-low, reset
GPIO88 active-low, vdd = WACOM-1V8 (GPIO150), 3V3 rail always-on. If
coordinates land mirrored or rotated relative to the finger touch, that is
an axis/inversion fix via the DT's `touchscreen-*` properties, not a new
investigation.

**Rotation tilt test (never yet performed).** Sanity first:
`cat /sys/devices/platform/soc/1101a000.i2c/i2c-6/6-004c/iio:device0/name`
must read `mc3416`, `busctl --system get-property net.hadess.SensorProxy
/net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer` must read
`true`, and (root) `in_mount_matrix` should still read
`0, -1, 0; -1, 0, 0; 0, 0, -1`. If `/proc/device-tree/model` is wrong
instead, the stock DT booted and the dtbswap handoff needs inspecting — do
not reflash. Then hold each edge-up pose at least three seconds while
watching `AccelerometerOrientation` follow the physical quadrant (a natural
portrait hold is calibrated to read `bottom-up`). Expect paired journal
lines within about a second per tilt — iio-sensor-proxy's orientation emit
followed by `dc1-orientation: <label> -> transform N` — with content ending
upright and touch tracking in all four poses, and returning to the start
pose restoring the picture. An animated ~260 ms transition means mutter
finally claimed the sensor (then watch for double-apply races); an instant
snap with exactly one `ClaimAccelerometer` this boot means the bridge-only
path drove it and mutter's orientation manager is still dormant.

Not listed means untested or unknown. Status updates land here as the port
progresses; upstreaming to postmarketOS is the goal, so this table also
tracks what is left before the device can move out of
`device/testing`.
