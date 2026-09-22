#!/usr/bin/env python3
"""Read USB 2.0 hub status or Billboard capabilities without changing anything.

Linux requires a writable usbfs handle even for IN control transfers. Run as
root when /dev/bus/usb is not writable; the only requests here are standard
GET_DESCRIPTOR and class GET_STATUS. No strings, serials or kernel logs are
collected. Change bits are reported without acknowledging/clearing them.
"""
import argparse
import ctypes
import fcntl
import os
from pathlib import Path
import re
import struct
import sys


class Control(ctypes.Structure):
    _fields_ = [('request_type', ctypes.c_uint8), ('request', ctypes.c_uint8),
                ('value', ctypes.c_uint16), ('index', ctypes.c_uint16),
                ('length', ctypes.c_uint16), ('timeout', ctypes.c_uint32),
                ('data', ctypes.c_void_p)]


USBDEVFS_CONTROL = (3 << 30) | (ctypes.sizeof(Control) << 16) | (ord('U') << 8)


def read_control(fd, request_type, request, value, index, length):
    # Deliberately allow only bounded descriptor and port-status reads.
    descriptor = (request_type, request, value, index, length) == (0x80, 6, 0x100, 0, 18)
    bos = (request_type, request, value, index) == (0x80, 6, 0xf00, 0) and 5 <= length <= 1024
    port_status = (request_type, request, value, length) == (0xa3, 0, 0, 4) and 1 <= index <= 31
    if not (descriptor or bos or port_status):
        raise ValueError('only device/BOS descriptor and hub-port status reads are permitted')
    data = ctypes.create_string_buffer(length)
    control = Control(request_type, request, value, index, length, 1000, ctypes.addressof(data))
    received = fcntl.ioctl(fd, USBDEVFS_CONTROL, bytearray(control), True)
    if received != length:
        raise ValueError(f'short USB response: expected {length}, received {received}')
    return data.raw


def decode_status(data):
    status, change = struct.unpack('<HH', data)
    flags = ((0x001, 'connected'), (0x002, 'enabled'), (0x004, 'suspended'),
             (0x008, 'over-current'), (0x010, 'reset'), (0x100, 'powered'),
             (0x200, 'low-speed'), (0x400, 'high-speed'))
    return f'status=0x{status:04x} change=0x{change:04x} ' + ','.join(
        name for mask, name in flags if status & mask)


def decode_billboard(data):
    """Decode Billboard fields only; omit container IDs and all USB strings."""
    if (not 5 <= len(data) <= 1024 or data[:2] != bytes((5, 15)) or
            int.from_bytes(data[2:4], 'little') != len(data)):
        raise ValueError('invalid BOS header or length')
    lines, pos, count, found = [], 5, 0, False
    states = ('unspecified-error', 'not-attempted', 'unsuccessful', 'successful')
    while pos < len(data):
        n = data[pos]
        if n < 3 or pos + n > len(data) or data[pos + 1] != 16:
            raise ValueError('invalid BOS capability')
        cap = data[pos:pos + n]
        if cap[2] == 13:
            if n < 48 or not 1 <= cap[4] <= 52 or n < 44 + 4 * cap[4]:
                raise ValueError('invalid Billboard capability')
            found = True
            lines.append('Billboard revision=%04x additional_failure=0x%02x preferred=%d' %
                         (int.from_bytes(cap[40:42], 'little'), cap[42], cap[5]))
            for i in range(cap[4]):
                off = 44 + 4 * i
                state = (cap[8 + i // 4] >> (2 * (i % 4))) & 3
                lines.append('  SVID=%04x mode=%d result=%s' %
                             (int.from_bytes(cap[off:off + 2], 'little'),
                              cap[off + 2], states[state]))
        elif cap[2] == 15:
            if n != 8:
                raise ValueError('invalid Billboard alternate-mode capability')
            lines.append('  Alternate-mode index=%d VDO=%08x' %
                         (cap[3], int.from_bytes(cap[4:8], 'little')))
        count += 1
        pos += n
    if count != data[4]:
        raise ValueError('BOS capability count mismatch')
    if not found:
        raise ValueError('no Billboard capability in BOS')
    return '\n'.join(lines)


def probe_billboard(name):
    if not re.fullmatch(r'[0-9]+-[0-9]+(?:\.[0-9]+)*', name):
        raise ValueError('use a USB device name, not an interface or root hub')
    devices = Path('/sys/bus/usb/devices')
    device = devices / name
    value = lambda field: (device / field).read_text().strip()
    dev_class = int(value('bDeviceClass'), 16)
    # The Lenovo composite device uses class 0 and an interface of class 0x11.
    interfaces = devices.glob(name + ':*')
    if dev_class != 0x11 and not any(
            int((p / 'bInterfaceClass').read_text(), 16) == 0x11 for p in interfaces):
        raise ValueError('device has no Billboard class or interface')
    vendor, product = int(value('idVendor'), 16), int(value('idProduct'), 16)
    node = f'/dev/bus/usb/{int(value("busnum")):03d}/{int(value("devnum")):03d}'
    fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
    try:
        descriptor = read_control(fd, 0x80, 6, 0x100, 0, 18)
        if (descriptor[:2] != bytes((18, 1)) or descriptor[4] != dev_class or
                struct.unpack_from('<HH', descriptor, 8) != (vendor, product)):
            raise ValueError('USB device changed before opening its node')
        head = read_control(fd, 0x80, 6, 0xf00, 0, 5)
        if head[:2] != bytes((5, 15)):
            raise ValueError('invalid BOS header')
        total = int.from_bytes(head[2:4], 'little')
        data = read_control(fd, 0x80, 6, 0xf00, 0, total)
        if data[:5] != head:
            raise ValueError('BOS changed between reads')
        decoded = decode_billboard(data)
        print(f'{name} {vendor:04x}:{product:04x}')
        print(decoded)
    finally:
        os.close(fd)


def probe(hub):
    if not re.fullmatch(r'[0-9]+-[0-9]+(?:\.[0-9]+)*', hub):
        raise ValueError('use a hub sysfs name such as 1-1 (not a root hub or interface)')
    device = Path('/sys/bus/usb/devices') / hub
    value = lambda name: (device / name).read_text().strip()
    if value('bDeviceClass') != '09' or float(value('speed')) > 480:
        raise ValueError('this tool supports external USB 2.0 hubs only')
    ports = int(value('maxchild'))
    if not 1 <= ports <= 31:
        raise ValueError('invalid hub port count')
    vendor, product = int(value('idVendor'), 16), int(value('idProduct'), 16)
    node = f'/dev/bus/usb/{int(value("busnum")):03d}/{int(value("devnum")):03d}'
    fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
    try:
        descriptor = read_control(fd, 0x80, 6, 0x100, 0, 18)
        if descriptor[4] != 9 or struct.unpack_from('<HH', descriptor, 8) != (vendor, product):
            raise ValueError('USB device changed before opening its node')
        print(f'{hub} {vendor:04x}:{product:04x}: {ports} ports')
        for port in range(1, ports + 1):
            data = read_control(fd, 0xa3, 0, 0, port, 4)
            print(f'port {port}: {decode_status(data)}', flush=True)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--billboard', action='store_true', help='read Billboard BOS instead of hub ports')
    parser.add_argument('device', help='USB device sysfs name, for example 1-1 or 1-1.2')
    args = parser.parse_args()
    try:
        (probe_billboard if args.billboard else probe)(args.device)
    except PermissionError:
        sys.exit('USB status access needs root: run this same command with sudo')
    except (OSError, ValueError) as exc:
        sys.exit(f'USB status read failed: {exc}')


if __name__ == '__main__':
    main()
