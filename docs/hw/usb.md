# USB gadget, docking and configfs — measurement record

Deep-dive for the status-table rows *USB gadget* and *configfs teardown*
in [README.md](../../README.md#hardware-support-at-a-glance). The exposure/ownership consequences of
these channels are documented in [../security.md](../security.md).

## USB gadget

Serial console works (`/dev/ttyGS0`, `ttyGS1`); USB ethernet and SSH over
USB did **not** at first, and an earlier "Works" here was wrong.
`dc1-usb-gadget` reused the gadget the initramfs leaves behind on the
assumption that it is "identical" to the one it builds. It is not: on a
plain (non-installer) boot the handed-off `g1` carried `acm.0` and
`acm.1` and no `ecm.0` at all (observed 2026-08-17), so rebinding the UDC
produced the two ACM ttys and never a `usb0`. The service still reported
success, because the wait for `usb0` ran in a background subshell that
`exit 0`-ed when the interface was missing. Both are fixed in device
pkgrel=34: the existing tree is completed in place (`ensure_ecm`) before
the bind, and the `usb0` wait is in the foreground and fatal.

It must be the **only** UDC owner: `usb-signaller` (from
`postmarketos-usb-moded`) starts afterwards, cannot classify our
functions, tries to switch the UDC to its own gadget, and wedges in
configfs; the device package masks it and its three mode units.

**2026-08-22 evening: the fix confirmed itself on a real boot** — the
handed-off tree was completed in place to `acm.0`+`acm.1`+`ecm.0`, all
linked into `c.1`; the UDC bound cleanly at t=7.26 s after the initramfs
unbind; `usb0` came up UP at 172.16.42.1/24 with the pinned MAC pair;
`usb-signaller` and its three mode units all masked; configfs healthy
(shallow single-level listings only — the D-state wedge is avoided, never
provoked).

**Re-measured 2026-08-26 (running r76/r37 boot):** `usb0` exists and is
administered (NO-CARRIER with no host attached — expected on battery
without a USB peer), and the interface set survived the boot intact.

What remains for ✅ is plugging a USB host into the port and proving SSH
over ECM end-to-end — tracked in [../roadmap.md](../roadmap.md).

## USB host / Type-C hub

The installed system is packaged to use the same port as a data host for a
charging Type-C hub. The port is power-role dual but tries sink first: the
MT6375 TCPM path can request its conservative 5 V/500 mA OTG source when a
power-role swap requires it, and switches MUSB to host after a DR_SWAP. If a
discovered partner reports `type=hub` but the active role is still `[device]`,
the packaged `90-device-daylight-jagar.rules` udev rule requests `host` through
`/sys/class/typec/port0/data_role`; an ordinary PC host never matches it.

The `dc1-usb-gadget` service still binds `g1` on every installed boot, and
the installer continues to bind its ACM+ECM gadget. Host mode disconnects
D+ in the kernel without unbinding the gadget driver, then reconnects it
when the port returns to device mode. This preserves the installer and
recovery gadget path and avoids the measured configfs teardown wedge below.

The sink-host electrical path was verified live on 2026-08-28. The first
role-switch build reached data host / power sink, but MUSB raised
`VBUS_ERROR in a_wait_vrise (81, <SessEnd>)`: MT6375 TCPM saw powered VBUS
and negotiated PD while the USB PHY's independent UTMI VBUS input stayed
at session end. Forcing the PHY's VBUSVALID/AVALID session inputs and
restarting the role session made the attached Lenovo/Fresco Logic five-port
hub enumerate immediately at 480 Mbit/s; charger `online` remained `1`,
input current remained 1.5 A, and the Type-C power role remained `[sink]`.
Kernel `a1a5a465fb61` makes that override an opt-in T-PHY property
(`mediatek,force-vbus-valid`) enabled
only for jagar and clears it outside host mode. Note its placement: the
property lives on the `usb-phy@0` child of the `t-phy@11f40000` node, not
on the T-PHY parent — grepping only the parent looks like the property is
missing.

The source-power path is intentionally not a fast-charge or Thunderbolt
implementation: it advertises only 5 V/500 mA and leaves the RT9471 secondary
charger disabled. Functional source-role operation was verified live on
2026-09-18 after the pkgrel 60 boot: `/sys/class/typec/port0` reported
`power_role=[source]`, `data_role=[host]`, and `port_type=[dual]`, while the
attached hub chain enumerated two hubs, a Logitech receiver, a CoreChips
USB 10/100 adapter, and a Keychron Q1 Max. An external VBUS/current meter was
not present, so source-current margin and thermal behavior remain pending.
USB data remains MUSB USB 2.0; this role change cannot make the port USB 3.x,
DisplayPort Alt Mode, or Thunderbolt.

The packaged linux r50 boot reproduced that host/sink state without a manual
register write. It did **not** prove downstream peripherals: this partner is
a Lenovo 40B0 Thunderbolt 4 dock, not a plain USB 2.0 charging hub. Its
Fresco Logic V1003 hub enumerated, along with the dock's internal MCU and USB
Billboard interfaces, but raw hub GET_STATUS reported ports 3--5 as powered
with neither the connection nor enable bit set. Per-port power cycling and a
full USB hub reset produced the same state. Thus Linux never received an
electrical attach indication for the keyboard or mouse; there was no device
descriptor, authorization failure, or driver bind to fix on the DC-1.

A second attach in the same packaged-kernel session logged
`hub 1-1:1.0: activate --> -11`. Source tracing found a separate MUSB bug:
jagar is PIO-only, but MUSB advertised `HCD_DMA`, so usbcore tried to DMA-map
the hub's interrupt/status buffer. This machine has 8 GiB of RAM, a 32-bit
MUSB child mask, and `swiotlb=noforce`; an unnecessary mapping can therefore
fail as `-EAGAIN`. Kernel `05abbc2ae75c` omits `HCD_DMA` only for
`CONFIG_MUSB_PIO_ONLY` builds (the gate is the `.flags` expression of
`musb_hc_driver` in `drivers/usb/musb/musb_host.c`). That restores the
status URB needed for later
port-change notifications without changing DMA-capable MUSB builds. Linux r52
with that commit booted successfully on 2026-08-28 and registered the MUSB
host/root hub; no external hub was present in that boot, so the repeated
physical reconnect remains pending. The high-address mapping failure is
inferred from the call path rather than traced live. It does not
explain the 40B0 result: the first attachment had a healthy status URB and
the dock still never asserted downstream connection.

This path remains 🚧 until an ordinary USB 2.0-capable charging hub proves a
keyboard or mouse and the return path is exercised: unplug the hub, attach a
PC, and prove the gadget reconnects without restarting `dc1-usb-gadget`.
The 40B0 session proves the DC-1 host controller and charging/sink coexistence,
but does not close downstream peripheral enumeration. This is a failed test,
not proof that the dock's mouse ports inherently require Thunderbolt or
DisplayPort. USB-only fallback remains unresolved; see the
[compatibility interpretation](../usb-docking.md#limits). The exact session
is tracked in [../roadmap.md](../roadmap.md).

The kernel config audit also found a real, narrower omission: host-side USB
network support was absent even though the USB core, hub, HID, and storage
drivers were built in. Kernel pkgrel 60 adds built-in `usbnet`, CDC Ethernet /
NCM, Realtek RTL8152/8153, ASIX AX8817x/AX88179, and SMSC95xx support. This
allows a USB 2.0 Ethernet adapter exposed by a dock to bind once its hub
reports the device; it does not create a missing downstream connection, USB 3
link, Thunderbolt transport, or DisplayPort Alt Mode.

## 2026-09-22 software audit (kernel r61 / device r103)

The [docking guide](../usb-docking.md) records the manufacturer accessory
specifications, driver matrix and end-to-end acceptance procedure. This audit
found missing USB audio/UVC and CoreChips Ethernet drivers, and an add-only
Type-C rule that missed later PD identity discovery. Optional peripheral
drivers now build as modules in the version-matched kernel `-modules` APK;
existing r60 host-networking drivers move there too. The controller and
ACM/ECM recovery path stay built in. The installer stages only its legacy
gadget module allowlist, so new peripheral modules do not inflate boot images.
Device r103 handles identity changes and confines internal touch calibration
to the Ilitek panel.

Configuration resolution with clang/LLD 20 and offline packaging/role tests
cover the software changes. There was no dock attached during this audit;
charging-hub peripheral traffic, repeated reconnect, USB audio/video and the
return to a PC gadget connection remain hardware acceptance work.

## 2026-09-22 Lenovo 40B0 attachment (running kernel r60 / device r102)

After the software audit, the owner attached the 40B0 with its power supply,
display and mouse connected. The tablet remained data host / power sink with
USB-PD active; the charger reported `online=1` and `status=Charging`.
The Fresco Logic V1003 hub (`17ef:30ba`) enumerated at 480 Mbit/s, with the
dock MCU (`17ef:30b4`) and Billboard (`17ef:30b5`) at 12 Mbit/s. The MCU's
HID interface bound to `usbhid`. No mouse USB device or input event node
appeared, and no dock network interface appeared.

The hub was runtime-active, with zero port over-current counts. Sysfs showed
ports 1--2 configured and ports 3--5 `not attached`; none was disabled.
The current attachment's kernel messages contained no descriptor errors,
`VBUS_ERROR`, or hub `activate --> -11` failure. Earlier-boot descriptor
timeouts were not attributed to this attachment. These observations establish
charging and internal-device enumeration, **not working mouse input**.
Fresh hub GET_STATUS and a confirmed mouse move between ports are still
needed to distinguish an absent connection indication from a missed status
notification in this session; cached sysfs state alone cannot do that.
The [read-only hub reader](../../tools/usb/README.md) supports that check
without resetting the dock or changing port power.

This session still runs r60/r102: it does not validate the new r61 modules
APK or r103 identity-change helper. The attached display has no supported
DP/HDMI output path in this port: the board support implements neither
DisplayPort Alt Mode nor Thunderbolt. This is separate from mouse support,
and is not a physical board-wiring measurement. No dock reset, role forcing,
gadget unbind, package install or reboot was used for these observations.

## configfs teardown

The gadget teardown used to unbind the UDC, unlink the functions, then
`rmdir` bottom-up, on the theory that the uninterruptible hangs came from
removals arriving out of order. They do not. Measured on hardware
2026-08-17: with the UDC cleanly unbound, every function unlinked from
`c.1`, the configs already removed, and **no process holding
`/dev/ttyGS0` or `ttyGS1` open**, `rmdir functions/acm.0` still entered D
state and stayed there. It cannot be signalled (`SIGKILL` was ignored),
so the mount is wedged for the rest of the boot, and because it holds the
parent directory's lock every later configfs access blocks behind it — a
plain recursive `find` over `usb_gadget/` hung immediately. That is the
same wedge previously blamed on `usb-signaller`'s removal order, and it
is what failed the suspend freezer, since a D-state task can never be
frozen. So nothing removes gadget objects any more: `stop` unbinds the
UDC and leaves the tree standing, and `start` reuses and completes it.
Rebuilding the tree, if it is ever actually needed, means a reboot.

Operational rule derived from this: never walk the configfs gadget tree
recursively on this device; inspect only shallow single-level listings.
