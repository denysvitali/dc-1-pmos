#!/usr/bin/env python3
"""Exercise the screen-off sleep policy with fake sysfs and a fake command."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(sys.argv[1]).resolve()
sys.argv = sys.argv[:1]


class SleepOnBlankTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dc1-sleep-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dpms = self.root / "class/drm/card0-DSI-1/dpms"
        self.dpms.parent.mkdir(parents=True)
        self.dpms.write_text("On\n")
        self.light = self.root / "class/backlight/lcd-backlight/bl_power"
        self.light.parent.mkdir(parents=True)
        self.light.write_text("4\n")
        self.online = self.root / "class/power_supply/mt6375-charger/online"
        self.online.parent.mkdir(parents=True)
        self.online.write_text("0\n")
        self.log = self.root / "attempts"
        self.enable = self.root / "enable-auto-suspend"
        self.enable.touch()
        command = self.root / "fake-systemctl"
        command.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DC1_TEST_LOG"\n')
        command.chmod(0o755)
        self.env = dict(os.environ, DC1_SLEEP_SYSFS=str(self.root),
                        DC1_SLEEP_COMMAND=str(command), DC1_SLEEP_DELAY="0.20",
                        DC1_SLEEP_POLL="0.02", DC1_TEST_LOG=str(self.log),
                        DC1_SLEEP_ENABLE_FILE=str(self.enable))
        self.proc = subprocess.Popen([str(HELPER)], env=self.env,
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE, start_new_session=True)
        self.addCleanup(self.stop)

    def stop(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
        try:
            self.proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.communicate()
            self.fail("sleep helper did not stop")

    def attempts(self):
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return [line for line in lines if line == "--no-wall suspend"]

    def expect_attempts(self, count):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if len(self.attempts()) == count:
                return
            self.assertIsNone(self.proc.poll(), "sleep helper exited unexpectedly")
            time.sleep(0.01)
        self.fail(f"expected {count} attempts, got {self.attempts()!r}")

    def test_one_attempt_per_screen_off_cycle(self):
        self.dpms.write_text("Off\n")
        self.expect_attempts(1)
        self.assertEqual(self.attempts(), ["--no-wall suspend"])
        self.assertEqual(self.log.read_text().splitlines()[:2],
                         ["unmask sleep.target suspend.target", "--no-wall suspend"])
        time.sleep(0.30)
        self.assertEqual(len(self.attempts()), 1, "immediate resume retried suspend")
        self.dpms.write_text("On\n")
        time.sleep(0.10)
        self.dpms.write_text("Off\n")
        self.expect_attempts(2)

    def test_requires_battery_and_dark_frontlights(self):
        self.online.write_text("1\n")
        self.dpms.write_text("Off\n")
        time.sleep(0.30)
        self.assertEqual(self.attempts(), [])
        self.online.write_text("0\n")
        self.light.write_text("0\n")
        time.sleep(0.30)
        self.assertEqual(self.attempts(), [])
        self.light.write_text("4\n")
        self.expect_attempts(1)

    def test_removed_opt_in_cancels_pending_sleep(self):
        self.dpms.write_text("Off\n")
        self.enable.unlink()
        time.sleep(0.30)
        self.assertEqual(self.attempts(), [])
        self.enable.touch()
        self.expect_attempts(1)

    def test_unknown_or_other_connector_on_cancels_timer(self):
        second = self.root / "class/drm/card0-HDMI-1/dpms"
        second.parent.mkdir()
        second.write_text("On\n")
        self.dpms.write_text("Off\n")
        time.sleep(0.30)
        self.assertEqual(self.attempts(), [])
        second.unlink()
        self.dpms.write_text("Off")  # Incomplete sysfs read is unknown.
        time.sleep(0.30)
        self.assertEqual(self.attempts(), [])
        self.dpms.write_text("Off\n")
        self.expect_attempts(1)


unittest.main()
