"""Exercise telemetry decisions without GTK or live sysfs writes."""
import ast
import glob
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "pmaports/device/testing/device-daylight-jagar/dc1-charging-settings"
tree = ast.parse(SOURCE.read_text())
functions = {"amps", "profile_choices", "rate_explanation", "read_text", "read_pack_temperature", "parse_owner_status"}
nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in functions]
namespace = {"CHARGE_PROFILES": (("Conservative", 2_000_000), ("Default", 3_150_000)), "glob": glob, "os": os}
window = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "ChargingSettingsWindow")
methods = [node for node in window.body if isinstance(node, ast.FunctionDef) and node.name in {"_refresh_controls", "_on_profile"}]
controls_class = ast.parse("class Controls: pass").body[0]
controls_class.body = methods
nodes.append(controls_class)
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), "exec"), namespace)


class ChargingSettingsTests(unittest.TestCase):
    def test_custom_limit_is_visible_without_replacing_presets(self):
        choices = namespace["profile_choices"](500_000)
        self.assertEqual(choices[:2], list(namespace["CHARGE_PROFILES"]))
        self.assertEqual(choices[2], ("Custom · 0.50 A (active)", 500_000))
        self.assertEqual(len(namespace["profile_choices"](3_150_000)), 2)
        self.assertEqual(len(namespace["profile_choices"](0)), 2)

    def reason(self, **changes):
        status = dict(charger_online=True, charge_target_ua=3_150_000,
                      battery_ua=3_030_000, battery_status="Charging",
                      charge_voltage_uv=4_400_000, battery_uv=4_100_000)
        status.update(changes)
        return namespace["rate_explanation"](status)

    def test_near_target_and_custom_cap(self):
        self.assertIn("near the configured", self.reason())
        reason = self.reason(charge_target_ua=500_000, battery_ua=470_000)
        self.assertIn("Custom 0.50 A limit is active", reason)
        self.assertIn("near the configured", reason)

    def test_slow_rate_does_not_invent_a_thermal_diagnosis(self):
        self.assertIn("cause is not measured", self.reason(battery_ua=1_500_000))
        self.assertIn("normal taper may", self.reason(battery_ua=500_000, battery_uv=4_370_000))
        self.assertIn("reports full", self.reason(battery_status="Full", battery_ua=0))
        self.assertEqual(self.reason(charger_online=False, battery_ua=-250_000), "Running on battery")

    def test_custom_selection_does_not_write_a_new_limit(self):
        controls = namespace["Controls"]()
        controls._busy = controls._building = False
        controls._profile_choices = list(namespace["CHARGE_PROFILES"])
        writes = []
        controls._write = writes.append
        controls._set_controls_sensitive = lambda value: None
        controls._set_error = lambda value: None
        for name in ("_charging_mode", "_auto_update", "_auto_suspend"):
            setattr(controls, name, SimpleNamespace(set_active=lambda value: None))
        class Profile:
            def set_model(self, model): self.model = model
            def set_selected(self, selected):
                self.selected = selected
                controls._on_profile(self, None)
            def get_selected(self): return self.selected
        controls._profile = Profile()
        namespace["Gtk"] = SimpleNamespace(INVALID_LIST_POSITION=0xffffffff,
                                          StringList=SimpleNamespace(new=lambda labels: labels))
        namespace["run_helper"] = lambda args: (0, "charge_current=500000\n", "")
        controls._refresh_controls()
        self.assertEqual(controls._profile.selected, 2)
        self.assertIn("Custom", controls._profile.model[2])
        controls._on_profile(controls._profile, None)
        self.assertEqual(writes, [])
        controls._profile.set_selected(1)
        self.assertEqual(writes, [["charge-current", "3150000"]])

    def test_temperature_requires_a_present_pack_gauge(self):
        with tempfile.TemporaryDirectory() as root:
            namespace["SYSFS"] = root
            gauge = Path(root) / "class/power_supply/bq78z100-0"
            gauge.mkdir(parents=True)
            for name, value in {"present": "0", "type": "Battery", "temp": "270"}.items():
                (gauge / name).write_text(value)
            self.assertIn("Unavailable", namespace["read_pack_temperature"]())
            (gauge / "present").write_text("1")
            self.assertEqual(namespace["read_pack_temperature"](), "27.0 °C")
            (gauge / "temp").unlink()
            self.assertIn("Unavailable", namespace["read_pack_temperature"]())


if __name__ == "__main__":
    unittest.main()
