# Display, GPU, and frontlight — measurement record

Deep-dive for the status-table rows *Display*, *GPU*, and *Frontlight* in
[docs/status.md](../status.md). This page holds the measurement history and
the invariants future changes must preserve; the table holds the current
verdict. Newest facts last inside each section.

## Panel and the DSI pipeline

DSI panel; Wayland sessions (Sway, GNOME) run. Blank/unblank: a DPMS off
stops the pipeline at the proven boundary and a DPMS on replays the handoff
(`production power sequence complete` → `first DSI frame complete`) in
~0.6 s. That log sequence was read as proof on 2026-08-16 and **was not** —
it printed identically while the glass stayed blank white. Root-caused
2026-08-24: `mtk_mipi_tx_pll_prepare()` **set** `DSI_SW_CTL_EN` on every
MIPI-TX lane. That bit parks a lane under software control and disconnects
its pad from the DSI controller, so it is the power-*off* semantic —
`phy-mtk-mipi-dsi-mt8183.c`, same IP block, clears it at power-on and sets
it at power-off. Boot never exercised the bug: LK hands Linux an
already-running PLL, so `prepare()` takes its `RG_DSI_PLL_EN` early return
and never reaches the gate writes, meaning the kernel's own cold path had
never once lit this panel. Any DPMS off/on cycle ran it, killed the lanes,
and transmitted the panel's DCS init sequence into the void, leaving the
panel asleep behind a lit backlight — a uniformly white normally-white LCD,
with every log reporting a clean power-on. The driver also wrote D2 twice
instead of touching the real D3 block at `0x0544`, harmless only while the
sense was inverted. Fixed in kernel `2466a7f6` (linux pkgrel=37), first
confirmed in place through `/dev/mem` pokes, then **hardware-verified on
the booted r37 kernel 2026-08-24**: two full DPMS off/on cycles through the
untouched driver paths — unprepare parks all five lanes (including D3 at
`0x0544`), prepare clears them, and the panel comes back every time with TE
at ~230 edges/2 s, DCS `0x0a` reading `0x9c`, and DSI error count 0 at the
driver's own 772.5 Mbps. The power key now blanks and wakes reliably.

### Ground truth for display work

**Kernel logs do not prove the panel is lit.** The only trustworthy
liveness signals are:

- the **TE line on GPIO83** — `gpiomon -c gpiochip0 83`, ~200 edges/2 s
  when the panel TCON runs, 0 when it does not; and
- a **DCS read of `0x0a`**, where `0x9c` =
  booster|sleep-out|normal|display-on.

Short DCS writes complete host-side without a panel ACK, so the whole
pipeline can report a clean power-on while the glass is uniformly white
(the resting state of this normally-white LCD with the backlight on and no
drive). Verify display work against TE/DCS, never against dmesg. A DCS
read that times out latches the DSI handoff state machine into its failed
phase, and the pipeline then refuses every re-enable until reboot — only
probe a state you are willing to lose.

`DSI_SW_CTL_EN` in MIPI-TX must be **clear** while the link is running.
All five lanes matter — D0/D1/D2/CK and the real D3 block at `0x0544`. LK
leaves the PLL running, so `mtk_mipi_tx_pll_prepare()` early-returns on
boot and its cold path is exercised only by a DPMS off/on cycle; a bug
living there is invisible until something relights the panel.

The full mode is correct as shipped: the bezel overlaps the outer ~10
device px of the 1200×1600 panel on every edge and the lit area's corners
are rounded (~30-40 px radius; measured 2026-08-25 with on-glass
calibration rulers). Do **not** shrink the DSI timings to compensate.
Edge-flush UI is handled by the `dc1-safe-area` shell extension in the
device package; other shipped UI should keep a >=12 device px margin
(~40 px in corners).

The frontlight is not the panel's DRM backlight — our mainline DT has no
panel node, so DRM exposes no `panel orientation` property and no backlight
phandle — so `dc1-screen-backlight` mirrors the connector's DPMS state onto
both RT4539 `bl_power` files; without it a blanked panel stays evenly lit
and reads as a wedged display.

## GPU

Mali-G57 MC2 via Panfrost, **now native on the mainline DT** (verified
2026-08-19): kernel `981870b` enables the dtsi `gpu` node at the proven
390 MHz / 850 mV point, panfrost binds at t=6.8 s from cold boot with no
overlay and no probe poke, `renderD128` exists before the session starts,
and gnome-shell logs `Created gbm renderer` (no llvmpipe). GPU devfreq
cooling now binds through the LVTS ts3-0 map since kernel `0f6e730c92d6`
(2026-08-20), live-verified 2026-08-22 — see
[thermal.md](thermal.md). The overlay path below remains for stock-tree
boots. `dc1-gpu` used to report failure while the GPU worked anyway:
applying the runtime overlay only edits the live tree, and the platform
device for the newly-enabled `mali` node is registered after that, so the
`drivers_probe` poke issued straight after `modprobe` hit an empty
platform bus and got `ENODEV` (measured 2026-08-17 at t=4.98 s; panfrost
then bound at t=15.17 s off the kernel's own deferred-probe timeout). A
red unit costs the ordering guarantee that gdm → mutter starts with a
render node, so the poke is now retried until `renderD128` appears.
Panfrost's old `Failed to register cooling device` log dates from when
there was no thermal zone to bind to; the 2026-08-20 LVTS trips/maps fixed
it (devfreq cooler live 2026-08-22) — see [thermal.md](thermal.md).

## Frontlight

Dual RT4539 backlight drivers: `lcd-backlight` (white, i2c-5) and
`lcd-backlight-amber` (amber, i2c-2). GNOME binds exactly one backlight
device to the internal display — `gsd-power` takes the first `firmware` >
`platform` > `raw` match, which is always the white one — so its Settings
slider drives white alone. The `dc1-warmth@denv.it` shell extension
shipped in the device package adds a quick-settings temperature slider
that mixes both channels over one shared luminance: the lower half ramps
amber up over full white, the upper half dims white, reaching pure amber
(white fully off) at max. GNOME's own brightness controls set the
luminance; the extension persists it and tells gsd's echoes of its own
white writes apart from real brightness changes by comparing sysfs against
its last write. Writes go through logind's `Session.SetBrightness`, no
root needed.
