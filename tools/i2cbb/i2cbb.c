// Bit-bang I2C on two GPIO lines via the gpio chardev v2 uapi, to probe a bus
// whose AP controller is not enabled in the device tree. Open-drain is
// emulated the usual way: "high" releases the line to input (the pin's own
// pull-up drives it), "low" drives it as output-0.
//
// usage: i2cbb <chip> <scl-offset> <sda-offset> [addr]
//   no addr -> scan 0x08..0x77; addr -> probe that address only

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "gpio_uapi.h"

static int line_fd(int chip, unsigned int off)
{
	struct gpio_v2_line_request req;

	memset(&req, 0, sizeof(req));
	req.offsets[0] = off;
	req.num_lines = 1;
	req.config.flags = GPIO_V2_LINE_FLAG_INPUT;
	snprintf(req.consumer, sizeof(req.consumer), "i2cbb");

	if (ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
		fprintf(stderr, "GET_LINE %u: %s\n", off, strerror(errno));
		exit(1);
	}
	return req.fd;
}

// Release the line (input, pulled high) or drive it low (output 0).
static void drive(int fd, int high)
{
	struct gpio_v2_line_config cfg;

	memset(&cfg, 0, sizeof(cfg));
	if (high) {
		cfg.flags = GPIO_V2_LINE_FLAG_INPUT;
	} else {
		cfg.flags = GPIO_V2_LINE_FLAG_OUTPUT;
		cfg.num_attrs = 1;
		cfg.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
		cfg.attrs[0].attr.values = 0;
		cfg.attrs[0].mask = 1;
	}
	if (ioctl(fd, GPIO_V2_LINE_SET_CONFIG_IOCTL, &cfg) < 0) {
		fprintf(stderr, "SET_CONFIG: %s\n", strerror(errno));
		exit(1);
	}
}

static int sense(int fd)
{
	struct gpio_v2_line_values v;

	memset(&v, 0, sizeof(v));
	v.mask = 1;
	if (ioctl(fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0) {
		fprintf(stderr, "GET_VALUES: %s\n", strerror(errno));
		exit(1);
	}
	return v.bits & 1;
}

static void tick(void)
{
	struct timespec ts = { 0, 5000 };  // 5 us -> ~50 kHz at best

	nanosleep(&ts, NULL);
}

static int scl, sda;

static void scl_high(void)
{
	int i;

	drive(scl, 1);
	// Honour clock stretching: the line is an input now, so we can see it.
	for (i = 0; i < 1000 && !sense(scl); i++)
		tick();
	tick();
}

static void scl_low(void) { drive(scl, 0); tick(); }

static void bb_start(void)
{
	drive(sda, 1);
	scl_high();
	drive(sda, 0);
	tick();
	scl_low();
}

static void bb_stop(void)
{
	drive(sda, 0);
	tick();
	scl_high();
	drive(sda, 1);
	tick();
}

static int bb_write_byte(uint8_t b)
{
	int i, ack;

	for (i = 7; i >= 0; i--) {
		drive(sda, (b >> i) & 1);
		tick();
		scl_high();
		scl_low();
	}
	drive(sda, 1);          // release for the slave's ACK
	scl_high();
	ack = !sense(sda);      // ACK is the slave pulling SDA low
	scl_low();
	return ack;
}

static uint8_t bb_read_byte(int ack)
{
	uint8_t v = 0;
	int i;

	drive(sda, 1);
	for (i = 7; i >= 0; i--) {
		scl_high();
		v |= sense(sda) << i;
		scl_low();
	}
	drive(sda, !ack);
	tick();
	scl_high();
	scl_low();
	drive(sda, 1);
	return v;
}

static int probe(uint8_t addr)
{
	int ack;

	bb_start();
	ack = bb_write_byte(addr << 1);
	bb_stop();
	return ack;
}

// Register read: write the register index, repeated START, then read n bytes.
static int reg_read(uint8_t addr, uint8_t reg, uint8_t *out, int n)
{
	int i;

	bb_start();
	if (!bb_write_byte(addr << 1))
		goto nak;
	if (!bb_write_byte(reg))
		goto nak;
	bb_start();
	if (!bb_write_byte((addr << 1) | 1))
		goto nak;
	for (i = 0; i < n; i++)
		out[i] = bb_read_byte(i != n - 1);
	bb_stop();
	return 0;
nak:
	bb_stop();
	return -1;
}

static int reg_write(uint8_t addr, uint8_t reg, uint8_t val)
{
	int ok;

	bb_start();
	ok = bb_write_byte(addr << 1) && bb_write_byte(reg) && bb_write_byte(val);
	bb_stop();
	return ok ? 0 : -1;
}

int main(int argc, char **argv)
{
	int chip, i;
	char path[64];

	if (argc < 4) {
		fprintf(stderr, "usage: %s <chip> <scl> <sda> [addr]\n", argv[0]);
		return 2;
	}
	snprintf(path, sizeof(path), "/dev/gpiochip%s", argv[1]);
	chip = open(path, O_RDWR);
	if (chip < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return 1;
	}
	scl = line_fd(chip, atoi(argv[2]));
	sda = line_fd(chip, atoi(argv[3]));

	// Idle state, and a sanity check that the bus is pulled up at all.
	drive(scl, 1);
	drive(sda, 1);
	tick();
	printf("idle: scl=%d sda=%d\n", sense(scl), sense(sda));

	if (argc >= 8 && !strcmp(argv[4], "dump")) {
		uint8_t a = strtol(argv[5], NULL, 0);
		int start = strtol(argv[6], NULL, 0);
		int n = strtol(argv[7], NULL, 0);
		uint8_t buf[256];

		if (reg_read(a, start, buf, n) < 0) {
			printf("nak\n");
			return 1;
		}
		for (i = 0; i < n; i++) {
			if (i % 16 == 0)
				printf("%s%02x:", i ? "\n" : "", start + i);
			printf(" %02x", buf[i]);
		}
		printf("\n");
		return 0;
	}

	// log <addr> <seconds>: timestamped 16-bit XYZ, for mount-matrix work.
	if (argc >= 7 && !strcmp(argv[4], "log")) {
		uint8_t a = strtol(argv[5], NULL, 0);
		int secs = strtol(argv[6], NULL, 0);
		struct timespec t0, now;
		uint8_t b[6];

		clock_gettime(CLOCK_MONOTONIC, &t0);
		for (;;) {
			clock_gettime(CLOCK_MONOTONIC, &now);
			double dt = (now.tv_sec - t0.tv_sec) +
				    (now.tv_nsec - t0.tv_nsec) / 1e9;

			if (dt > secs)
				break;
			if (reg_read(a, 0x0d, b, 6) == 0)
				printf("%.2f %d %d %d\n", dt,
				       (int16_t)(b[0] | b[1] << 8),
				       (int16_t)(b[2] | b[3] << 8),
				       (int16_t)(b[4] | b[5] << 8));
			fflush(stdout);
			usleep(200000);
		}
		return 0;
	}

	if (argc >= 8 && !strcmp(argv[4], "w")) {
		uint8_t a = strtol(argv[5], NULL, 0);
		uint8_t r = strtol(argv[6], NULL, 0);
		uint8_t v = strtol(argv[7], NULL, 0);

		printf("write 0x%02x[0x%02x]=0x%02x: %s\n", a, r, v,
		       reg_write(a, r, v) == 0 ? "ok" : "nak");
		return 0;
	}

	if (argc >= 5) {
		uint8_t a = strtol(argv[4], NULL, 0);

		printf("0x%02x: %s\n", a, probe(a) ? "ACK" : "nak");
		return 0;
	}

	for (i = 0x08; i <= 0x77; i++)
		if (probe(i))
			printf("found 0x%02x\n", i);
	printf("scan done\n");
	return 0;
}
