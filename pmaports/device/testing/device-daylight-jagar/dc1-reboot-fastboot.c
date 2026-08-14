// SPDX-License-Identifier: GPL-2.0-only
/*
 * dc1-reboot-fastboot -- reboot the DC-1 into LK's fastboot, from Linux.
 *
 * MECHANISM
 *
 * There is no jump from a running kernel into fastboot. The kernel leaves a
 * note in a register that survives a warm reset, resets the SoC, and LK reads
 * the note on the way up. On this SoC the note is the low nibble of
 * WDT_NONRST_REG2 == 0x10007000 + 0x24, and the value that means fastboot is 3.
 *
 * LK's boot_mode_select (file offset 0xa1e8 of lk_a.img minus its 0x200 MTK
 * header) decides in this order, and every test RETURNS:
 *
 *   1. preloader boot mode in {1,4,7}                -> that mode
 *   2. latch + clear low nibble of 0x10007024, == 2  -> RECOVERY
 *   3. misc BCB command == "boot-recovery"           -> RECOVERY
 *   4. misc BCB command == "boot-fastboot"           -> RECOVERY
 *   5. latched nibble == 3                           -> 0x63, FASTBOOT
 *   6. key id 1 held -> FACTORY;  7. key id 6 held   -> LK boot menu
 *
 * and its caller at 0xcf60 does `if (boot_mode_select() == 0x63) fastboot()`.
 * LK's own `fastboot reboot-bootloader` command is the positive control: the
 * handler at 0x6258 logs "rebooting the device to bootloader", calls the nibble
 * setter at 0x347b8 with 3, and resets. This tool does the same two steps.
 * [verified by disassembly of the shipped lk_a.img; re-check with:
 *  dd if=lk_a.img bs=512 skip=1 of=lk.bin
 *  r2 -q -n -a arm -b 64 -e scr.color=0 -c 'pd 24 @ 0x347b8' lk.bin]
 *
 * WHY NOT THE BCB
 *
 * The bootloader control block in `misc` is what Android's `adb reboot
 * bootloader` leans on, and it is a trap here. This LK knows no
 * "bootonce-bootloader"; the only two commands it compares against are
 * "boot-recovery" and "boot-fastboot", BOTH resolve to RECOVERY (steps 3 and
 * 4 above), this device has no recovery partition, and a match returns before
 * the nibble test and before the boot menu. Arming the BCB does not reach
 * fastboot and removes the two remaining ways back. So this tool clears a
 * stale BCB rather than writing one -- otherwise step 3/4 would fire and the
 * nibble we just wrote would never be looked at.
 *
 * The nibble does not have that failure mode: LK latches and zeroes it at step
 * 2, so an armed device that never gets to reboot is not armed forever.
 *
 * WHY NOT `reboot bootloader`
 *
 * mt6789.dtsi describes this exact register as syscon-reboot-mode (offset
 * 0x24, mask 0xf, mode-bootloader = 3) and CONFIG_SYSCON_REBOOT_MODE=y, but
 * the toprgu node is not "syscon"/"simple-mfd" and mtk_wdt does not populate
 * its children, so no platform device is ever created for the reboot-mode node
 * and LINUX_REBOOT_CMD_RESTART2 has nothing registered to honour it. [inferred
 * from the DT and driver sources; not observed on device.] Fixing that in the
 * kernel is the tidier end state -- this tool is what works today, and it also
 * works from a rescue initramfs with no init system at all.
 *
 *   usage: dc1-reboot-fastboot [-n] [--no-reboot] [-f] [--misc DEV]
 *
 *     -n, --dry-run   report the BCB and the nibble, change nothing
 *         --no-reboot arm, but leave rebooting to the caller
 *     -f, --force     reboot(2) directly instead of exec'ing /sbin/reboot;
 *                     for initramfs callers, where there is no init to ask
 *         --misc DEV  use DEV as the misc partition instead of resolving it
 *
 * Test hooks, same spirit as installer/src/partlib.sh: DC1_SYSBLOCK overrides
 * /sys/class/block, DC1_DEVDIR overrides /dev, DC1_MEMDEV overrides /dev/mem
 * and DC1_MEMBASE overrides the mapped physical base.
 */

#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/stat.h>

#define WDT_BASE		0x10007000UL
#define WDT_MAP_LEN		0x1000UL
#define WDT_NONRST2		0x24		/* survives a warm reset */
#define BOOT_MODE_MASK		0x0fU
#define BOOT_MODE_FASTBOOT	0x03U

/* Real misc is well under a megabyte. A big device under PARTNAME=misc means
 * the mapping is not what we think it is, and the next write would land in
 * something that matters. 16 MiB in 512-byte sectors. */
#define MISC_MAX_SECTORS	32768UL

/* bootloader_message: char command[32]; char status[32]; ... The A/B
 * bootloader_control lives at offset 2048 and is deliberately left alone. */
#define BCB_CLEAR_BYTES		64

static const char *env_or(const char *name, const char *fallback)
{
	const char *v = getenv(name);

	return (v && *v) ? v : fallback;
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
static int resolve_misc(char *out, size_t n)
{
	const char *sysblock = env_or("DC1_SYSBLOCK", "/sys/class/block");
	const char *devdir = env_or("DC1_DEVDIR", "/dev");
	char found[64] = "", path[512], buf[4096];
	struct dirent *de;
	int count = 0;
	DIR *d;

	d = opendir(sysblock);
	if (!d) {
		fprintf(stderr, "dc1-reboot-fastboot: opendir %s failed\n", sysblock);
		return -1;
	}
	while ((de = readdir(d))) {
		if (de->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "%s/%s/uevent", sysblock, de->d_name);
		if (read_file(path, buf, sizeof(buf)) < 0)
			continue;
		if (!strstr(buf, "PARTNAME=misc\n"))
			continue;
		count++;
		snprintf(found, sizeof(found), "%s", de->d_name);
	}
	closedir(d);

	if (count != 1) {
		fprintf(stderr, "dc1-reboot-fastboot: expected exactly 1 "
				"PARTNAME=misc, found %d\n", count);
		return -1;
	}

	snprintf(path, sizeof(path), "%s/%s/size", sysblock, found);
	if (read_file(path, buf, sizeof(buf)) < 0) {
		fprintf(stderr, "dc1-reboot-fastboot: cannot read %s\n", path);
		return -1;
	}
	if (strtoul(buf, NULL, 10) > MISC_MAX_SECTORS) {
		fprintf(stderr, "dc1-reboot-fastboot: misc (%s) is %lu sectors, "
				"refusing (mapping moved?)\n",
			found, strtoul(buf, NULL, 10));
		return -1;
	}

	snprintf(out, n, "%s/%s", devdir, found);
	return 0;
}

static void print_command(const char *what, const char *cmd)
{
	size_t i;

	printf("dc1-reboot-fastboot: %s: \"", what);
	for (i = 0; i < 32 && cmd[i]; i++)
		putchar((cmd[i] >= 0x20 && cmd[i] < 0x7f) ? cmd[i] : '.');
	printf("\"\n");
}

/* Returns 0 on success, -1 if the BCB could not be inspected. */
static int disarm_bcb(const char *dev, int dry_run)
{
	char cmd[33] = "", zero[BCB_CLEAR_BYTES];
	int fd, armed;

	fd = open(dev, dry_run ? O_RDONLY : O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "dc1-reboot-fastboot: open %s failed\n", dev);
		return -1;
	}
	if (pread(fd, cmd, 32, 0) != 32) {
		fprintf(stderr, "dc1-reboot-fastboot: short read of %s\n", dev);
		close(fd);
		return -1;
	}
	print_command("misc BCB command", cmd);

	/* The only two strings this LK matches. Anything else it ignores, so
	 * anything else is left alone. */
	armed = !strcmp(cmd, "boot-fastboot") || !strcmp(cmd, "boot-recovery");
	if (!armed) {
		close(fd);
		return 0;
	}
	if (dry_run) {
		printf("dc1-reboot-fastboot: BCB is armed and would divert LK to "
		       "recovery; would clear it\n");
		close(fd);
		return 0;
	}

	memset(zero, 0, sizeof(zero));
	if (pwrite(fd, zero, sizeof(zero), 0) != (ssize_t)sizeof(zero)) {
		fprintf(stderr, "dc1-reboot-fastboot: clearing the BCB failed\n");
		close(fd);
		return -1;
	}
	fsync(fd);
	if (pread(fd, cmd, 32, 0) != 32 || cmd[0] != '\0') {
		fprintf(stderr, "dc1-reboot-fastboot: BCB did not read back "
				"clear; refusing to continue\n");
		close(fd);
		return -1;
	}
	printf("dc1-reboot-fastboot: cleared the armed BCB (it means RECOVERY "
	       "on this LK, and hides the nibble)\n");
	close(fd);
	return 0;
}

static int arm_nibble(int dry_run)
{
	const char *memdev = env_or("DC1_MEMDEV", "/dev/mem");
	unsigned long base = strtoul(env_or("DC1_MEMBASE", "0x10007000"), NULL, 16);
	volatile uint32_t *regs;
	uint32_t old, want, got;
	int fd;

	fd = open(memdev, dry_run ? O_RDONLY : O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "dc1-reboot-fastboot: open %s failed "
				"(CONFIG_DEVMEM?)\n", memdev);
		return -1;
	}
	regs = mmap(NULL, WDT_MAP_LEN, dry_run ? PROT_READ : PROT_READ | PROT_WRITE,
		    MAP_SHARED, fd, (off_t)base);
	close(fd);
	if (regs == MAP_FAILED) {
		fprintf(stderr, "dc1-reboot-fastboot: mmap %s at 0x%lx failed\n",
			memdev, base);
		return -1;
	}

	old = regs[WDT_NONRST2 / 4];
	printf("dc1-reboot-fastboot: WDT_NONRST_REG2 (0x%lx) = 0x%08x, boot mode "
	       "nibble = %u\n", base + WDT_NONRST2, old, old & BOOT_MODE_MASK);

	if (dry_run) {
		printf("dc1-reboot-fastboot: would set the nibble to %u (fastboot)\n",
		       BOOT_MODE_FASTBOOT);
		munmap((void *)regs, WDT_MAP_LEN);
		return 0;
	}

	want = (old & ~BOOT_MODE_MASK) | BOOT_MODE_FASTBOOT;
	regs[WDT_NONRST2 / 4] = want;
	__sync_synchronize();
	got = regs[WDT_NONRST2 / 4];
	munmap((void *)regs, WDT_MAP_LEN);

	if ((got & BOOT_MODE_MASK) != BOOT_MODE_FASTBOOT) {
		fprintf(stderr, "dc1-reboot-fastboot: wrote 0x%08x, read back "
				"0x%08x -- register did not take, NOT rebooting\n",
			want, got);
		return -1;
	}
	printf("dc1-reboot-fastboot: armed: 0x%08x -> 0x%08x (nibble %u = fastboot)\n",
	       old, got, BOOT_MODE_FASTBOOT);
	return 0;
}

static void usage(FILE *f)
{
	fprintf(f, "usage: dc1-reboot-fastboot [-n|--dry-run] [--no-reboot] "
		   "[-f|--force] [--misc DEV]\n");
}

int main(int argc, char **argv)
{
	const char *misc_arg = NULL;
	int dry_run = 0, no_reboot = 0, force = 0, i;
	char misc[256];

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-n") || !strcmp(argv[i], "--dry-run"))
			dry_run = 1;
		else if (!strcmp(argv[i], "--no-reboot"))
			no_reboot = 1;
		else if (!strcmp(argv[i], "-f") || !strcmp(argv[i], "--force"))
			force = 1;
		else if (!strcmp(argv[i], "--misc") && i + 1 < argc)
			misc_arg = argv[++i];
		else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage(stdout);
			return 0;
		} else {
			usage(stderr);
			return 2;
		}
	}

	if (!dry_run && geteuid() != 0) {
		fprintf(stderr, "dc1-reboot-fastboot: must be root\n");
		return 1;
	}

	/* Step 1: make sure LK will get as far as the nibble. A BCB we cannot
	 * inspect is not fatal -- it is normally clear, and the nibble write is
	 * worth doing either way -- but it is the first thing to suspect if the
	 * device comes back to Linux instead of fastboot. */
	if (misc_arg)
		snprintf(misc, sizeof(misc), "%s", misc_arg);
	else if (resolve_misc(misc, sizeof(misc)) < 0)
		misc[0] = '\0';

	if (misc[0]) {
		printf("dc1-reboot-fastboot: misc = %s\n", misc);
		if (disarm_bcb(misc, dry_run) < 0)
			return 1;
	} else {
		fprintf(stderr, "dc1-reboot-fastboot: WARNING: could not check the "
				"BCB; if this boots back into Linux, a stale "
				"\"boot-fastboot\"/\"boot-recovery\" there is why\n");
	}

	/* Step 2: leave the note LK reads on the way up. */
	if (arm_nibble(dry_run) < 0)
		return 1;

	if (dry_run || no_reboot)
		return 0;

	sync();
	printf("dc1-reboot-fastboot: rebooting into fastboot\n");
	fflush(stdout);

	/* Ask the init system first so filesystems come down cleanly; -f is for
	 * callers that are the init system, or have none. */
	if (!force) {
		char *args[] = { (char *)"reboot", NULL };

		execv("/sbin/reboot", args);
	}
	reboot(RB_AUTOBOOT);
	perror("dc1-reboot-fastboot: reboot");
	return 1;
}
