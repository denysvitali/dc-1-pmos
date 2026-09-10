#!/usr/bin/env python3
"""Offline refusal checks for local kernel image inspection."""
import gzip
import importlib.util
from pathlib import Path
import struct
import json
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_install', Path(__file__).parents[1]/'kernel-local-install.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


def fixture():
    kernel = b'Linux version 7.2-test-build\0' + bytes(128)
    payload = bytearray(96)
    payload[56:60] = b'ARM\x64'
    payload[80:84] = b'\xd0\x0d\xfe\xed'
    struct.pack_into('<4I', payload, 64, 80, 16, 96, len(kernel))
    payload += kernel
    compressed = gzip.compress(payload)
    ramdisk = b'\x02\x21\x4c\x18ramdisk'
    header = bytearray(4096)
    struct.pack_into('<8s4I', header, 0, b'ANDROID!', len(compressed), len(ramdisk), 0x1800017B, 1584)
    struct.pack_into('<I', header, 40, 4)
    struct.pack_into('<I', header, 1580, 4096)
    pad = lambda b: b + bytes((-len(b)) % 4096)
    return bytes(header)+pad(compressed)+pad(ramdisk)+b'AVB0'+bytes(4092), kernel


class LocalKernelTests(unittest.TestCase):
    def test_valid_image(self):
        image, kernel = fixture()
        payload, offset, ramdisk, signature, end = local.unpack(image)
        self.assertEqual(payload[offset:], kernel)
        self.assertEqual(end, len(image))
        self.assertEqual(local.banner(kernel), 'Linux version 7.2-test-build')

    def test_truncated_image(self):
        image, _ = fixture()
        with self.assertRaises(RuntimeError):
            local.unpack(image[:-1])

    def test_header_and_signature_refusals(self):
        image, _ = fixture()
        for offset in (0, 20, 40, 1580, len(image)-4096):
            corrupt = bytearray(image)
            corrupt[offset] ^= 255
            with self.subTest(offset=offset), self.assertRaises(RuntimeError):
                local.unpack(corrupt)

    def test_non_dtbswap_refused(self):
        image, _ = fixture()
        data = bytearray(image)
        k = struct.unpack_from('<I', data, 8)[0]
        payload = bytearray(gzip.decompress(data[4096:4096+k]))
        struct.pack_into('<I', payload, 72, len(payload)+1)
        compressed = gzip.compress(payload)
        struct.pack_into('<I', data, 8, len(compressed))
        data[4096:8192] = compressed+bytes(4096-len(compressed))
        with self.assertRaises(RuntimeError):
            local.unpack(data)

    def test_ambiguous_banner_refused(self):
        with self.assertRaises(RuntimeError):
            local.banner(b'Linux version 7.2-one\0Linux version 7.2-two\0')

    def test_identical_banner_and_format_string(self):
        self.assertEqual(local.banner(b'Linux version 7.2-one\0Linux version 7.2-one\0Linux version %s (%s)\0'),
                         'Linux version 7.2-one')

    def test_module_does_not_satisfy_builtin(self):
        with self.assertRaises(RuntimeError):
            local.check_config(b'CONFIG_MMC_MTK=m\n', 'CONFIG_MMC_MTK=y\n')
        local.check_config(b'CONFIG_MMC_MTK=y\n', 'CONFIG_MMC_MTK=y\n')


class ConfirmationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.directory = self.root/'transaction'
        self.directory.mkdir()
        image, kernel = fixture()
        (self.root/'boot_b').write_bytes(image)
        (self.root/'vmlinuz').write_bytes(gzip.compress(kernel))
        (self.root/'version').write_text(local.banner(kernel))
        (self.root/'boot_id').write_text('new-boot')
        (self.root/'filesystems').write_text('ext4\nvfat\nexfat\n')
        (self.root/'mmc0').mkdir()
        (self.directory/'previous.apk').write_bytes(b'old package')
        self.state = dict(directory=str(self.directory), target='b', old_banner='Linux version 7.1-old',
                          new_banner=local.banner(kernel), boot_id='previous-boot',
                          kernel_sha256=local.sha(kernel), previous_sha256=local.sha(b'old package'))
        self.pending = self.root/'pending.json'
        self.pending.write_text(json.dumps(self.state))
        mapping = {'/proc/version': self.root/'version',
                   '/proc/sys/kernel/random/boot_id': self.root/'boot_id',
                   '/proc/filesystems': self.root/'filesystems',
                   '/sys/class/mmc_host/mmc0': self.root/'mmc0',
                   '/var/lib/dc1/no-auto-update': self.root/'no-auto-update',
                   '/boot/vmlinuz': self.root/'vmlinuz'}
        for name, value in [('BASE', self.root), ('STATE', self.pending),
                            ('Path', lambda p: mapping.get(str(p), Path(p)))]:
            p = patch.object(local, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.run = patch.object(local, 'run').start()
        patch.object(local, 'print', create=True).start()
        self.install = patch.object(local, 'install_apk').start()
        patch.object(local.os, 'sync').start()
        patch.object(local, 'devices', return_value={'boot_b': self.root/'boot_b'}).start()
        patch.object(local, 'slot_status', return_value=('b', {}, '')).start()
        self.addCleanup(patch.stopall)

    def test_candidate_confirmed_after_identity_checks(self):
        local.confirm()
        self.run.assert_called_once_with('dc1-slotctl', 'mark-successful', 'b')
        self.install.assert_not_called()
        self.assertFalse(self.pending.exists())

    def test_wrong_installed_image_never_marks_successful(self):
        (self.root/'vmlinuz').write_bytes(gzip.compress(b'other kernel'))
        with self.assertRaises(RuntimeError):
            local.confirm()
        self.run.assert_not_called()
        self.assertTrue(self.pending.exists())

    def test_confirmation_refuses_same_boot(self):
        (self.root/'boot_id').write_text('previous-boot')
        with self.assertRaises(RuntimeError):
            local.confirm()
        self.run.assert_not_called()
        self.install.assert_not_called()

    def test_fallback_restores_only_verified_backup(self):
        (self.root/'version').write_text(self.state['old_banner'])
        local.confirm()
        self.install.assert_called_once_with(self.directory/'previous.apk', self.directory/'keys', rollback=True)
        self.run.assert_not_called()
        self.assertTrue((self.root/'no-auto-update').exists())

    def test_modified_rollback_refused(self):
        (self.root/'version').write_text(self.state['old_banner'])
        (self.directory/'previous.apk').write_bytes(b'changed')
        with self.assertRaises(RuntimeError):
            local.confirm()
        self.install.assert_not_called()


if __name__ == '__main__':
    unittest.main()
