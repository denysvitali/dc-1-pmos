/* dc1-misc.c -- the shared PARTNAME=misc resolver and string helpers.
 * See dc1-misc.h. */

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "dc1-misc.h"

const char *dc1_env_or(const char *name, const char *fallback)
{
	const char *v = getenv(name);

	return (v && *v) ? v : fallback;
}

int dc1_fmt(char *dst, size_t n, const char *f, const char *a, const char *b)
{
	int r = snprintf(dst, n, f, a, b);

	return (r < 0 || (size_t)r >= n) ? -1 : 0;
}

static int read_file(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY);
	ssize_t got;

	if (fd < 0)
		return -1;
	got = read(fd, buf, n - 1);
	close(fd);
	if (got < 0)
		return -1;
	buf[got] = '\0';
	return 0;
}

/* Resolve PARTNAME=misc out of sysfs: required unique, required small. No
 * hardcoded /dev/sdc1 -- a fixed node is exactly the mapping-moved hazard the
 * size check is here to catch. */
int dc1_resolve_misc(char *out, size_t n)
{
	const char *sysblock = dc1_env_or("DC1_SYSBLOCK", "/sys/class/block");
	const char *devdir = dc1_env_or("DC1_DEVDIR", "/dev");
	char found[NAME_MAX + 1] = "", path[PATH_MAX], buf[4096];
	struct dirent *de;
	int count = 0;
	DIR *d;

	d = opendir(sysblock);
	if (!d) {
		fprintf(stderr, "dc1: opendir %s failed\n", sysblock);
		return -1;
	}
	while ((de = readdir(d))) {
		if (de->d_name[0] == '.')
			continue;
		if (dc1_fmt(path, sizeof(path), "%s/%s/uevent", sysblock, de->d_name) < 0)
			continue;
		if (read_file(path, buf, sizeof(buf)) < 0)
			continue;
		if (!strstr(buf, "PARTNAME=misc\n"))
			continue;
		count++;
		/* A name we cannot hold is a name we must not act on: bump the
		 * count again so the "exactly 1" check below refuses. */
		if (dc1_fmt(found, sizeof(found), "%s%s", de->d_name, "") < 0)
			count++;
	}
	closedir(d);

	if (count != 1) {
		fprintf(stderr, "dc1: expected exactly 1 PARTNAME=misc, found %d\n",
			count);
		return -1;
	}

	if (dc1_fmt(path, sizeof(path), "%s/%s/size", sysblock, found) < 0 ||
	    read_file(path, buf, sizeof(buf)) < 0) {
		fprintf(stderr, "dc1: cannot read %s\n", path);
		return -1;
	}
	if (strtoul(buf, NULL, 10) > DC1_MISC_MAX_SECTORS) {
		fprintf(stderr, "dc1: misc (%s) is %lu sectors, refusing "
			"(mapping moved?)\n",
			found, strtoul(buf, NULL, 10));
		return -1;
	}

	return dc1_fmt(out, n, "%s/%s", devdir, found);
}
