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

Keep boot-image documentation aligned with `boot/dtbswap/README.md` and
`docs/installation.md`. Do not introduce a vendor_boot deployment path.

### USB-C data role

The single Type-C port is power-role dual and data-role dual, but tries sink
first: a PC keeps the installer/installed ACM+ECM gadget path, while a
charging hub can DR_SWAP MUSB to host and TCPM can request the MT6375 OTG
source. The source PDO is intentionally limited to 5 V/500 mA; functional
source-role operation was verified on 2026-09-18, while external VBUS-current
margin and thermal validation remain pending. The shared DTB must keep `dr_mode = "otg"`; reverting it to
`peripheral` removes the role switch. Keep the `g1` gadget driver bound in
host mode — the kernel disconnects D+ while hosting and restores it on return
to device mode. Never unbind it or remove configfs gadget objects to change
roles; `musb_gadget_stop()` kills the host engine and configfs removal can
wedge in D state.

MT6375 TCPM is the VBUS authority for both the charging-hub sink-host case and
the conservative source-role path. The
T-PHY's independent UTMI VBUS comparator remains at SessEnd even with a valid
PD contract, which makes MUSB raise `VBUS_ERROR` and prevents enumeration.
Keep jagar's opt-in `mediatek,force-vbus-valid` T-PHY property: it overrides
VBUSVALID/AVALID only in host mode and clears the override in device/OTG mode.
The jagar kernel is built with `CONFIG_MUSB_PIO_ONLY=y`; the MUSB host driver
must not advertise `HCD_DMA` in that configuration. The device has 8 GiB of
RAM, the MUSB child has a 32-bit DMA mask, and LK supplies
`swiotlb=noforce`. A false DMA capability makes usbcore needlessly map hub
status buffers and can reject the hub interrupt URB with `-EAGAIN`, leaving
later port changes invisible even though the initial hub scan succeeds.
The live register A/B on 2026-08-28 made the five-port USB 2.0 hub enumerate
at 480 Mbit/s while the Type-C power role stayed sink. That Lenovo 40B0
Thunderbolt dock exposed only its internal MCU and Billboard devices; its
otherwise powered downstream ports never asserted connection, including after
port-power and full-hub resets. Do not treat that session as keyboard/mouse
proof; close downstream enumeration with an ordinary USB 2.0-capable charging
hub.

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
Keep built-in FUSE, Landlock plus the BPF LSM dependency chain (including
securityfs and kernel BTF), uinput/uhid, and Bluetooth RFCOMM/BNEP. The GNOME
document portal, Tracker sandbox, systemd namespace confinement, remote-input
path, and BlueZ profiles otherwise fail independently after an apparently
successful boot. Alpine's usr-merged musl loader also needs the packaged
LocalSearch `LD_LIBRARY_PATH` drop-in: removing it makes every Landlock-confined
extractor exit 127. Unprivileged BPF must remain disabled by default.

The pack BQ78Z100 at i2c7 `0x55` does not ACK while the RT9471 at `0x53` on
the same bus does. Keep its production DTS node disabled: binding bq27xxx
only creates a phantom power supply, `-ENXIO` log spam, and a thermal zone
which disables itself. `mt6358-fg` is the calibrated battery fallback.
Re-enable the pack gauge only after a live ACK and protocol measurement.
The fallback's software charge anchor is restored by `dc1-battery-state`
only from a valid, single-use clean-shutdown record no more than ten minutes
old; every other boot keeps the driver's voltage-seed fail-safe.

The RT9471 is the factory secondary path in a dual-charger topology, but it
is not a free fast-charge switch. Keep `CONFIG_CHARGER_RT9471` unset and its
active-low GPIO151 CE parked high until a live session establishes its
VBUS/BAT/SYS routing, factory current-sharing policy, combined thermals, and
pack-temperature enforcement. The upstream driver's probe asserts both CE
and `CHG_EN`; enabling it blind could parallel two nominal 3.15 A chargers
while the BQ78Z100 protection/temperature monitor is unavailable.

The sensor buses are SCP-connected but reachable from the AP when the pins are
re-muxed; the SCP node is enabled with only its mailbox driver bound and the
core stays halted (wake requests time out), so no firmware owns the pins:

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

GPU min_freq is the first-frame smoothness knob (`simple_ondemand` always
wakes at the floor). Do not hardcode it in udev: `dc1-gpu-freq` is the
single writer, GNOME Settings → GPU is the experiment UI, and the last
choice persists in `/var/lib/dc1/gpu-freq.conf` — min/max only, the poll is
rewritten from the helper's `DEFAULT_POLL` on every apply. Shipped default
is the Super smooth preset at 812 MHz with a 40 ms poll; Smooth 700 MHz,
Balanced 545 MHz, and Power saver 390 MHz remain selectable. Thermal
devfreq cooling still caps from the top, and panfrost autosuspend keeps
the floor from costing idle power.

Keep `CONFIG_HIGH_RES_TIMERS=y` from kernel r57's `latency.config`. The
2026-09-12 trace found r56's GPU regulator/power-domain wake steps quantized
to 4 ms because high-resolution timers were disabled (HZ=250), accumulating
~100 ms stalls at all tested floors, including 1.1 GHz. Live timer resolution
was 4,000,000 ns. The fix preserves frequencies, HZ, electrical delays and
autosuspend. Post-boot r57 tests at a 700 MHz floor measured 100 ms idle-gap
p95 of 8.11–8.20 ms and maxima of 8.37–9.89 ms, with 1 ns reported timer
resolution. These are offscreen GPU measurements, not compositor FPS proof.
Compare idle-gap and continuous p95/maximum timing with `tools/performance/`,
not just throughput, before claiming a smoothness fix; see `docs/hw/display.md`.

The `1200x1600@120` mode is not free smoothness. Live CRTC vblank is
118.4 Hz with 62 lines / 0.31 ms of blanking (measured 2026-08-27);
KMS OVL planes cannot rotate 90°, so landscape is a GPU offscreen blit
and pinning Mali at 1.1 GHz does not turn that path into 120 FPS.
Window drag is worse: the CRTC keeps 118.4 Hz with missed_seq=0, and
mutter misses the deadline (~94 Hz tiny-fast, ~78 Hz large-fast at
812 MHz). Tiny-fast is compositor damage plus the landscape blit, not
GPU clock: 60 Hz still misses (~53 / ~43 Hz) with gnome-shell at ~20%
CPU. The shipped default stays 60 Hz. Device r84 defaults mutter
`kms-modifiers` on so Panfrost can use tiled intermediates for the blit.

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
- WirePlumber 0.5.15 `scripts/monitors/alsa.lua` concatenated a nil
  `node.name` when adapter bind fails (transient EBUSY on `hw:0,0`),
  which kills the ALSA monitor and leaves GNOME on Dummy Output. Do
  not fork that versioned script. `dc1-fix-wireplumber-alsa` reapplies
  a one-line `tostring()` guard from post-install/post-upgrade and from
  the apk trigger on the file, so a wireplumber upgrade cannot restore
  the crash. Alpine's current 0.5.16 ships those call sites guarded and
  was verified guarded on-device 2026-08-29 — the fix script no-ops on
  it; re-check its pattern at every WirePlumber bump rather than
  assuming the guard is obsolete.

Display/DSI invariants (measured 2026-08-24):

- **Kernel logs do not prove the panel is lit.** Short DCS writes complete
  host-side without a panel ACK, so the whole pipeline can report a clean
  power-on -- `production power sequence complete`, `first DSI frame
  complete`, frame-done IRQs -- while the glass is uniformly white. White
  is the resting state of this normally-white LCD with the backlight on
  and no drive.
- The only trustworthy liveness signals are the TE line on GPIO83
  (`gpiomon -c gpiochip0 83`; ~200 edges/2 s when the panel TCON runs, 0
  when it does not — root-only, `/dev/gpiochip0` is `crw-------`) and a
  DCS read of `0x0a`, where `0x9c` is
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
  corners). That extension also lifts the lock screen's unlock sheet clear
  of the on-screen keyboard by padding the parent of the unlock dialog's
  `_stack` (never the dialog's first child -- that is the background actor)
  by the OSK height while the keyboard is visible, which otherwise covers
  the sheet outright: the mobile shell puts the PIN pad below the password
  prompt inside the sheet, but hides the pad unless
  `Main.layoutManager.isPhone`, and the DC-1 can never
  satisfy that test at any sane display scale.

