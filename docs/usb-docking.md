# USB docking on the DC-1

The supported target is a **USB 2.0 hub with USB 2.0-compatible peripherals**.
All peripherals share the MUSB controller's 480 Mbit/s link. A powered USB-C
hub can leave the tablet charging while it hosts peripherals. An unpowered
hub shares the port's conservative 5 V/500 mA source budget with its devices;
source-current margin and thermal validation remain open.

Daylight documents [wired keyboards, mice and a USB/Ethernet multi-hub](https://support.daylightcomputer.com/getting-started/accessories-guide-daylight-works-with-devices),
[Ethernet adapters](https://support.daylightcomputer.com/getting-started/connect-to-ethernet),
and [external webcams](https://support.daylightcomputer.com/dc-1-webcam-guide).
Those are stock-software capabilities to cover, not proof that this port has
passed their acceptance tests. The [board specification](hardware.md) maps the
remaining advertised hardware to its subsystem records.

## Driver coverage

Kernel r61 introduces `linux-postmarketos-mediatek-mt6789-modules`. The kernel
APK depends on the **exact same version** of that subpackage, so normal APK
updates install the pair together. Optional drivers are `.ko` files loaded by
udev/kmod when their devices appear; they do not enlarge the built-in kernel
or either boot ramdisk. The modules APK includes the complete module tree and
dependency/alias indexes, including pre-existing platform modules. It also
depends on Alpine's upstream `linux-firmware-rtl_nic` package for Realtek NIC
firmware. No downloaded firmware is committed here.

| Function | Implemented coverage | Acceptance still needed |
| --- | --- | --- |
| Host and recovery roles | Built-in MUSB PIO, MT6375 TCPM, role switch, ACM/ECM gadget | Repeated powered-hub reconnect and return to PC/ECM |
| Keyboard/mouse | Built-in generic USB HID; modular Apple, Microsoft, Logitech DJ/HID++, multitouch | Input events, receiver hotplug and simultaneous traffic |
| Ethernet | Modular CDC ECM/NCM, RTL8152/8153, ASIX AX8817x/AX88179, SMSC75xx/95xx, LAN78xx, DM96xx, SR9700/SR9800 | Driver bind, DHCP, traffic and reconnect on actual adapters |
| Storage/card readers | Built-in USB mass storage, SCSI disk, FAT/exFAT/ext4; modular Realtek reader quirks | Read checks, safe eject, reconnect and concurrent traffic |
| USB audio/headsets | Modular `snd-usb-audio`, existing PipeWire/WirePlumber monitor | Output selection, playback/capture and reconnect |
| External webcams | Modular UVC/V4L2 | Application capture and audio/video concurrency within USB 2.0 bandwidth |

The 2026-09-18 r60 session recorded a hub chain, Logitech receiver, CoreChips
adapter and Keychron keyboard **enumerating in source-host mode**. On
2026-09-22, the owner confirmed working mouse input through a replacement
USB 2.0 hub after receiver hotplug, also on r60. Ethernet traffic, keyboard
input and charging-hub sink-host operation remain unverified. See the
[dated USB record](hw/usb.md).

Device r103 listens for both Type-C partner creation and later identity
changes. Linux publishes Discover Identity results through `KOBJ_CHANGE`;
the earlier add-only rule could miss the hub classification. The helper
rechecks `type=hub` and the active device role before requesting DR_SWAP on
that partner's port. It never changes the power role or unbinds the gadget.
Unknown partners and PCs are left to TCPM. The internal touchscreen's
180-degree calibration also now matches only `ilitek_ts`, so it does not
invert an external USB touchscreen.

## Limits

- Current board support exposes MUSB USB 2.0, with no implemented SuperSpeed,
  USB4, Thunderbolt or DisplayPort Alt Mode path. The dock's HDMI/DP sockets
  therefore have no supported video source in this port. Daylight's
  [public specification](https://support.daylightcomputer.com/daylight-dc-1-press-kit-1)
  lists Type-C with PD without specifying data speed or alt modes; that is
  not a definitive board-wiring specification. USB graphics adapters would
  need separate driver/compositor work and are not covered by this change.
- **A USB mouse does not require Thunderbolt or DisplayPort.** USB 2.0 uses
  a separate data path from the high-speed lanes used for these transports;
  see the [USB-IF/VESA explanation, slides 21--23](https://www.usb.org/sites/default/files/D2T1-4%20-%20VESA%20DP%20Alt%20Mode%20over%20USB%20Type-C.pdf).
  USB 2.0 operation alone also does not establish that DP Alt Mode is absent.
- The Lenovo 40B0 exposed its internal hub/MCU/Billboard, but no downstream
  mouse, in the recorded sessions. Its USB-only peripheral compatibility
  remains **unresolved**, not proven impossible. Lenovo's
  [compatibility note](https://pcsupport.lenovo.com/gp/en/accessories/PD500503)
  lists USB-C Alt Mode or Thunderbolt hosts; this describes supported host
  configurations, without establishing which individual functions must fail
  on other hosts. Successful internal-device enumeration already proves
  that some of the dock's USB 2.0 path works with the DC-1.
- Peripheral drivers bind after USB enumeration. Generic HID is already
  built in; a missing mouse descriptor does not identify a missing HID
  driver. Host/hub status handling, dock behavior and the physical connection
  still need to be distinguished before assigning the cause.
- Kernel modules apply after the matching kernel is booted. Do not judge a
  new APK's drivers using an older running kernel.

## Hardware acceptance session

Use an ordinary USB 2.0-capable hub first. Record the dock model, kernel and
device package versions, cable, power source, and a pass/fail for each step.
`lsusb` requires `usbutils`; the other observations are available through
sysfs, GNOME Settings and the existing desktop tools.

1. Attach the powered hub. Read `data_role` and `power_role` under
   `/sys/class/typec/port0/`: expect active host and sink. Check charger
   `online` at `/sys/class/power_supply/mt6375-charger/online`. Check
   `lsusb -t` for the hub and each peripheral's driver.
2. Use keyboard and mouse, then unplug/reinsert each **after** the hub has
   enumerated. Repeat hub attachment in both cable orientations. Require
   fresh input on every cycle, not just a device in the USB tree.
3. For Ethernet, require a driver and an interface in `nmcli device status`,
   a DHCP lease, and traffic to a known local peer. Repeat with Wi-Fi disabled
   through Settings so it cannot mask an Ethernet failure.
4. Read a known file from disposable test storage and compare its checksum.
   Eject through Files before removing it. Test concurrent input and Ethernet.
5. Select the dock headset explicitly in GNOME Sound. With the owner's
   go-ahead, check playback and recording, then disconnect it and verify the
   internal audio remains available. Open a UVC camera application and check
   sustained capture; test simultaneous USB audio separately.
6. Repeat at least ten attach/detach cycles with the peripherals attached.
   Exercise powered attachment and, with low-power peripherals, unpowered
   attachment. Do not disconnect hub power while storage is mounted.
7. Unplug the hub, attach a PC, and require ECM/SSH at `172.16.42.1` plus ACM
   to return without restarting the gadget service. Then return to the hub.

Never unbind `g1`, remove configfs objects, force PHY registers or change power
roles to make a test pass. A failure should retain its actual classification:
role negotiation, absent hub/port connection, unbound driver, or application
behavior. Summarize results in the USB record and verification ledger without
publishing serial numbers, network credentials or raw recovery logs.

If a peripheral never appears, use the
[read-only hub status tool](../tools/usb/README.md) to compare fresh port
GET_STATUS responses with sysfs's cached port state. This separates a dock
that reports no connection from a host that missed its change notification.

No dock was attached during the r61/r103 software audit. Offline checks cover
configuration, packaging, identity events, module content and rollback; they
do not establish that every docking station works.
