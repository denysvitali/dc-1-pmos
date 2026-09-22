#!/usr/bin/env python3
"""Ensure the raw hub reader uses only bounded IN requests."""
import ctypes
import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('hub_status', Path(__file__).with_name('hub-status.py'))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)


class HubStatusTests(unittest.TestCase):
    def test_no_connection_even_when_powered(self):
        text = hub.decode_status(struct.pack('<HH', 0x100, 0))
        self.assertIn('powered', text)
        self.assertNotIn('connected', text)

    def test_connection_and_change_bits(self):
        text = hub.decode_status(struct.pack('<HH', 0x303, 1))
        self.assertIn('connected,enabled,powered,low-speed', text)
        self.assertIn('change=0x0001', text)

    def test_read_request_and_timeout(self):
        def ioctl(fd, command, data, mutate):
            request = hub.Control.from_buffer(data)
            self.assertEqual((request.request_type, request.request, request.value,
                              request.index, request.length, request.timeout), (0xa3, 0, 0, 3, 4, 1000))
            ctypes.memmove(request.data, b'\x00\x01\x00\x00', 4)
            return 4
        with patch.object(hub.fcntl, 'ioctl', side_effect=ioctl):
            self.assertEqual(hub.read_control(1, 0xa3, 0, 0, 3, 4), b'\x00\x01\x00\x00')

    def test_short_response_is_not_status(self):
        with patch.object(hub.fcntl, 'ioctl', return_value=2):
            with self.assertRaisesRegex(ValueError, 'short USB response'):
                hub.read_control(1, 0xa3, 0, 0, 3, 4)

    def test_write_reset_string_and_unbounded_requests_refused(self):
        with patch.object(hub.fcntl, 'ioctl') as ioctl:
            for request in ((0x23, 3, 4, 3, 0), (0x23, 1, 16, 3, 0),
                            (0x80, 6, 0x301, 0, 255), (0xa3, 0, 0, 32, 4),
                            (0xa3, 0, 0, 1, 65535)):
                with self.subTest(request=request), self.assertRaises(ValueError):
                    hub.read_control(1, *request)
            ioctl.assert_not_called()


class BillboardTests(unittest.TestCase):
    @staticmethod
    def bos():
        # Synthetic four-mode fixture, including the last state in a bitmap byte.
        cap = bytearray(60)
        cap[:6] = bytes((60, 16, 13, 0, 4, 0))
        cap[8] = 0xe4
        cap[40:43] = bytes((0x21, 1, 2))
        for i in range(4):
            struct.pack_into('<HBB', cap, 44 + 4 * i, 0xff00 + i, i, 0)
        alt = bytes((8, 16, 15, 2, 0x78, 0x56, 0x34, 0x12))
        container = bytes((20, 16, 4, 0)) + b'PRIVATE-ID-OMIT!'
        total = 5 + len(cap) + len(alt) + len(container)
        return struct.pack('<BBHB', 5, 15, total, 3) + cap + alt + container

    def test_states_and_alternate_vdo_without_unique_ids(self):
        text = hub.decode_billboard(self.bos())
        for state in ('unspecified-error', 'not-attempted', 'unsuccessful', 'successful'):
            self.assertIn('result=' + state, text)
        self.assertIn('additional_failure=0x02', text)
        self.assertIn('index=2 VDO=12345678', text)
        self.assertNotIn('PRIVATE', text)

    def test_malformed_bos_is_rejected(self):
        good = self.bos()
        for offset, value in ((0, 4), (1, 3), (2, 5), (4, 4), (5, 0),
                              (5, 255), (6, 1), (9, 0), (9, 5), (65, 7)):
            bad = bytearray(good)
            bad[offset] = value
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                hub.decode_billboard(bad)
        with self.assertRaises(ValueError):
            hub.decode_billboard(good[:-1])
        with self.assertRaisesRegex(ValueError, 'no Billboard'):
            hub.decode_billboard(bytes((5, 15, 5, 0, 0)))

    def test_bos_request_is_in_only_and_bounded(self):
        def ioctl(fd, command, data, mutate):
            request = hub.Control.from_buffer(data)
            self.assertEqual((request.request_type, request.request, request.value,
                              request.index, request.length, request.timeout),
                             (0x80, 6, 0xf00, 0, 5, 1000))
            ctypes.memmove(request.data, b'\x05\x0f\x05\x00\x00', 5)
            return 5
        with patch.object(hub.fcntl, 'ioctl', side_effect=ioctl):
            self.assertEqual(hub.read_control(1, 0x80, 6, 0xf00, 0, 5),
                             b'\x05\x0f\x05\x00\x00')
        with patch.object(hub.fcntl, 'ioctl') as ioctl:
            for request in ((0x00, 6, 0xf00, 0, 5), (0x80, 6, 0xf00, 0, 1025),
                            (0x80, 6, 0xf00, 0, 4), (0x80, 6, 0xf00, 1, 5)):
                with self.subTest(request=request), self.assertRaises(ValueError):
                    hub.read_control(1, *request)
            ioctl.assert_not_called()

    def test_composite_billboard_identity_and_requests(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            device = root / '1-1.2'
            device.mkdir()
            for field, value in dict(bDeviceClass='00', idVendor='17ef',
                                     idProduct='30b5', busnum='1', devnum='19').items():
                (device / field).write_text(value)
            interface = root / '1-1.2:1.0'
            interface.mkdir()
            (interface / 'bInterfaceClass').write_text('11')
            descriptor = bytearray(18)
            descriptor[:2] = bytes((18, 1))
            struct.pack_into('<HH', descriptor, 8, 0x17ef, 0x30b5)
            bos = self.bos()
            with patch.object(hub, 'Path', return_value=root), \
                    patch.object(hub.os, 'open', return_value=123), \
                    patch.object(hub.os, 'close') as close, \
                    patch.object(hub, 'read_control', side_effect=[descriptor, bos[:5], bos]) as read, \
                    contextlib.redirect_stdout(io.StringIO()):
                hub.probe_billboard('1-1.2')
                self.assertEqual([call.args[1:] for call in read.call_args_list],
                                 [(0x80, 6, 0x100, 0, 18), (0x80, 6, 0xf00, 0, 5),
                                  (0x80, 6, 0xf00, 0, len(bos))])
                close.assert_called_once_with(123)
            descriptor[8] = 0
            with patch.object(hub, 'Path', return_value=root), \
                    patch.object(hub.os, 'open', return_value=123), \
                    patch.object(hub.os, 'close') as close, \
                    patch.object(hub, 'read_control', return_value=descriptor) as read:
                with self.assertRaisesRegex(ValueError, 'device changed'):
                    hub.probe_billboard('1-1.2')
                self.assertEqual(read.call_count, 1)
                close.assert_called_once_with(123)


if __name__ == '__main__':
    unittest.main()
