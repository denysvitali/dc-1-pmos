// SPDX-License-Identifier: GPL-2.0-only
/*
 * MN29005 fixed-gain raw ambient light support.
 *
 * Protocol reference: MediaTek's GPL driver published by OnePlusOSS in
 * android_kernel_oneplus_mt6893 at 48f1797695e24d46986a7c87dd91dd21cbf8c342,
 * drivers/misc/mediatek/sensor/2.0/mn29005/mn29xxx.{c,h} (Copyright 2020
 * MediaTek Inc.). Only its documented ALS registers are used here.
 *
 * No firmware, automatic gain, lux conversion, proximity, or IRQ ownership.
 * Boards must establish exclusive bus ownership before enabling the DT node.
 * Every measurement restores the idle/off state captured at probe.
 */
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/iio/iio.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pm_runtime.h>
#include <linux/string.h>
#include <linux/unaligned.h>

#define MN_ENABLE		0x00
#define MN_INTERRUPT		0x01
#define MN_POWER		0x02
#define MN_ID			0x03
#define MN_CONFIG		0x10
#define MN_THRESHOLDS		0x30
#define MN_STATUS		0x38
#define MN_REVISION		0x1288
#define MN_OFF_RESET		0x01
#define MN_ON_RUN		0x02
#define MN_MODE_ALS		0x01
#define MN_MODE_MASK		0x03
#define MN_DARK_PIXEL_OFF		0x0e
#define MN_INTEGRATION_512	(8 << 2)
#define MN_GAIN_MID		0x01
#define MN_CHANNEL_ONE		0x10
#define MN_COMPARE_RESET_LOCK	0x01
#define MN_COMPARE_RUN_UNLOCK	0x02
#define MN_SATURATED		0xe0
#define MN_COMPARISON_VALID	0x18

struct mn29005 {
	struct i2c_client *client;
	struct mutex lock;
	struct mutex read_lock;
	u8 control[3];
	u8 config[3];
	u8 thresholds[4];
	u8 status_control;
	bool changed;
	bool faulted;
};

static bool mn_read_range(u8 reg, size_t size)
{
	return (reg == MN_ENABLE && size == 3) ||
	       (reg == MN_ID && size == 2) ||
	       (reg == MN_CONFIG && size == 3) ||
	       (reg == MN_THRESHOLDS && size == 4) ||
	       (reg == MN_STATUS && (size == 1 || size == 7));
}

static int mn_read(struct mn29005 *sensor, u8 reg, u8 *data, size_t size)
{
	struct i2c_client *client = sensor->client;
	struct i2c_msg messages[] = {
		{ .addr = client->addr, .len = 1, .buf = &reg },
		{ .addr = client->addr, .flags = I2C_M_RD, .len = size, .buf = data },
	};
	int ret;

	if (client->addr != 0x49 || !data || !mn_read_range(reg, size))
		return -EINVAL;
	ret = i2c_transfer(client->adapter, messages, ARRAY_SIZE(messages));
	return ret == 2 ? 0 : ret < 0 ? ret : -EIO;
}

static int mn_write(struct mn29005 *sensor, u8 reg, const u8 *data, size_t size)
{
	u8 buffer[5];
	bool valid = ((reg == MN_ENABLE || reg == MN_INTERRUPT || reg == MN_POWER ||
		       reg == MN_STATUS) && size == 1) ||
		     (reg == MN_CONFIG && size == 3) ||
		     (reg == MN_THRESHOLDS && size == 4);
	int ret;

	if (sensor->client->addr != 0x49 || !data || !valid)
		return -EINVAL;
	buffer[0] = reg;
	memcpy(buffer + 1, data, size);
	ret = i2c_master_send(sensor->client, buffer, size + 1);
	return ret == (int)size + 1 ? 0 : ret < 0 ? ret : -EIO;
}

static int mn_write_byte(struct mn29005 *sensor, u8 reg, u8 value)
{
	return mn_write(sensor, reg, &value, 1);
}

static int mn_check_restored(struct mn29005 *sensor, u8 reg,
			     const u8 *expected, size_t size)
{
	u8 actual[4];
	int ret;

	if (size > sizeof(actual))
		return -EINVAL;
	ret = mn_read(sensor, reg, actual, size);
	return ret ? ret : memcmp(actual, expected, size) ? -EIO : 0;
}

/* Try every cleanup operation once, preserving the first failure. */
static int mn_restore(struct mn29005 *sensor)
{
	int ret, error = 0;

	if (!sensor->changed)
		return 0;
#define RESTORE(op) do { ret = (op); if (ret && !error) error = ret; } while (0)
	RESTORE(mn_write_byte(sensor, MN_POWER, MN_OFF_RESET));
	RESTORE(mn_write_byte(sensor, MN_ENABLE, 0));
	RESTORE(mn_write(sensor, MN_CONFIG, sensor->config, sizeof(sensor->config)));
	RESTORE(mn_write(sensor, MN_THRESHOLDS, sensor->thresholds, sizeof(sensor->thresholds)));
	RESTORE(mn_write_byte(sensor, MN_STATUS, sensor->status_control));
	RESTORE(mn_write_byte(sensor, MN_INTERRUPT, sensor->control[1]));
	RESTORE(mn_write_byte(sensor, MN_ENABLE, sensor->control[0]));
	RESTORE(mn_write_byte(sensor, MN_POWER, sensor->control[2]));
	RESTORE(mn_check_restored(sensor, MN_ENABLE, sensor->control, sizeof(sensor->control)));
	RESTORE(mn_check_restored(sensor, MN_CONFIG, sensor->config, sizeof(sensor->config)));
	RESTORE(mn_check_restored(sensor, MN_THRESHOLDS, sensor->thresholds, sizeof(sensor->thresholds)));
#undef RESTORE
	if (error) {
		sensor->faulted = true;
		dev_err_ratelimited(&sensor->client->dev, "idle restoration failed: %d\n", error);
	} else {
		sensor->changed = false;
	}
	return error;
}

static int mn_runtime_resume(struct device *dev)
{
	struct mn29005 *sensor = iio_priv(dev_get_drvdata(dev));
	/* Public first-report preset: pre mode, mid gain, one cycle, CH1. */
	const u8 config[] = { MN_INTEGRATION_512 | MN_GAIN_MID, MN_CHANNEL_ONE, 0 };
	const u8 thresholds[4] = { 0 };
	int ret, cleanup;

	mutex_lock(&sensor->lock);
	if (sensor->faulted) {
		ret = -EIO;
		goto out;
	}
	sensor->changed = true;
#define SETUP(op) do { ret = (op); if (ret) goto restore; } while (0)
	SETUP(mn_write_byte(sensor, MN_POWER, MN_OFF_RESET));
	SETUP(mn_write_byte(sensor, MN_ENABLE, 0));
	SETUP(mn_write_byte(sensor, MN_INTERRUPT, MN_DARK_PIXEL_OFF));
	SETUP(mn_write(sensor, MN_CONFIG, config, sizeof(config)));
	SETUP(mn_write(sensor, MN_THRESHOLDS, thresholds, sizeof(thresholds)));
	SETUP(mn_write_byte(sensor, MN_STATUS, MN_COMPARE_RESET_LOCK));
	SETUP(mn_write_byte(sensor, MN_STATUS, MN_COMPARE_RUN_UNLOCK));
	SETUP(mn_write_byte(sensor, MN_ENABLE, MN_MODE_ALS));
	SETUP(mn_write_byte(sensor, MN_POWER, MN_ON_RUN));
#undef SETUP
	ret = 0;
	goto out;
restore:
	cleanup = mn_restore(sensor);
	if (cleanup)
		ret = cleanup;
out:
	mutex_unlock(&sensor->lock);
	return ret;
}

static int mn_runtime_suspend(struct device *dev)
{
	struct mn29005 *sensor = iio_priv(dev_get_drvdata(dev));
	int ret;

	mutex_lock(&sensor->lock);
	ret = mn_restore(sensor);
	mutex_unlock(&sensor->lock);
	return ret;
}

static int mn_sample(struct mn29005 *sensor, int *value)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(500);
	u8 bytes[7];
	int ret;

	/* A failed suspend can leave PM active: check the latch on this path too. */
	if (sensor->faulted)
		return -EIO;
	msleep(30);
	for (;;) {
		ret = mn_read(sensor, MN_STATUS, bytes, sizeof(bytes));
		if (ret)
			return ret;
		if (bytes[0] & MN_SATURATED)
			return -ERANGE;
		/* The public driver considers only both-clear comparison flags unready. */
		if (bytes[0] & MN_COMPARISON_VALID) {
			*value = get_unaligned_le16(bytes + 3);
			return 0;
		}
		if (time_after_eq(jiffies, deadline))
			return -ETIMEDOUT;
		msleep(10);
	}
}

static int mn_read_raw(struct iio_dev *indio, const struct iio_chan_spec *channel,
		       int *value, int *value2, long mask)
{
	struct mn29005 *sensor = iio_priv(indio);
	struct device *dev = &sensor->client->dev;
	int ret, cleanup;

	if (mask != IIO_CHAN_INFO_RAW || channel->type != IIO_LIGHT)
		return -EINVAL;
	mutex_lock(&sensor->read_lock);
	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0) {
		/* A verified rollback permits retry after a transient resume I/O error. */
		mutex_lock(&sensor->lock);
		if (!sensor->changed && !sensor->faulted)
			pm_runtime_set_suspended(dev);
		mutex_unlock(&sensor->lock);
		goto out;
	}
	mutex_lock(&sensor->lock);
	ret = mn_sample(sensor, value);
	mutex_unlock(&sensor->lock);
	cleanup = pm_runtime_put_sync_suspend(dev);
	if (cleanup < 0)
		ret = cleanup;
	else if (!ret)
		ret = IIO_VAL_INT;
out:
	mutex_unlock(&sensor->read_lock);
	return ret;
}

static const struct iio_info mn_info = { .read_raw = mn_read_raw };
static const struct iio_chan_spec mn_channels[] = {
	{ .type = IIO_LIGHT, .info_mask_separate = BIT(IIO_CHAN_INFO_RAW) },
};

static int mn_probe(struct i2c_client *client)
{
	struct iio_dev *indio;
	struct mn29005 *sensor;
	u8 revision[2];
	int ret;

	if (client->addr != 0x49 || (client->flags & I2C_CLIENT_TEN) ||
	    !i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENODEV;
	indio = devm_iio_device_alloc(&client->dev, sizeof(*sensor));
	if (!indio)
		return -ENOMEM;
	sensor = iio_priv(indio);
	sensor->client = client;
	mutex_init(&sensor->lock);
	mutex_init(&sensor->read_lock);
	i2c_set_clientdata(client, indio);
	ret = mn_read(sensor, MN_ID, revision, sizeof(revision));
	if (ret)
		return ret;
	if (get_unaligned_le16(revision) != MN_REVISION)
		return -ENODEV;
	ret = mn_read(sensor, MN_ENABLE, sensor->control, sizeof(sensor->control));
	if (ret)
		return ret;
	if ((sensor->control[0] & MN_MODE_MASK) || !(sensor->control[2] & MN_OFF_RESET))
		return -EBUSY;
	ret = mn_read(sensor, MN_CONFIG, sensor->config, sizeof(sensor->config));
	if (ret)
		return ret;
	ret = mn_read(sensor, MN_THRESHOLDS, sensor->thresholds, sizeof(sensor->thresholds));
	if (ret)
		return ret;
	ret = mn_read(sensor, MN_STATUS, &sensor->status_control, 1);
	if (ret)
		return ret;
	sensor->status_control &= MN_MODE_MASK;
	indio->name = "mn29005";
	indio->info = &mn_info;
	indio->modes = INDIO_DIRECT_MODE;
	indio->channels = mn_channels;
	indio->num_channels = ARRAY_SIZE(mn_channels);
	ret = pm_runtime_set_suspended(&client->dev);
	if (ret)
		return ret;
	pm_runtime_enable(&client->dev);
	ret = iio_device_register(indio);
	if (ret)
		pm_runtime_disable(&client->dev);
	return ret;
}

static void mn_remove(struct i2c_client *client)
{
	struct iio_dev *indio = i2c_get_clientdata(client);
	struct mn29005 *sensor = iio_priv(indio);

	iio_device_unregister(indio);
	pm_runtime_disable(&client->dev);
	mutex_lock(&sensor->lock);
	mn_restore(sensor);
	mutex_unlock(&sensor->lock);
}

static void mn_shutdown(struct i2c_client *client)
{
	pm_runtime_disable(&client->dev);
	mn_runtime_suspend(&client->dev);
}

static const struct dev_pm_ops mn_pm_ops = {
	RUNTIME_PM_OPS(mn_runtime_suspend, mn_runtime_resume, NULL)
	SYSTEM_SLEEP_PM_OPS(pm_runtime_force_suspend, pm_runtime_force_resume)
};

static const struct i2c_device_id mn_ids[] = { { "mn29005", 0 }, { } };
MODULE_DEVICE_TABLE(i2c, mn_ids);

/*
 * Reuse the compatible from the public protocol driver. Probe still checks
 * revision 0x1288; other MN29-family devices are not supported.
 */
static const struct of_device_id mn_of_match[] = {
	{ .compatible = "mediatek,mn29xxxals" },
	{ }
};
MODULE_DEVICE_TABLE(of, mn_of_match);

static struct i2c_driver mn_driver = {
	.driver = {
		.name = "mn29005",
		.pm = pm_ptr(&mn_pm_ops),
		.of_match_table = mn_of_match,
	},
	.probe = mn_probe,
	.remove = mn_remove,
	.shutdown = mn_shutdown,
	.id_table = mn_ids,
};
module_i2c_driver(mn_driver);

MODULE_DESCRIPTION("MN29005 fixed-gain raw ambient light sensor");
MODULE_LICENSE("GPL");
