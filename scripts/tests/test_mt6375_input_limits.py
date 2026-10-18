#!/usr/bin/env python3
"""Compile the patched PD input policy with an observing regmap backend.

The patch carries the complete function as context, so this offline test runs
the shipped C rather than a Python translation of the voltage/current math.
No device, kernel build, network or charger writes are involved.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "pmaports/device/testing/linux-postmarketos-mediatek-mt6789/mt6375-input-limits.patch"

HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint32_t u32;
#define READ_ONCE(x) (x)
#define DIV_ROUND_CLOSEST(x, y) (((x) + (y) / 2) / (y))
#define clamp(v, lo, hi) ((v) < (lo) ? (lo) : (v) > (hi) ? (hi) : (v))
#define rounddown(x, y) ((x) / (y) * (y))
#define GENMASK(h, l) ((~0u << (l)) & (~0u >> (31 - (h))))
#define MT6375_AICR_BOOST_UA 1500000
#define MT6375_REG_CHG_TOP2 0x21
#define MT6375_REG_CHG_AICR 0x22
#define MT6375_REG_CHG_MIVR 0x23
#define dev_info(...) ((void)0)
struct regmap { unsigned int regs[256], writes; int fail_reg; };
static struct { struct regmap *regmap; } mt6375_chg_bridge;
static int mt6375_aicr_encode(int ua, unsigned int *code) {
    /* Observe the policy's request without duplicating the chip encoder. */
    *code = ua;
    return 0;
}
static int regmap_write(struct regmap *map, unsigned int reg, unsigned int value) {
    if ((int)reg == map->fail_reg) return -EIO;
    map->regs[reg] = value;
    map->writes++;
    return 0;
}
static int regmap_update_bits(struct regmap *map, unsigned int reg,
                              unsigned int mask, unsigned int value) {
    return regmap_write(map, reg, (map->regs[reg] & ~mask) | (value & mask));
}
'''

MAIN = r'''
int main(void) {
    struct regmap map = { .fail_reg = -1 };
    const unsigned int voltages[] = {5000, 9000, 12000};
    const unsigned int codes[] = {3, 43, 73};
    const unsigned int ovp[] = {0, 2, 3};
    assert(mt6375_charger_program_input(5000, 3000) == -ENODEV);
    mt6375_chg_bridge.regmap = &map;
    for (unsigned int i = 0; i < 3; i++) {
        map.regs[0x21] = 0xfc;
        assert(mt6375_charger_program_input(voltages[i], 3000) == 0);
        assert(map.regs[0x23] == codes[i]);
        assert(map.regs[0x21] == (0xfc | ovp[i]));
    }
    for (unsigned int ma = 100; ma <= 3225; ma++) {
        assert(mt6375_charger_program_input(9000, ma) == 0);
        assert(map.regs[0x22] <= ma * 1000);
        assert(map.regs[0x22] % 25000 == 0);
        assert(ma * 1000 - map.regs[0x22] < 25000);
    }
    assert(mt6375_charger_program_input(0, 0) == 0);
    assert(map.regs[0x23] == 6 && map.regs[0x22] == 1500000);
    map.writes = 0;
    map.fail_reg = 0x21;
    assert(mt6375_charger_program_input(12000, 3000) == -EIO);
    assert(map.writes == 0);
    map.fail_reg = 0x23;
    assert(mt6375_charger_program_input(12000, 3000) == -EIO);
    assert(map.writes == 1);
    map.fail_reg = 0x22;
    assert(mt6375_charger_program_input(12000, 3000) == -EIO);
    puts("PASS: PD voltage thresholds, source budgets, detach and I/O failures");
}
'''


class InputLimitsTest(unittest.TestCase):
    def test_shipped_policy(self):
        postimage = "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                              if line.startswith((" ", "+")) and not line.startswith("+++"))
        start = postimage.index("int mt6375_charger_program_input(u32 mv, u32 ma)\n{")
        end = postimage.index("EXPORT_SYMBOL_GPL", start)
        function = postimage[start:end]
        with tempfile.TemporaryDirectory(prefix="dc1-input-limits-") as tmp:
            source = Path(tmp) / "test.c"
            binary = Path(tmp) / "test"
            source.write_text(HARNESS + function + MAIN)
            subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra",
                            "-Werror", str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
