#!/usr/bin/env python3
"""Periodic GPU reads must not block GTK, overlap, or outlive the window."""
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[2] / 'pmaports/device/testing/device-daylight-jagar/dc1-gpu-settings'


class PollTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = []
        self.workers = []
        self.removed = []
        glib = types.SimpleNamespace(
            idle_add=lambda callback, *args: self.callbacks.append((callback, args)),
            source_remove=self.removed.append,
            timeout_add=lambda *_args: 77)
        gi = types.ModuleType('gi')
        gi.require_version = lambda *_args: None
        repository = types.ModuleType('gi.repository')
        repository.Adw = types.SimpleNamespace(PreferencesWindow=object, Application=object)
        repository.GLib, repository.Gtk = glib, types.SimpleNamespace()
        ns = {'__name__': 'gpu_settings_test', '__file__': str(HELPER)}
        with patch.dict(sys.modules, {'gi': gi, 'gi.repository': repository}):
            exec(compile(HELPER.read_text(), str(HELPER), 'exec'), ns)
        def thread(*, target, **kwargs):
            return types.SimpleNamespace(start=lambda: self.workers.append(target))
        ns['threading'] = types.SimpleNamespace(Thread=thread)
        ns['run_helper'] = lambda *_args, **_kwargs: self.fail('poll invoked the full helper')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.freq = Path(self.tmp.name) / 'cur_freq'
        self.freq.write_text('812000000\n')
        ns['CURRENT_FREQ'] = str(self.freq)
        self.window = object.__new__(ns['GpuSettingsWindow'])
        self.window._closed = self.window._reading = self.window._busy = False
        self.window._pending = None
        self.window._generation = self.window._write_id = 0
        self.window._poll_id = 42
        self.values = []
        self.window._current_row = types.SimpleNamespace(set_subtitle=self.values.append)

    def finish(self):
        self.workers.pop(0)()
        callback, args = self.callbacks.pop(0)
        callback(*args)

    def test_background_single_read_and_no_overlapping_workers(self):
        self.assertTrue(self.window._tick())
        self.assertTrue(self.window._tick())
        self.assertEqual(len(self.workers), 1)
        self.assertEqual(self.values, [])
        self.finish()
        self.assertEqual(self.values, ['812 MHz'])
        self.assertFalse(self.window._reading)

    def test_frequency_change_discards_stale_result(self):
        self.window._tick()
        self.window._queue_write(700000000, 1100000000)
        self.window._pending = None  # Simulate the newer write finishing first.
        self.finish()
        self.assertEqual(self.values, [])
        self.assertFalse(self.window._reading)

    def test_close_cancels_poll_and_discards_inflight_result(self):
        self.window._tick()
        self.assertFalse(self.window._on_close(self.window))
        self.assertEqual(self.removed, [42])
        self.finish()
        self.assertEqual(self.values, [])
        self.assertFalse(self.window._tick())
        self.assertEqual(self.workers, [])

    def test_unavailable_value_recovers_on_next_tick(self):
        self.freq.write_text('not-a-frequency')
        self.window._tick()
        self.finish()
        self.assertEqual(self.values, ['unavailable'])
        self.freq.write_text('545000000')
        self.window._tick()
        self.finish()
        self.assertEqual(self.values[-1], '545 MHz')

    def test_busy_or_pending_writes_suppress_reads(self):
        self.window._busy = True
        self.window._tick()
        self.window._busy = False
        self.window._pending = (700000000, 1100000000)
        self.window._tick()
        self.assertEqual(self.workers, [])


if __name__ == '__main__':
    unittest.main()
