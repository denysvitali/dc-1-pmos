// SPDX-License-Identifier: MIT
/*
 * Controlled MN29-family ALS/proximity probe.
 *
 * The exact part and register protocol are unknown, so this tool deliberately
 * performs only current-address reads. It never writes a register address or
 * data byte, which avoids putting an unidentified sensor into an uncontrolled
 * mode. Its purpose is to establish whether the AP-owned i2c1 bus can reach
 * the part and whether its read-only byte stream reacts to the environment;
 * it is not a sensor driver. The MediaTek driver rejects the original
 * zero-length message with its null buffer, so that address-only request never
 * reached the wire.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_SAMPLES 1U
#define DEFAULT_INTERVAL_MS 100U
#define MAX_SAMPLES 1024U
#define MAX_INTERVAL_MS 60000U

static int read_current_byte(int fd, unsigned char address,
			     unsigned char *value)
{
	struct i2c_msg message = {
		.addr = address,
		.flags = I2C_M_RD,
		.len = 1,
		.buf = value,
	};
	struct i2c_rdwr_ioctl_data data = {
		.msgs = &message,
		.nmsgs = 1,
	};

	return ioctl(fd, I2C_RDWR, &data);
}

static int parse_uint(const char *text, unsigned int min, unsigned int max,
		      unsigned int *value)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 10);
	if (errno || !end || *end != '\0' || parsed < min || parsed > max)
		return -1;

	*value = (unsigned int)parsed;
	return 0;
}

static void usage(const char *program)
{
	fprintf(stderr,
		"Usage: %s [--samples COUNT] [--interval-ms MILLISECONDS]\n"
		"\n"
		"Perform current-address reads only; never write to the sensor.\n"
		"COUNT must be 1..%u and MILLISECONDS 0..%u.\n",
		program, MAX_SAMPLES, MAX_INTERVAL_MS);
}

static int sleep_ms(unsigned int interval_ms)
{
	struct timespec delay = {
		.tv_sec = interval_ms / 1000U,
		.tv_nsec = (long)(interval_ms % 1000U) * 1000000L,
	};

	while (nanosleep(&delay, &delay) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const unsigned char address = 0x49;
	unsigned int samples = DEFAULT_SAMPLES;
	unsigned int interval_ms = DEFAULT_INTERVAL_MS;
	unsigned long functions = 0;
	unsigned int i;
	int fd;

	for (i = 1; i < (unsigned int)argc; i++) {
		if (!strcmp(argv[i], "--samples") && i + 1 < (unsigned int)argc) {
			if (parse_uint(argv[++i], 1, MAX_SAMPLES, &samples) < 0) {
				usage(argv[0]);
				return 64;
			}
		} else if (!strcmp(argv[i], "--interval-ms") &&
			   i + 1 < (unsigned int)argc) {
			if (parse_uint(argv[++i], 0, MAX_INTERVAL_MS,
				       &interval_ms) < 0) {
				usage(argv[0]);
				return 64;
			}
		} else if (!strcmp(argv[i], "--help")) {
			usage(argv[0]);
			return 0;
		} else {
			usage(argv[0]);
			return 64;
		}
	}

	fd = open("/dev/i2c-1", O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "mn29-probe: cannot open /dev/i2c-1: %s\n",
			strerror(errno));
		return 1;
	}

	if (ioctl(fd, I2C_FUNCS, &functions) < 0 ||
	    !(functions & I2C_FUNC_I2C)) {
		fprintf(stderr, "mn29-probe: /dev/i2c-1 does not support raw I2C\n");
		close(fd);
		return 1;
	}

	for (i = 0; i < samples; i++) {
		unsigned char value = 0;

		if (read_current_byte(fd, address, &value) < 0) {
			if (errno == ENXIO || errno == EREMOTEIO)
				printf("MN29 probe: no ACK at i2c1 0x%02x\n",
				       address);
			else
				fprintf(stderr,
					"MN29 probe: i2c1 0x%02x read failed: %s\n",
					address, strerror(errno));
			close(fd);
			return 2;
		}

		if (samples == 1)
			printf("MN29 probe: ACK at i2c1 0x%02x (read 0x%02x); "
			       "protocol still unidentified\n", address, value);
		else
			printf("sample=%u value=0x%02x decimal=%u\n",
			       i + 1, value, value);

		if (i + 1 < samples && sleep_ms(interval_ms) < 0) {
			fprintf(stderr, "mn29-probe: sleep failed: %s\n",
				strerror(errno));
			close(fd);
			return 3;
		}
	}

	close(fd);
	return 0;
}
