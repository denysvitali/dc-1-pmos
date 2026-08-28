// SPDX-License-Identifier: MIT
/*
 * Controlled MN29-family ALS/proximity probe.
 *
 * The exact part and register protocol are unknown, so this tool deliberately
 * performs only a one-byte read. It never writes a data byte, which avoids
 * putting an unidentified sensor into an uncontrolled mode. Its purpose is to
 * establish whether the AP-owned i2c1 bus can reach the part; it is not a
 * sensor driver. The MediaTek driver rejects the original zero-length message
 * with its null buffer, so that address-only request never reached the wire.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int probe_address(int fd, unsigned char address, unsigned char *value)
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

int main(void)
{
	const unsigned char address = 0x49;
	unsigned char value = 0;
	unsigned long functions = 0;
	int ret;
	int fd;

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

	ret = probe_address(fd, address, &value);
	if (ret < 0) {
		if (errno == ENXIO || errno == EREMOTEIO)
			printf("MN29 probe: no ACK at i2c1 0x%02x\n", address);
		else
			fprintf(stderr, "MN29 probe: i2c1 0x%02x read failed: %s\n",
				address, strerror(errno));
		close(fd);
		return 2;
	}

	printf("MN29 probe: ACK at i2c1 0x%02x (read 0x%02x); "
	       "protocol still unidentified\n", address, value);
	close(fd);
	return 0;
}
