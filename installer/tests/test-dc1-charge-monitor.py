import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[2] / "tools/power/charge-monitor.py"
spec = importlib.util.spec_from_file_location("charge_monitor", path)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class ChargeMonitorTests(unittest.TestCase):
    def test_disabled_adc_is_never_enabled(self):
        with patch.object(monitor, "transfer", return_value=[0]) as bus:
            with self.assertRaisesRegex(RuntimeError, "disabled"):
                monitor.adc_sample()
        self.assertEqual(bus.call_args_list, [(("w1@0x34", "0xa4", "r1"),)])

    def test_busy_adc_is_never_overwritten(self):
        with patch.object(monitor, "transfer", side_effect=[[128], [16]]) as bus:
            with self.assertRaisesRegex(RuntimeError, "busy"):
                monitor.adc_sample()
        self.assertFalse(any(call.args[0].startswith("w2") for call in bus.call_args_list))

    def test_only_single_shot_channel_selects_are_written(self):
        writes = []
        def transfer(*args):
            if args[0] == "w2@0x34":
                self.assertEqual(args[1], "0xa6")
                writes.append(args)
                return []
            if args[1] == "0xa4":
                return [128]
            if args[1] == "0xa6":
                return [0]
            return [0, 110]
        with patch.object(monitor, "transfer", side_effect=transfer), patch.object(monitor.time, "sleep"):
            result = monitor.adc_sample()
        self.assertEqual([int(args[2], 16) for args in writes], [16, 64, 80, 96, 128])
        self.assertEqual(result["junction_c"], 54)
        self.assertAlmostEqual(result["vbus_v"], .6875)


if __name__ == "__main__":
    unittest.main()
