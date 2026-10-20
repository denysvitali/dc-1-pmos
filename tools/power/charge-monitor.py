#!/usr/bin/env python3
"""Bounded charging measurements; no changes to charge or thermal policy.

--adc opts into MT6375 single-shot conversions on this board's i2c5/0x34.
The ADC must already be enabled and idle. Only its channel-select register
is written; all other measurements use read-only sysfs attributes.
"""

import argparse
import datetime
import glob
import json
from pathlib import Path
import subprocess
import time


def transfer(*args):
    result = subprocess.run(
        ["i2ctransfer", "-y", "-f", "5", *args],
        check=True, capture_output=True, text=True, timeout=2,
    )
    return [int(value, 16) for value in result.stdout.split()]


def adc_sample():
    if not transfer("w1@0x34", "0xa4", "r1")[0] & 0x80:
        raise RuntimeError("ADC is disabled; refusing to enable it")
    result = {}
    for channel, name, scale, offset in (
        (1, "vbus_v", .00625, 0), (4, "vbat_v", .00125, 0),
        (5, "ibus_a", .0025, 0), (6, "ibat_a", .0025, 0),
        (8, "junction_c", 1, -56),
    ):
        if transfer("w1@0x34", "0xa6", "r1")[0]:
            raise RuntimeError("ADC is busy; refusing to replace its conversion")
        transfer("w2@0x34", "0xa6", hex(channel << 4))
        for _ in range(20):
            time.sleep(.005)
            if not transfer("w1@0x34", "0xa6", "r1")[0] & 0xf0:
                break
        else:
            raise RuntimeError("ADC conversion timed out")
        high, low = transfer("w1@0x34", hex(0xaa + 2 * (channel - 1)), "r2")
        result[name] = round(((high << 8) | low) * scale + offset, 4)
    return result


def read(path):
    try:
        value = Path(path).read_text(encoding="ascii").strip()
        try:
            return int(value)
        except ValueError:
            return value
    except (OSError, UnicodeError):
        return None


def sample(with_adc=False):
    result = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    result["thermal_mc"] = {
        read(f"{zone}/type"): read(f"{zone}/temp")
        for zone in glob.glob("/sys/class/thermal/thermal_zone*")
    }
    for supply, fields in (
        ("mt6358-fg", ("capacity", "current_now", "voltage_now", "status")),
        ("mt6375-charger", ("online", "constant_charge_current", "input_current_limit")),
        ("tcpm-source-psy-mt6375-tcpc", ("voltage_now", "current_max")),
    ):
        result[supply] = {
            field: read(f"/sys/class/power_supply/{supply}/{field}") for field in fields
        }
    if with_adc:
        try:
            result["adc"] = adc_sample()
        except (OSError, RuntimeError, subprocess.SubprocessError, ValueError, IndexError) as exc:
            result["adc_error"] = str(exc)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=600, help="seconds (1–3600)")
    parser.add_argument("--interval", type=int, default=15, help="seconds (2–300)")
    parser.add_argument("--adc", action="store_true", help="opt into charger ADC conversions")
    args = parser.parse_args()
    if not 1 <= args.duration <= 3600 or not 2 <= args.interval <= 300:
        parser.error("duration or interval outside the supported range")
    start = time.monotonic()
    while True:
        result = sample(args.adc)
        result["elapsed_s"] = round(time.monotonic() - start, 2)
        print(json.dumps(result, sort_keys=True), flush=True)
        remaining = args.duration - (time.monotonic() - start)
        if remaining <= 0:
            return
        time.sleep(min(args.interval, remaining))


if __name__ == "__main__":
    main()
