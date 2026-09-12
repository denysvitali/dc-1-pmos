#!/usr/bin/env python3
"""Measure actual sleep latency; clock reading precision alone is insufficient."""

import json
import statistics
import time
from pathlib import Path


def measure(requested_us, samples=100):
    elapsed = []
    for _ in range(samples):
        start = time.monotonic_ns()
        time.sleep(requested_us / 1_000_000)
        elapsed.append((time.monotonic_ns() - start) / 1000)
    elapsed.sort()
    return {
        "requested_us": requested_us,
        "samples": samples,
        "p50_us": round(statistics.median(elapsed), 3),
        "p95_us": round(elapsed[(95 * samples + 99) // 100 - 1], 3),
        "max_us": round(elapsed[-1], 3),
    }


if __name__ == "__main__":
    slack = Path("/proc/self/timerslack_ns")
    print(json.dumps({
        "monotonic_resolution_ns": round(time.clock_getres(time.CLOCK_MONOTONIC) * 1e9),
        "timer_slack_ns": int(slack.read_text()) if slack.exists() else None,
        "measurements": [measure(usec) for usec in (20, 200, 1000)],
    }, indent=2))
