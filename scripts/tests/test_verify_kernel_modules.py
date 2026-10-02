#!/usr/bin/env python3
"""Cover the module APK/rootfs parity gate's depmod handling.

depmod runs again when the rootfs installs the modules package, with the kmod
from the rootfs rather than the build chroot, and regenerates the indexes
under /lib/modules. Its output differs from the APK's in formatting and in which
provider it picks for an ambiguous symbol, which the real arm64 build trips on.
These cases pin the contract: driver content must match exactly, the indexes
must only name modules the package ships, and a genuine content difference must
still stop the export.
"""
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'verify-kernel-modules.py'

_spec = __import__('importlib.util', fromlist=['util']).spec_from_file_location(
    '_gate', SCRIPT)
_gate = __import__('importlib.util', fromlist=['util']).module_from_spec(_spec)
_spec.loader.exec_module(_gate)
index_modules = _gate.index_modules
RELEASE = '7.2.0-rc5'
PREFIX = f'lib/modules/{RELEASE}/'

# The module tree the fixture ships. Every module named by the indexes below
# must have a file here, or the gate is right to reject the index.
DRIVERS = (
    'kernel/drivers/usb/test.ko',
    'kernel/drivers/block/zram/zram.ko',
    'kernel/mm/zsmalloc.ko',
    'kernel/lib/zstd/zstd_compress.ko',
    'kernel/drivers/media/v4l2-core/videodev.ko',
    'kernel/drivers/media/mc/mc.ko',
    'kernel/drivers/media/common/videobuf2/videobuf2-common.ko',
    'kernel/drivers/media/common/videobuf2/videobuf2-v4l2.ko',
)

# Taken from the real failing build: the rootfs's depmod resolved a videobuf2
# symbol to mc.ko, and emitted zram's dependencies in the other order.
APK_DEP = (
    'kernel/drivers/media/common/videobuf2/videobuf2-v4l2.ko: '
    'kernel/drivers/media/common/videobuf2/videobuf2-common.ko '
    'kernel/drivers/media/v4l2-core/videodev.ko\n'
    'kernel/drivers/block/zram/zram.ko: '
    'kernel/lib/zstd/zstd_compress.ko kernel/mm/zsmalloc.ko\n'
    'kernel/drivers/usb/test.ko:\n'
)
ROOTFS_DEP = (
    'kernel/drivers/media/common/videobuf2/videobuf2-v4l2.ko: '
    'kernel/drivers/media/common/videobuf2/videobuf2-common.ko '
    'kernel/drivers/media/mc/mc.ko kernel/drivers/media/v4l2-core/videodev.ko\n'
    'kernel/drivers/block/zram/zram.ko: '
    'kernel/mm/zsmalloc.ko kernel/lib/zstd/zstd_compress.ko\n'
    'kernel/drivers/usb/test.ko:\n'
)


def build_tree(root, dep=APK_DEP):
    """A minimal module tree: drivers plus the metadata the gate requires."""
    modules = root / PREFIX
    modules.mkdir(parents=True, exist_ok=True)
    (root / 'usr/share/kernel/postmarketos-mediatek-mt6789').mkdir(
        parents=True, exist_ok=True)
    (root / 'usr/share/kernel/postmarketos-mediatek-mt6789/kernel.release').write_text(
        RELEASE + '\n')
    for driver in DRIVERS:
        path = modules / driver
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('module bytes\n')
    # A non-driver payload: firmware and overlays are content, not derived.
    firmware = modules / 'kernel/drivers/usb/firmware.bin'
    firmware.parent.mkdir(parents=True, exist_ok=True)
    firmware.write_text('firmware bytes\n')
    (modules / 'modules.dep').write_text(dep)
    (modules / 'modules.alias').write_text(
        '# Aliases extracted from modules themselves.\n'
        'alias char-major-81-* kernel/drivers/media/v4l2-core/videodev.ko\n'
        'alias usb:* kernel/drivers/usb/test.ko\n')
    # Built-in drivers are compiled into the kernel and have no file here.
    (modules / 'modules.builtin').write_text('kernel/drivers/usb/core/usbcore.ko\n')


class VerifyKernelModulesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.tmp)], check=True)
        self.apk_tree = self.tmp / 'pkg'
        self.root = self.tmp / 'rootfs'
        build_tree(self.apk_tree)
        build_tree(self.root)

    def check(self):
        """Run the gate and return (returncode, combined output)."""
        apk = self.tmp / 'modules.apk'
        with tarfile.open(apk, 'w:gz') as archive:
            archive.add(self.apk_tree / 'lib', arcname='lib')
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(apk), str(self.root)],
            capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def test_identical_tree_passes(self):
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn('parity passed', out)

    def test_real_depmod_reindex_passes(self):
        """The exact difference the real build reported, end to end.

        A different kmod regenerated the indexes: different comment header,
        alias pattern spelling, dependency ordering, and an extra provider for
        one symbol. None of that changes which modules are installed.
        """
        build_tree(self.root, dep=ROOTFS_DEP)
        (self.root / PREFIX / 'modules.alias').write_text(
            'alias char_major_81_* kernel/drivers/media/v4l2-core/videodev.ko\n'
            'alias usb:* kernel/drivers/usb/test.ko\n')
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_binary_index_is_exempt_from_content(self):
        """depmod's .bin indices are opaque, and modules.dep covers them.

        The real build's index began
        b'\x0b.kernel/...videobuf2-v4l2.ko\x00+kernel/...uvc.ko\x00' with
        kmod's type markers, which is exactly why these are not parsed.
        """
        (self.apk_tree / PREFIX / 'modules.dep.bin').write_bytes(
            b'PADDING\x00kernel/drivers/usb/test.ko\x00\x00')
        (self.root / PREFIX / 'modules.dep.bin').write_bytes(
            b'\x0b.kernel/drivers/usb/test.ko\x00'
            b'+kernel/drivers/uvc.ko\x00-kernel/drivers/other.ko\x00')
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_marker_prefixed_index_path_is_not_read_as_a_module(self):
        """A kmod type marker must never become part of a module name."""
        blob = (b'\x0b.kernel/drivers/usb/test.ko\x00'
                b'+kernel/drivers/uvc.ko\x00')
        self.assertNotIn('+kernel/drivers/uvc.ko', index_modules(blob))
        self.assertIn('kernel/drivers/uvc.ko', index_modules(blob))

    def test_index_naming_an_absent_module_fails(self):
        """An index naming a module neither package ships is real drift."""
        (self.root / PREFIX / 'modules.alias').write_text(
            'alias char-major-81-* kernel/drivers/media/v4l2-core/videodev.ko\n'
            'alias char-major-99-* kernel/drivers/ghost/ghostmodule.ko\n'
            'alias usb:* kernel/drivers/usb/test.ko\n')
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('does not ship', out)

    def test_dropped_alias_is_tolerated(self):
        """An index entry going missing is depmod's business, not ours.

        Every driver the package ships is still present and byte-identical;
        the index merely stopped mentioning one. The gate's one-way check --
        an index may not name a module that does not exist -- still holds.
        """
        (self.root / PREFIX / 'modules.alias').write_text(
            'alias usb:* kernel/drivers/usb/test.ko\n')
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_driver_byte_drift_fails(self):
        """The same-version-cache-drift case the gate exists to catch."""
        (self.root / PREFIX / 'kernel/drivers/usb/test.ko').write_text('other build\n')
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('mismatch', out)

    def test_firmware_byte_drift_fails(self):
        """Firmware and overlays are content, not depmod output."""
        (self.root / PREFIX / 'kernel/drivers/usb/firmware.bin').write_text('other\n')
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('mismatch', out)

    def test_driver_byte_drift_fails_alongside_reindex(self):
        """Reformatted indexes must not excuse a driver that actually differs."""
        build_tree(self.root, dep=ROOTFS_DEP)
        (self.root / PREFIX / 'kernel/drivers/usb/test.ko').write_text('other build\n')
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('mismatch', out)

    def test_missing_driver_in_rootfs_fails(self):
        (self.root / PREFIX / 'kernel/drivers/usb/test.ko').unlink()
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('absent from rootfs', out)

    def test_missing_index_metadata_fails(self):
        (self.apk_tree / PREFIX / 'modules.alias').unlink()
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('metadata', out)


if __name__ == '__main__':
    unittest.main()
