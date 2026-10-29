#!/usr/bin/env python3
"""Run the shipped sensor C with an observing I2C/PM fault-injection harness.

No device access. The PM model includes fatal runtime callback errors and
balanced get/put accounting; the native kernel build separately checks APIs.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "pmaports/device/testing/linux-postmarketos-mediatek-mt6789/mn29005.c"

HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef EREMOTEIO
#define EREMOTEIO 121
#endif
typedef uint8_t u8;
#define BIT(x) (1UL << (x))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define I2C_M_RD 1
#define I2C_CLIENT_TEN 16
#define I2C_FUNC_I2C 1
#define IIO_LIGHT 1
#define IIO_CHAN_INFO_RAW 0
#define IIO_VAL_INT 1
#define INDIO_DIRECT_MODE 1
#define dev_err_ratelimited(...) ((void)0)
static unsigned long jiffies;
#define msecs_to_jiffies(x) (x)
#define time_after_eq(a, b) ((long)((a) - (b)) >= 0)
static void msleep(unsigned int ms) { jiffies += ms; }
static unsigned int get_unaligned_le16(const u8 *p) { return p[0] | p[1] << 8; }
struct mutex { bool held; };
static void mutex_init(struct mutex *m) { m->held = false; }
static void mutex_lock(struct mutex *m) { assert(!m->held); m->held = true; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held = false; }
struct device { void *data; bool enabled, active; int refs, error; };
struct i2c_adapter { bool supported; };
struct i2c_client { struct device dev; struct i2c_adapter *adapter; int addr, flags; };
struct i2c_msg { int addr, flags, len; u8 *buf; };
struct iio_dev;
struct iio_chan_spec { int type; unsigned long info_mask_separate; };
struct iio_info { int (*read_raw)(struct iio_dev *, const struct iio_chan_spec *, int *, int *, long); };
struct iio_dev {
    const char *name;
    const struct iio_info *info;
    int modes, num_channels;
    const struct iio_chan_spec *channels;
    void *priv;
};
static int register_error, allocation_error, set_status_error;
static struct iio_dev *devm_iio_device_alloc(struct device *d, size_t size) {
    if (allocation_error) return NULL;
    struct iio_dev *i = calloc(1, sizeof(*i)); assert(i);
    i->priv = calloc(1, size); assert(i->priv); d->data = i; return i;
}
static void *iio_priv(struct iio_dev *i) { return i->priv; }
static void *dev_get_drvdata(struct device *d) { return d->data; }
static void *i2c_get_clientdata(struct i2c_client *c) { return c->dev.data; }
static void i2c_set_clientdata(struct i2c_client *c, void *p) { c->dev.data = p; }
static int iio_device_register(struct iio_dev *i) { return register_error; }
static void iio_device_unregister(struct iio_dev *i) { (void)i; }
static bool i2c_check_functionality(struct i2c_adapter *a, int feature) { return a->supported; }
static int mn_runtime_resume(struct device *d);
static int mn_runtime_suspend(struct device *d);
static void pm_runtime_enable(struct device *d) { d->enabled = true; }
static void pm_runtime_disable(struct device *d) { d->enabled = false; }
static int pm_runtime_set_suspended(struct device *d) {
    if (set_status_error) return set_status_error;
    if (d->enabled && !d->error) return -EAGAIN;
    d->active = false; d->error = 0; return 0;
}
static int pm_runtime_resume_and_get(struct device *d) {
    int ret;
    assert(d->enabled);
    if (d->error) return -EINVAL;
    if (!d->active) {
        ret = mn_runtime_resume(d);
        if (ret) { d->error = ret; return ret; }
        d->active = true;
    }
    d->refs++; return 0;
}
static int pm_runtime_put_sync_suspend(struct device *d) {
    int ret;
    assert(d->refs > 0); d->refs--;
    if (d->refs) return 0;
    if (d->error) return -EINVAL;
    ret = mn_runtime_suspend(d);
    if (ret) d->error = ret;
    else d->active = false;
    return ret;
}
static u8 regs[256], baseline[256];
static int calls, writes, sample_reads, fail_at, short_at, corrupt_readback;
static u8 status = 0x10;
static unsigned int raw_value = 0x1234;
static int i2c_transfer(struct i2c_adapter *a, struct i2c_msg *m, int count) {
    assert(count == 2 && m[0].addr == 0x49 && m[1].addr == 0x49);
    assert(!m[0].flags && m[1].flags == I2C_M_RD && m[0].len == 1);
    calls++;
    if (calls == fail_at) return -EREMOTEIO;
    if (calls == short_at) return 1;
    unsigned int reg = m[0].buf[0];
    assert(reg + m[1].len <= sizeof(regs));
    memcpy(m[1].buf, regs + reg, m[1].len);
    if (reg == 0x38 && m[1].len == 7) {
        sample_reads++;
        m[1].buf[0] = status; m[1].buf[3] = raw_value; m[1].buf[4] = raw_value >> 8;
    }
    if (corrupt_readback && writes && reg == 0x10) m[1].buf[0] ^= 1;
    return 2;
}
static int i2c_master_send(struct i2c_client *c, const u8 *b, int size) {
    assert(c->addr == 0x49 && size >= 2 && size <= 5);
    assert(b[0] < 0x20 || b[0] == 0x30 || b[0] == 0x38);
    calls++; writes++;
    /* A failed write may have changed a byte before the error was reported. */
    if (calls == fail_at || calls == short_at) {
        regs[b[0]] = b[1];
        return calls == fail_at ? -EREMOTEIO : size - 1;
    }
    memcpy(regs + b[0], b + 1, size - 1); return size;
}
'''

MAIN = r'''
static struct i2c_adapter adapter;
static struct i2c_client client;
static void reset(void) {
    memset(&client, 0, sizeof(client)); memset(regs, 0, sizeof(regs));
    adapter.supported = true; client.adapter = &adapter; client.addr = 0x49;
    regs[0] = 0x30; regs[1] = 0xae; regs[2] = 3; regs[3] = 0x88; regs[4] = 0x12;
    regs[0x10] = 0x43; regs[0x11] = 0x50; regs[0x12] = 0x60;
    regs[0x30] = 5; regs[0x31] = 2; regs[0x32] = 0xfa; regs[0x33] = 0x77;
    regs[0x38] = 2;
    memcpy(baseline, regs, sizeof(regs));
    calls = writes = sample_reads = fail_at = short_at = corrupt_readback = 0;
    register_error = allocation_error = set_status_error = 0;
    status = 0x10; raw_value = 0x1234; jiffies = 0;
}
static void destroy(void) {
    struct iio_dev *i = client.dev.data;
    if (i) { free(i->priv); free(i); client.dev.data = NULL; }
}
static struct mn29005 *bind(void) {
    assert(mn_probe(&client) == 0); assert(writes == 0);
    calls = 0; return iio_priv(client.dev.data);
}
static int measure(int *value) {
    return mn_read_raw(client.dev.data, &mn_channels[0], value, NULL, IIO_CHAN_INFO_RAW);
}
static void restored(void) {
    assert(memcmp(regs, baseline, sizeof(regs)) == 0);
    assert(client.dev.refs == 0);
}
int main(void) {
    int value, ret, total, before;
    struct mn29005 *s;
    reset(); s = bind();
    assert(measure(&value) == IIO_VAL_INT && value == 0x1234);
    total = calls; restored(); assert(!client.dev.active && !s->changed);
    assert(jiffies == 30); mn_remove(&client); destroy();

    /* Every transfer in activation, sampling, and restoration can fail. */
    for (int short_io = 0; short_io < 2; short_io++) {
        for (int step = 1; step <= total; step++) {
            reset(); s = bind();
            if (short_io) short_at = step; else fail_at = step;
            value = -1; ret = measure(&value);
            assert(ret < 0 && client.dev.refs == 0);
            before = sample_reads;
            if (s->faulted) {
                assert(measure(&value) < 0 && sample_reads == before);
                /* Even an externally reset PM error cannot bypass the latch. */
                client.dev.error = 0; client.dev.active = true;
                assert(measure(&value) == -EIO && sample_reads == before);
            } else {
                restored(); assert(!client.dev.active && !client.dev.error);
                assert(measure(&value) == IIO_VAL_INT);
            }
            mn_remove(&client); restored(); destroy();
        }
    }
    printf("PASS: %d negative/short transfer failure points and PM reference balance\n", total * 2);

    for (int step = 1; step <= 5; step++) {
        reset(); fail_at = step; assert(mn_probe(&client) == -EREMOTEIO);
        assert(!writes && !client.dev.enabled); destroy();
    }
    reset(); client.addr = 0x48; assert(mn_probe(&client) == -ENODEV); assert(!calls);
    reset(); client.flags = I2C_CLIENT_TEN; assert(mn_probe(&client) == -ENODEV); assert(!calls);
    reset(); adapter.supported = false; assert(mn_probe(&client) == -ENODEV); assert(!calls);
    reset(); allocation_error = 1; assert(mn_probe(&client) == -ENOMEM);
    reset(); regs[4] = 0; assert(mn_probe(&client) == -ENODEV); assert(!writes); destroy();
    reset(); regs[0] |= 2; assert(mn_probe(&client) == -EBUSY); assert(!writes); destroy();
    reset(); regs[2] = 2; assert(mn_probe(&client) == -EBUSY); assert(!writes); destroy();
    reset(); register_error = -ENOMEM; assert(mn_probe(&client) == -ENOMEM);
    assert(!client.dev.enabled && !writes); destroy();
    reset(); set_status_error = -EBUSY; assert(mn_probe(&client) == -EBUSY);
    assert(!client.dev.enabled && !writes); destroy();
    puts("PASS: identity, ownership, allocation, registration and probe refusal paths");

    reset(); s = bind(); status = 0;
    assert(measure(&value) == -ETIMEDOUT && jiffies == 500); restored();
    status = 0x10; assert(measure(&value) == IIO_VAL_INT); restored();
    for (unsigned int flag = 0x20; flag <= 0x80; flag <<= 1) {
        status = flag | 0x10; assert(measure(&value) == -ERANGE); restored();
    }
    for (unsigned int flag = 8; flag <= 24; flag += 8) {
        status = flag;
        raw_value = 0; assert(measure(&value) == IIO_VAL_INT && value == 0);
        raw_value = 65535; assert(measure(&value) == IIO_VAL_INT && value == 65535);
    }
    u8 bytes[8] = {0}; before = calls;
    assert(mn_read(s, 0xff, bytes, 1) == -EINVAL);
    assert(mn_read(s, MN_STATUS, bytes, 8) == -EINVAL);
    assert(mn_read(s, MN_STATUS, NULL, 7) == -EINVAL);
    assert(mn_write(s, 0x23, bytes, 1) == -EINVAL);
    assert(mn_write(s, MN_CONFIG, bytes, 8) == -EINVAL);
    assert(mn_write(s, MN_CONFIG, NULL, 3) == -EINVAL);
    assert(mn_read_raw(client.dev.data, &mn_channels[0], &value, NULL, 99) == -EINVAL);
    assert(calls == before); mn_remove(&client); destroy();
    puts("PASS: bounded timeout, saturation, all readiness flags, raw boundaries and transfer allowlist");

    reset(); s = bind(); corrupt_readback = 1;
    assert(measure(&value) == -EIO && s->faulted && client.dev.refs == 0);
    corrupt_readback = 0; before = sample_reads;
    assert(measure(&value) < 0 && sample_reads == before);
    mn_remove(&client); restored(); destroy();

    reset(); s = bind(); assert(mn_runtime_resume(&client.dev) == 0);
    mn_shutdown(&client); restored(); assert(!client.dev.enabled); destroy();
    puts("PASS: restore readback mismatch latches failure; shutdown restores hardware");
}
'''


class SensorDriverTest(unittest.TestCase):
    def test_shipped_driver_fault_paths(self):
        source = SOURCE.read_text().split("static const struct dev_pm_ops mn_pm_ops", 1)[0]
        source = "\n".join(line for line in source.splitlines() if not line.startswith("#include"))
        with tempfile.TemporaryDirectory(prefix="dc1-mn29005-") as directory:
            path = Path(directory)
            (path / "test.c").write_text(HARNESS + source + MAIN)
            subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra",
                            "-Werror", "-Wno-unused-parameter", str(path / "test.c"),
                            "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
