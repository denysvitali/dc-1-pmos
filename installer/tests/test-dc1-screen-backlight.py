#!/usr/bin/env python3
"""Fake-sysfs contract tests; no real sysfs or service operations.

Pass --legacy SOURCE to exercise the original shell implementation with only
its sysfs paths redirected. Otherwise pass the compiled helper. The same
transition/restore cases are used for both implementations.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

LEGACY = len(sys.argv) > 1 and sys.argv[1] == "--legacy"
HELPER = Path(sys.argv[2] if LEGACY else sys.argv[1]).resolve()
sys.argv = sys.argv[:1]


class BacklightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dc1-backlight-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.drm = self.root / "class/drm"
        self.backlight = self.root / "class/backlight"
        self.drm.mkdir(parents=True)
        self.backlight.mkdir(parents=True)
        self.powers = []
        for name, brightness in (("cool", "73\n"), ("warm", "19\n")):
            light = self.backlight / name
            light.mkdir()
            (light / "brightness").write_text(brightness)
            (light / "bl_power").write_text("sentinel\n")
            self.powers.append(light / "bl_power")
        self.env = dict(os.environ, DC1_BACKLIGHT_SYSFS=str(self.root))
        if LEGACY:
            script = self.root / "legacy.sh"
            script.write_text(HELPER.read_text().replace("/sys/class/", str(self.root) + "/class/"))
            self.command = ["sh", str(script)]
        else:
            self.command = [str(HELPER)]
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(self.command, env=self.env, start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.stop)

    def stop(self, sig=signal.SIGTERM):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, sig)
        try:
            self.proc.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.communicate()
            self.fail("helper did not stop within one second")
        self.proc = None

    def connector(self, name, state):
        path = self.drm / name / "dpms"
        path.parent.mkdir(exist_ok=True)
        # Atomic replacement prevents fake regular-file truncation races.
        staging = path.with_name("next")
        staging.write_text(state)
        staging.replace(path)
        return path

    def expect(self, value):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if all(path.read_text() == value for path in self.powers):
                return
            if self.proc is not None:
                self.assertIsNone(self.proc.poll(), "helper exited unexpectedly")
            time.sleep(0.02)
        self.fail(f"expected {value!r}: {[p.read_text() for p in self.powers]}")

    def unchanged(self, value):
        stamps = [p.stat().st_mtime_ns for p in self.powers]
        time.sleep(1.1)  # At least two production polling intervals.
        self.assertIsNone(self.proc.poll())
        self.assertEqual([p.read_text() for p in self.powers], [value] * 2)
        self.assertEqual([p.stat().st_mtime_ns for p in self.powers], stamps,
                         "steady/unknown state rewrote bl_power")

    def test_unknown_transitions_and_brightness(self):
        self.start()
        self.unchanged("sentinel\n")  # No connector before the display gate.
        path = self.connector("card0-DSI-1", "Off\n")
        self.expect("4\n")
        self.unchanged("4\n")
        # No readable connector must keep the last applied state.
        path.unlink()
        self.unchanged("4\n")
        self.connector("card0-DSI-1", "")
        self.unchanged("4\n")  # Empty / partial reads do not vote.
        self.connector("card0-DSI-1", "On")
        self.unchanged("4\n")
        self.connector("card0-DSI-1", "On\n")
        self.expect("0\n")
        self.unchanged("0\n")
        for state in ("Standby\n", "Suspend\n", "Off\n"):
            self.connector("card0-DSI-1", state)
            self.expect("4\n")
            self.connector("card0-DSI-1", "On\n")
            self.expect("0\n")
        self.assertEqual((self.backlight / "cool/brightness").read_text(), "73\n")
        self.assertEqual((self.backlight / "warm/brightness").read_text(), "19\n")

    def test_multi_connector_on_precedence(self):
        self.connector("card0-AA-1", "Off\n")
        self.connector("card0-ZZ-1", "On\n")
        self.start()
        self.expect("0\n")
        self.connector("card0-AA-1", "On\n")
        self.connector("card0-ZZ-1", "Off\n")
        self.unchanged("0\n")
        self.connector("card0-AA-1", "Off\n")
        self.expect("4\n")
        self.connector("card0-ZZ-1", "On\n")
        self.expect("0\n")

    def test_unreadable_connector_and_failed_light_do_not_block_others(self):
        # A directory at dpms reliably fails read(), even in root-run CI.
        (self.drm / "card0-AA-1/dpms").mkdir(parents=True)
        self.connector("card0-ZZ-1", "Off\n")
        failed = self.powers.pop(0)
        failed.unlink()
        failed.mkdir()  # open-for-write fails, independent of privileges.
        self.start()
        self.expect("4\n")
        self.connector("card0-ZZ-1", "On\n")
        self.expect("0\n")

    def test_stop_and_explicit_restore(self):
        self.connector("card0-DSI-1", "Off\n")
        self.start()
        self.expect("4\n")
        # Both service managers terminate the helper, then call --restore.
        self.stop()
        self.assertEqual([p.read_text() for p in self.powers], ["4\n"] * 2)
        result = subprocess.run(self.command + ["--restore"], env=self.env, timeout=1,
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.expect("0\n")
        self.assertEqual((self.backlight / "cool/brightness").read_text(), "73\n")
        self.start()
        self.expect("4\n")
        self.stop(signal.SIGINT)

    def test_missing_class_directories_and_restore(self):
        shutil.rmtree(self.drm)
        shutil.rmtree(self.backlight)
        self.start()
        time.sleep(0.6)
        self.assertIsNone(self.proc.poll())
        self.stop()
        result = subprocess.run(self.command + ["--restore"], env=self.env, timeout=1,
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipIf(LEGACY, "C helper's process-free polling contract")
    def test_no_children_during_idle_wait(self):
        self.start()
        for _ in range(30):
            self.assertIsNone(self.proc.poll())
            # /task/TID/children depends on CONFIG_PROC_CHILDREN. PPID in
            # stat is available on all supported Linux kernels instead.
            for stat in Path("/proc").glob("[0-9]*/stat"):
                try:
                    fields = stat.read_text().rsplit(")", 1)[1].split()
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    continue  # An unrelated process exited during the scan.
                self.assertNotEqual(int(fields[1]), self.proc.pid,
                                    "idle helper spawned a child")
            time.sleep(0.04)


unittest.main()
