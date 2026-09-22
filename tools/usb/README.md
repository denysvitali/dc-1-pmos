# Read-only USB hub and Billboard status

When a peripheral is absent from the USB tree, sysfs's port `state` records
what Linux last observed. Read the hub's current status to distinguish a
missing connection indication from a missed port-change notification:

```sh
sudo python3 tools/usb/hub-status.py 1-1
```

Replace `1-1` with the external USB 2.0 hub's name under
`/sys/bus/usb/devices`. The script validates the hub class and identity,
then issues only device-descriptor and per-port GET_STATUS requests with
one-second timeouts. Linux requires a writable usbfs handle even for these
IN transfers, so the usual root-owned USB device nodes require sudo.
It does not detach drivers, reset devices, switch roles, change power,
clear change bits, or request device serial strings.

- `powered` without `connected`: the hub does not currently report a device
  on that port. Check the peripheral, cable, port and dock's USB 2.0 fallback.
- `connected` while sysfs still says `not attached`: inspect host-controller
  errors and the hub status interrupt path. A driver cannot bind until USB
  enumeration completes.
- `connected,enabled`: inspect the child USB interfaces and driver binding,
  then test the function in userspace.

Change bits are printed as reported; usbcore may handle them concurrently.
A single snapshot does not prove reconnect reliability. Follow the
[docking acceptance procedure](../../docs/usb-docking.md) for that.

Offline request-boundary and status-decoding checks run through
`installer/tests/test-usb-docking.sh`; they never access real USB hardware.

For a dock exposing a Billboard device, read its advertised mode results:

```sh
sudo python3 tools/usb/hub-status.py --billboard 1-1.2
```

Use the Billboard's device name, not its parent hub or interface name. This
also handles composite devices such as the Lenovo 40B0, whose Billboard class
is on an interface. It reads only the device descriptor and a BOS descriptor
bounded to 1024 bytes, checks their lengths and identity, and prints Billboard
mode results. It neither requests strings nor prints container IDs. The field
layout follows the [upstream usbutils decoder](https://github.com/gregkh/usbutils/blob/master/lsusb.c).

An alternate mode reported as `not-attempted` does not prove that ordinary
USB mouse support is impossible. Likewise, `additional_failure=0x02` is not
by itself a failed charging contract: [Infineon's reference implementation](https://github.com/Infineon/pdaltmode/blob/master/cy_pdaltmode_billboard.c)
also uses this flag for alternate-mode entry timeout/failure. Compare it with
the TCPM exchange and fresh hub-port status before assigning a cause.
