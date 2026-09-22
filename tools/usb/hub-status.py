#!/usr/bin/env python3
"""Read fresh USB 2.0 hub port status without resetting or changing anything.

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
    # Deliberately allow only the two fixed read requests used below.
    descriptor = (request_type, request, value, index, length) == (0x80, 6, 0x100, 0, 18)
    port_status = (request_type, request, value, length) == (0xa3, 0, 0, 4) and 1 <= index <= 31
    if not (descriptor or port_status):
        raise ValueError('only device descriptor and hub-port status reads are permitted')
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
    parser.add_argument('hub', help='external hub sysfs name, for example 1-1')
    args = parser.parse_args()
    try:
        probe(args.hub)
    except PermissionError:
        sys.exit('USB status access needs root: run this same command with sudo')
    except (OSError, ValueError) as exc:
        sys.exit(f'hub status read failed: {exc}')


if __name__ == '__main__':
    main()
