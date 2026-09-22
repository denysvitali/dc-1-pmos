#!/usr/bin/env python3
"""Late PD identity, reconnect, rejection and peripheral module staging."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DEVICE = ROOT / 'pmaports/device/testing/device-daylight-jagar'


class DockingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.partner = self.root / 'port1-partner'
        self.partner.mkdir()
        (self.root / 'port1').mkdir()
        self.role = self.root / 'port1/data_role'
        self.role.write_text('host [device]\n')
        self.power = self.root / 'port1/power_role'
        self.power.write_text('source [sink]\n')

    def request(self, partner='port1-partner'):
        return subprocess.run(['sh', str(DEVICE / 'dc1-usb-host'), partner],
                              env=dict(os.environ, DC1_TYPEC_SYSFS=str(self.root)),
                              capture_output=True, text=True)

    def test_identity_discovered_after_add(self):
        (self.partner / 'type').write_text('not_dfp\n')
        self.assertEqual(self.request().returncode, 0)
        self.assertEqual(self.role.read_text(), 'host [device]\n')
        (self.partner / 'type').write_text('hub\n')
        self.assertEqual(self.request().returncode, 0)
        self.assertEqual(self.role.read_text(), 'host\n')
        self.assertEqual(self.power.read_text(), 'source [sink]\n')

    def test_pc_charger_and_unknown_partner_untouched(self):
        for kind in ('host', 'power_brick', 'peripheral', 'not_dfp', ''):
            with self.subTest(kind=kind):
                (self.partner / 'type').write_text(kind + '\n')
                self.assertEqual(self.request().returncode, 0)
                self.assertEqual(self.role.read_text(), 'host [device]\n')

    def test_already_host_does_not_swap_again(self):
        (self.partner / 'type').write_text('hub\n')
        self.role.write_text('[host] device\n')
        self.assertEqual(self.request().returncode, 0)
        self.assertEqual(self.role.read_text(), '[host] device\n')

    def test_detached_partner_and_absent_role(self):
        self.assertEqual(self.request().returncode, 0)
        (self.partner / 'type').write_text('hub\n')
        self.role.unlink()
        self.assertEqual(self.request().returncode, 0)
        self.assertFalse(self.role.exists())

    def test_invalid_partner_names(self):
        for name in ('../port1-partner', 'portx-partner', 'port1', 'port-partner'):
            self.assertEqual(self.request(name).returncode, 2)

    def test_rejected_write_is_reported(self):
        (self.partner / 'type').write_text('hub\n')
        self.role.chmod(0o444)
        if os.geteuid() == 0:
            self.skipTest('permission denial requires an unprivileged user')
        result = self.request()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rejected', result.stderr)

    def test_udev_dispatches_late_identity_and_scopes_touch(self):
        # Guard the event subscription as well as the helper: testing only
        # the helper cannot catch the original add-only discovery bug.
        rules = (DEVICE / '90-device-daylight-jagar.rules').read_text().replace('\\\n', '')
        dock = next(line for line in rules.splitlines() if 'RUN+="/usr/libexec/dc1-usb-host' in line)
        self.assertIn('ACTION=="add|change"', dock)
        self.assertIn('ATTR{type}=="hub"', dock)
        touch = next(line for line in rules.splitlines() if 'ENV{LIBINPUT_CALIBRATION_MATRIX}=' in line)
        self.assertIn('ATTRS{name}=="ilitek_ts"', touch)

    def test_ramdisk_excludes_peripheral_modules(self):
        modules = self.root / 'modules/kernel'
        modules.mkdir(parents=True)
        for name in ('libcomposite', 'usb_f_ecm', 'uvcvideo', 'snd-usb-audio', 'r8152'):
            (modules / (name + '.ko')).write_text(name)
        dest = self.root / 'ramdisk/lib/modules'
        result = subprocess.run(['sh', str(ROOT / 'installer/stage-gadget-modules.sh'),
                                 str(modules.parent), str(dest)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({p.name for p in dest.iterdir()}, {'libcomposite.ko', 'usb_f_ecm.ko'})
        (modules / 'duplicate').mkdir()
        (modules / 'duplicate/usb_f_ecm.ko').write_text('other ABI')
        result = subprocess.run(['sh', str(ROOT / 'installer/stage-gadget-modules.sh'),
                                 str(modules.parent), str(dest)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
