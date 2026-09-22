#!/usr/bin/env python3
"""Ensure the raw hub reader uses only bounded IN requests."""
import ctypes
import importlib.util
from pathlib import Path
import struct
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


if __name__ == '__main__':
    unittest.main()
