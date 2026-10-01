#!/usr/bin/env python3
"""Cover the module APK/rootfs parity gate's depmod handling.

The real build tripped this: depmod rewrites the kmod indexes when the rootfs
installs them, and its output is not stable across kmod versions, so the export
gate compared bytes that were never meant to be stable. These cases pin both
halves of the fix -- tolerate a reindex, still reject real drift.
"""
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'verify-kernel-modules.py'
RELEASE = '7.2.0-rc5'
PREFIX = f'lib/modules/{RELEASE}/'


def build_tree(root):
    """A minimal module tree: one driver plus the metadata the gate requires."""
    modules = root / PREFIX
    (modules / 'kernel/drivers/usb').mkdir(parents=True)
    (root / 'usr/share/kernel/postmarketos-mediatek-mt6789').mkdir(parents=True)
    (root / 'usr/share/kernel/postmarketos-mediatek-mt6789/kernel.release').write_text(
        RELEASE + '\n')
    (modules / 'kernel/drivers/usb/test.ko').write_text('module bytes\n')
    (modules / 'modules.dep').write_text('kernel/drivers/usb/test.ko:\n')
    (modules / 'modules.alias').write_text(
        'alias char-major-81-* videodev\nalias usb:* test\n')
    (modules / 'modules.builtin').write_text(
        'kernel/drivers/usb/core/usbcore.ko\n')
    return modules


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

    def test_depmod_reindex_passes(self):
        """A different depmod's spelling, ordering and comment header is not drift."""
        (self.root / PREFIX / 'modules.alias').write_text(
            '# Aliases extracted from modules themselves.\n'
            'alias char_major_81_* videodev\n'
            '\n'
            'alias usb:* test\n')
        (self.root / PREFIX / 'modules.dep').write_text(
            '# comment\n\nkernel/drivers/usb/test.ko:   \n')
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_alias_naming_an_absent_module_fails(self):
        """Normalization must not launder an index that references other modules."""
        (self.root / PREFIX / 'modules.alias').write_text(
            'alias char-major-81-* videodev\n'
            'alias char-major-99-* othermodule\n'
            'alias usb:* test\n')
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('modules.alias', out)

    def test_dropped_alias_fails(self):
        """A rootfs index missing an alias the APK ships is real drift."""
        (self.root / PREFIX / 'modules.alias').write_text('alias usb:* test\n')
        code, out = self.check()
        self.assertNotEqual(code, 0)
        self.assertIn('modules.alias', out)

    def test_driver_byte_drift_fails(self):
        """The same-version-cache-drift case the gate exists to catch."""
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
