// SPDX-License-Identifier: GPL-2.0-only
/*
 * dc1-pwrkey -- dedicated KEY_POWER reader for DC-1 charging mode.
 *
 * Charging mode (dc1-charging.target) is deliberately headless: no gdm, no
 * compositor, no session -- so nothing consumes the power key there. It
 * also cannot hand the key to logind instead: this device ships
 * /etc/systemd/logind.conf.d/10-dc1-power.conf with HandlePowerKey=ignore
 * (logind's default action would sleep/blank a panel whose frontlight
 * stays lit, and suspend is harmful here), and /etc drop-ins outrank
 * anything charging mode could stage under /run at generator time -- so
 * charging mode ships its own minimal reader rather than fighting the
 * precedence order. A LONG press on the PMIC power button still performs
 * a hardware reset underneath all of this; that lands in LK and then in a
 * normal boot, which is exactly the escape hatch the poweroff-flag design
 * expects (systemd never ran, so no clean-poweroff flag gets recorded).
 *
 * Usage: dc1-pwrkey [SECONDS]
 *
 *   SECONDS   watch window; "0" or omitted waits forever.
 *
 * Scans $DC1_INPUT_DIR (default /dev/input) for event* devices, opens each
 * O_RDONLY, and select()s across all of them until the first EV_KEY
 * KEY_POWER press (value 1).
 *
 * Exit codes:
 *   0    KEY_POWER pressed ("KEY_POWER pressed" on stdout)
 *   62   timed out with no press -- distinct from "broken" so the charging
 *        monitor could tell "nothing happened" from "respawn me"
 *   1    fatal: select() failed, every watched device vanished mid-watch,
 *        or there was nothing to watch and no deadline either (the monitor
 *        respawns on any non-zero exit, so its 5 s backoff is the retry)
 *   2    usage error
 *
 * A degraded SCAN is not fatal by design: a missing or empty input
 * directory (cold udev, a test sandbox) selects on zero descriptors and
 * runs out the clock to 62 -- that keeps `DC1_INPUT_DIR=/nonexistent
 * dc1-pwrkey 1` -> 62 deterministic for smoke tests and harmless on device.
 *
 * Partial reads are carried over: bytes land in an aligned buffer and only
 * whole sizeof(struct input_event) chunks are interpreted, so a key event
 * split across two read()s is still recognized.
 *
 * UAPI only (<linux/input.h> and <linux/input-event-codes.h>) plus libc;
 * no runtime dependency beyond libc. Test hook: DC1_INPUT_DIR points the
 * scan at a private directory.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#include <linux/input-event-codes.h>
#include <linux/input.h>

#define DC1_EXIT_PRESSED	0
#define DC1_EXIT_FATAL		1
#define DC1_EXIT_USAGE		2
#define DC1_EXIT_TIMEOUT	62
#define DC1_MAX_DEVS		64
/* One year: effectively forever, but keeps the deadline math bounded. */
#define DC1_MAX_TIMEOUT_SECS	31536000LL

static int now_ms(long long *out)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		return -1;
	*out = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
	return 0;
}

static int parse_timeout(const char *arg, long long *seconds)
{
	char *end;
	long long val;

	errno = 0;
	val = strtoll(arg, &end, 10);
	if (errno != 0 || end == arg || *end != '\0' || val < 0 ||
	    val > DC1_MAX_TIMEOUT_SECS)
		return -1;
	*seconds = val;
	return 0;
}

/* Interpret every whole event in buf, carrying any partial tail over.
 * memcpy keeps the struct access alignment- and aliasing-safe. */
static void consume_events(unsigned char *buf, size_t *have)
{
	size_t off = 0;

	while (*have - off >= sizeof(struct input_event)) {
		struct input_event ev;

		memcpy(&ev, buf + off, sizeof(ev));
		off += sizeof(ev);
		if (ev.type == EV_KEY && ev.code == KEY_POWER &&
		    ev.value == 1) {
			fputs("KEY_POWER pressed\n", stdout);
			fflush(stdout);
			exit(DC1_EXIT_PRESSED);
		}
	}
	if (off > 0) {
		memmove(buf, buf + off, *have - off);
		*have -= off;
	}
}

static int wait_out_deadline(long long deadline_ms)
{
	for (;;) {
		long long now, remain;
		struct timespec ts;

		if (now_ms(&now) != 0) {
			perror("dc1-pwrkey: clock_gettime");
			return DC1_EXIT_FATAL;
		}
		remain = deadline_ms - now;
		if (remain <= 0)
			return DC1_EXIT_TIMEOUT;
		ts.tv_sec = (time_t)(remain / 1000);
		ts.tv_nsec = (remain % 1000) * 1000000L;
		if (nanosleep(&ts, NULL) != 0 && errno != EINTR) {
			perror("dc1-pwrkey: nanosleep");
			return DC1_EXIT_FATAL;
		}
	}
}

int main(int argc, char **argv)
{
	const char *input_dir;
	struct dirent *de;
	DIR *dir;
	int fds[DC1_MAX_DEVS];
	int nfds = 0;
	int i;
	long long timeout_secs = 0;
	long long deadline_ms = -1; /* -1 = forever */
	unsigned char buf[64 * sizeof(struct input_event)];
	size_t have = 0;

	if (argc > 2) {
		fprintf(stderr, "usage: %s [SECONDS]\n", argv[0]);
		return DC1_EXIT_USAGE;
	}
	if (argc == 2 && parse_timeout(argv[1], &timeout_secs) != 0) {
		fprintf(stderr, "%s: bad timeout \"%s\"\n", argv[0], argv[1]);
		return DC1_EXIT_USAGE;
	}

	input_dir = getenv("DC1_INPUT_DIR");
	if (input_dir == NULL || *input_dir == '\0')
		input_dir = "/dev/input";

	dir = opendir(input_dir);
	if (dir == NULL) {
		fprintf(stderr, "dc1-pwrkey: %s: %s\n", input_dir,
			strerror(errno));
		/* Degraded, not fatal: see the header comment. Fall through
		 * with zero watchers and let the clock run out. */
	} else {
		while ((de = readdir(dir)) != NULL) {
			char path[PATH_MAX];
			int fd;

			if (strncmp(de->d_name, "event", 5) != 0)
				continue;
			if (nfds >= DC1_MAX_DEVS)
				break;
			if ((size_t)snprintf(path, sizeof(path), "%s/%s",
					     input_dir, de->d_name) >=
			    sizeof(path))
				continue;
			fd = open(path, O_RDONLY);
			if (fd < 0)
				continue; /* e.g. EACCES or grabbed: skip */
			fds[nfds++] = fd;
		}
		closedir(dir);
	}

	if (timeout_secs > 0) {
		long long now;

		if (now_ms(&now) != 0) {
			perror("dc1-pwrkey: clock_gettime");
			return DC1_EXIT_FATAL;
		}
		deadline_ms = now + timeout_secs * 1000;
	}

	if (nfds == 0) {
		fprintf(stderr,
			"dc1-pwrkey: no usable event devices under %s\n",
			input_dir);
		if (deadline_ms >= 0)
			return wait_out_deadline(deadline_ms);
		return DC1_EXIT_FATAL;
	}

	for (;;) {
		fd_set rfds;
		struct timeval tv, *tvp = NULL;
		int ready;
		int maxfd = -1;
		int active = 0;

		if (deadline_ms >= 0) {
			long long now, remain;

			if (now_ms(&now) != 0) {
				perror("dc1-pwrkey: clock_gettime");
				return DC1_EXIT_FATAL;
			}
			remain = deadline_ms - now;
			if (remain <= 0)
				return DC1_EXIT_TIMEOUT;
			tv.tv_sec = (time_t)(remain / 1000);
			tv.tv_usec = (remain % 1000) * 1000;
			tvp = &tv;
		}

		FD_ZERO(&rfds);
		for (i = 0; i < nfds; i++) {
			if (fds[i] < 0)
				continue;
			active++;
			FD_SET(fds[i], &rfds);
			if (fds[i] > maxfd)
				maxfd = fds[i];
		}
		if (active == 0) {
			fprintf(stderr,
				"dc1-pwrkey: all input devices disappeared\n");
			return DC1_EXIT_FATAL;
		}

		ready = select(maxfd + 1, &rfds, NULL, NULL, tvp);
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			perror("dc1-pwrkey: select");
			return DC1_EXIT_FATAL;
		}
		if (ready == 0)
			return DC1_EXIT_TIMEOUT;

		for (i = 0; i < nfds; i++) {
			ssize_t n;

			if (fds[i] < 0 || !FD_ISSET(fds[i], &rfds))
				continue;
			n = read(fds[i], buf + have, sizeof(buf) - have);
			if (n <= 0) {
				if (n < 0 && (errno == EINTR ||
					      errno == EAGAIN))
					continue;
				/* Device went away (or hit EOF): stop
				 * watching it; the active check above
				 * catches total loss. */
				close(fds[i]);
				fds[i] = -1;
				continue;
			}
			have += (size_t)n;
			consume_events(buf, &have);
		}
	}
}
