// SPDX-License-Identifier: MIT
/*
 * Mirror DRM DPMS onto the two independent RT4539 frontlights. The panel has
 * no ordinary backlight phandle, so DRM blanking alone leaves them burning.
 * Write bl_power (0 = on, 4 = off), never brightness: the user's brightness
 * survives blanking. Both systemd and OpenRC run this helper and call
 * --restore after stopping it, including abnormal termination.
 *
 * Polling stays at 500 ms: DRM supplies no DPMS uevent, and GNOME-only D-Bus
 * notifications would lose sway support. This replaces the shell loop's
 * twice-per-second sleep child with an interruptible monotonic wait. It
 * removes recurring process creation, not the polling wakeups; no measured
 * battery or compositor speedup is claimed.
 *
 * Preserve the shell's state rules: any successfully read On wins; any other
 * complete line votes off. Missing/unreadable/incomplete lines do not vote.
 * With no votes leave lights untouched. Apply only on observed state changes,
 * best-effort per light (no retry until another state change, as before).
 *
 * Test hook: DC1_BACKLIGHT_SYSFS replaces /sys, with class/drm and
 * class/backlight beneath it. No child processes or runtime dependencies
 * beyond libc. SIGTERM/SIGINT retain their default, immediate stop behavior;
 * restoration belongs to the service managers' existing stop-post hooks.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <glob.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum state { UNKNOWN = -1, ON = 0, OFF = 4 };

static int paths(const char *root, const char *suffix, glob_t *matches)
{
	char pattern[PATH_MAX];
	int n = snprintf(pattern, sizeof(pattern), "%s/class/%s", root, suffix);

	memset(matches, 0, sizeof(*matches));
	if (n < 0 || (size_t)n >= sizeof(pattern))
		return -1;
	return glob(pattern, 0, NULL, matches);
}

static enum state screen_state(const char *root)
{
	glob_t matches;
	enum state state = UNKNOWN;
	char *line = NULL;
	size_t capacity = 0;

	if (paths(root, "drm/*/dpms", &matches) == 0) {
		for (size_t i = 0; i < matches.gl_pathc; i++) {
			FILE *file = fopen(matches.gl_pathv[i], "r");
			ssize_t length;
			char *value;

			if (file == NULL)
				continue;
			length = getline(&line, &capacity, file);
			fclose(file);
			/* shell read returns failure on EOF without a newline. */
			if (length <= 0 || line[length - 1] != '\n')
				continue;
			line[--length] = '\0';
			/* Match read -r's default IFS trimming, not token parsing. */
			while (length > 0 && (line[length - 1] == ' ' ||
					     line[length - 1] == '\t'))
				line[--length] = '\0';
			value = line;
			while (*value == ' ' || *value == '\t')
				value++;
			state = strcmp(value, "On") == 0 ? ON : OFF;
			if (state == ON)
				break;
		}
	}
	free(line);
	globfree(&matches);
	return state;
}

static void lights_set(const char *root, enum state state)
{
	glob_t matches;

	if (paths(root, "backlight/*/bl_power", &matches) == 0) {
		for (size_t i = 0; i < matches.gl_pathc; i++) {
			FILE *file;

			/* Keep the shell's writable-file guard and best effort. */
			if (access(matches.gl_pathv[i], W_OK) != 0)
				continue;
			file = fopen(matches.gl_pathv[i], "w");
			if (file == NULL)
				continue;
			fprintf(file, "%d\n", state);
			fclose(file);
		}
	}
	globfree(&matches);
}

static int wait_interval(void)
{
	struct timespec until;
	int error;

	if (clock_gettime(CLOCK_MONOTONIC, &until) != 0)
		return -1;
	until.tv_nsec += 500000000L;
	if (until.tv_nsec >= 1000000000L) {
		until.tv_sec++;
		until.tv_nsec -= 1000000000L;
	}
	do {
		error = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, NULL);
	} while (error == EINTR);
	if (error != 0) {
		errno = error;
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *root = getenv("DC1_BACKLIGHT_SYSFS");
	enum state applied = UNKNOWN;

	if (root == NULL || *root == '\0')
		root = "/sys";
	if (argc == 2 && strcmp(argv[1], "--restore") == 0) {
		lights_set(root, ON);
		return 0;
	}
	if (argc != 1) {
		fprintf(stderr, "usage: %s [--restore]\n", argv[0]);
		return 2;
	}
	for (;;) {
		enum state state = screen_state(root);

		if (state != UNKNOWN && state != applied) {
			lights_set(root, state);
			applied = state;
		}
		if (wait_interval() != 0) {
			perror("dc1-screen-backlight: monotonic wait");
			return 1;
		}
	}
}
