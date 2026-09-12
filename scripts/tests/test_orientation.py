#!/usr/bin/env python3
"""Exercise orientation events with deterministic buses and a fake main loop."""
import contextlib
import io
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[2] / 'pmaports/device/testing/device-daylight-jagar/dc1-orientation'


class BusError(Exception):
    pass


class Sources:
    SOURCE_REMOVE = False

    def __init__(self):
        self.pending = {}
        self.serial = 0

    def timeout_add(self, delay, callback):
        self.serial += 1
        self.pending[self.serial] = (delay, callback)
        return self.serial

    def idle_add(self, callback):
        return self.timeout_add(0, callback)

    def source_remove(self, source):
        del self.pending[source]

    def dispatch(self):
        source = next(iter(self.pending))
        _, callback = self.pending.pop(source)
        callback()


class Sensor:
    def __init__(self):
        self.orientation = 'bottom-up'
        self.claims = self.reads = self.releases = 0
        self.fail_claim = False

    def ClaimAccelerometer(self, **kwargs):
        if self.fail_claim:
            raise BusError('sensor starting')
        self.claims += 1

    def Get(self, *args):
        self.reads += 1
        return self.orientation

    def ReleaseAccelerometer(self, **kwargs):
        self.releases += 1


class Display:
    def __init__(self):
        self.transform = 2
        self.reads = 0
        self.applies = []
        self.fail = False

    def GetCurrentState(self):
        self.reads += 1
        if self.fail:
            raise BusError('compositor restarting')
        spec = ('DSI-1', 'vendor', 'model', 'serial')
        modes = [('60', 1200, 1600, 60., 1., [], {}),
                 ('120', 1200, 1600, 120., 1.25, [], {'is-current': True})]
        return 7, [(spec, modes, {})], [(0, 0, 1.25, self.transform, True, [spec], {})], {}

    def ApplyMonitorsConfig(self, serial, method, configs, props):
        self.applies.append((serial, method, configs, props))
        self.transform = configs[0][3]


class Bus:
    def __init__(self, obj):
        self.obj = obj
        self.receivers = []

    def get_object(self, *args):
        return self.obj

    def add_signal_receiver(self, callback, **kwargs):
        receiver = types.SimpleNamespace(callback=callback, options=kwargs, removed=False)
        receiver.remove = lambda: setattr(receiver, 'removed', True)
        self.receivers.append(receiver)
        return receiver


class Settings:
    def __init__(self):
        self.locked = False
        self.callback = None

    def connect(self, name, callback):
        self.callback = callback
        return 1

    def disconnect(self, identifier):
        self.callback = None

    def get_boolean(self, name):
        return self.locked

    def lock(self, value):
        self.locked = value
        self.callback(self, 'orientation-lock')


class OrientationTests(unittest.TestCase):
    def setUp(self):
        self.sources = Sources()
        dbus = types.ModuleType('dbus')
        dbus.DBusException = BusError
        dbus.Interface = lambda obj, interface: obj
        for name, convert in [('Int32', int), ('UInt32', int), ('Double', float), ('Boolean', bool)]:
            setattr(dbus, name, convert)
        dbus_glib = types.ModuleType('dbus.mainloop.glib')
        dbus_glib.DBusGMainLoop = lambda **kwargs: None
        repository = types.ModuleType('gi.repository')
        repository.GLib = self.sources
        repository.GLibUnix = types.SimpleNamespace()
        repository.Gio = types.SimpleNamespace()
        modules = {'dbus': dbus, 'dbus.mainloop': types.ModuleType('dbus.mainloop'),
                   'dbus.mainloop.glib': dbus_glib, 'gi': types.ModuleType('gi'),
                   'gi.repository': repository}
        ns = {'__name__': 'orientation_test'}
        with patch.dict(sys.modules, modules):
            exec(compile(HELPER.read_text(), str(HELPER), 'exec'), ns)
        self.sensor, self.display = Sensor(), Display()
        self.system, self.session = Bus(self.sensor), Bus(self.display)
        self.settings = Settings()
        self.stopped = False
        loop = types.SimpleNamespace(quit=lambda: setattr(self, 'stopped', True))
        self.bridge = ns['OrientationBridge'](self.system, self.session, self.settings, loop)
        self.output = contextlib.ExitStack()
        self.output.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.output.enter_context(contextlib.redirect_stderr(io.StringIO()))
        self.addCleanup(self.output.close)
        self.bridge.start()

    def sensor_event(self, orientation):
        self.sensor.orientation = orientation
        self.bridge.sensor_changed('net.hadess.SensorProxy', {'AccelerometerOrientation': orientation}, [])

    def test_steady_state_has_no_periodic_calls(self):
        self.sources.dispatch()
        self.assertEqual(self.display.reads, 1)
        self.assertEqual(self.sensor.reads, 1)
        self.assertEqual(self.sensor.claims, 1)
        self.assertEqual(self.sources.pending, {})
        self.assertEqual(self.display.applies, [])

    def test_burst_coalesces_and_preserves_mode_scale_and_position(self):
        self.sources.dispatch()
        for _ in range(100):
            self.sensor_event('left-up')
        self.assertEqual(len(self.sources.pending), 1)
        self.sources.dispatch()
        self.assertEqual(self.display.reads, 2)
        self.assertEqual(self.display.applies, [(7, 1, [(0, 0, 1.25, 1, True, [('DSI-1', '120', {})])], {})])
        # The MonitorsChanged echo caused by our apply does not apply again.
        self.bridge.queue()
        self.sources.dispatch()
        self.assertEqual(len(self.display.applies), 1)
        self.assertEqual(self.sources.pending, {})

    def test_lock_suppresses_updates_and_unlock_uses_latest_orientation(self):
        self.sources.dispatch()
        self.settings.lock(True)
        self.sensor_event('right-up')
        self.sources.dispatch()
        self.assertEqual(self.display.reads, 1)
        self.assertEqual(self.sources.pending, {})
        self.settings.lock(False)
        self.sources.dispatch()
        self.assertEqual(self.display.transform, 3)

    def test_mutter_restart_reapplies_unchanged_sensor_state(self):
        self.sources.dispatch()
        replacement = Display()
        replacement.transform = 0
        self.session.obj = replacement
        self.bridge.owner_changed('org.gnome.Mutter.DisplayConfig', ':1.1', ':1.2')
        self.sources.dispatch()
        self.assertEqual(replacement.transform, 2)
        self.assertEqual(len(replacement.applies), 1)

    def test_sensor_restart_reclaims_and_reads_new_owner(self):
        self.sources.dispatch()
        replacement = Sensor()
        replacement.orientation = 'normal'
        self.system.obj = replacement
        self.bridge.owner_changed('net.hadess.SensorProxy', ':1.1', ':1.2')
        self.sources.dispatch()
        self.assertEqual(replacement.claims, 1)
        self.assertEqual(self.display.transform, 0)

    def test_failure_retries_but_owner_signal_preempts_retry_delay(self):
        self.display.fail = True
        self.sources.dispatch()
        self.assertEqual([delay for delay, _ in self.sources.pending.values()], [1000])
        self.display.fail = False
        self.bridge.owner_changed('org.gnome.Mutter.DisplayConfig', ':1.1', ':1.2')
        self.assertEqual([delay for delay, _ in self.sources.pending.values()], [0])
        self.sources.dispatch()
        self.assertEqual(self.sources.pending, {})

    def test_failed_claim_is_retried(self):
        self.sensor.fail_claim = True
        self.sources.dispatch()
        self.assertIsNone(self.bridge.sensor)
        self.sensor.fail_claim = False
        self.sources.dispatch()
        self.assertEqual(self.sensor.claims, 1)
        self.assertEqual(self.sources.pending, {})

    def test_invalidated_orientation_is_read_and_unrelated_signals_ignored(self):
        self.sources.dispatch()
        self.bridge.sensor_changed('net.hadess.SensorProxy', {'LightLevel': 1}, [])
        self.assertEqual(self.sources.pending, {})
        self.sensor.orientation = 'undefined'
        self.display.transform = 1
        self.bridge.sensor_changed('net.hadess.SensorProxy', {}, ['AccelerometerOrientation'])
        self.sources.dispatch()
        self.assertEqual(self.display.transform, 2)

    def test_shutdown_cancels_pending_work_unsubscribes_and_releases(self):
        self.sources.dispatch()
        self.sensor_event('left-up')
        self.bridge.stop()
        self.assertEqual(self.sources.pending, {})
        self.assertEqual(self.sensor.releases, 1)
        self.assertTrue(self.stopped)
        self.assertTrue(all(r.removed for r in self.system.receivers + self.session.receivers))
        self.bridge.queue()
        self.assertEqual(self.sources.pending, {})


if __name__ == '__main__':
    unittest.main()
