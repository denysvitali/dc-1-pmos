// SPDX-License-Identifier: GPL-2.0-only
/*
 * rebootbl - reboot the DC-1 straight into LK's fastboot.
 *
 * Two mechanisms, tried in order.
 *
 * 1. The BCB in the "misc" partition. This is what LK actually honours and what
 *    Android's `adb reboot bootloader` uses: write "bootonce-bootloader" into
 *    bootloader_message.command, and LK enters fastboot once, then clears it.
 *    misc is /dev/block/by-name/misc == sdc1 on this device (UFS), which is why
 *    this only became possible once UFS probed.
 *
 * 2. LINUX_REBOOT_CMD_RESTART2 with a mode string, for the syscon-reboot-mode
 *    path the stock DT advertises (watchdog@10007000, offset 0x24,
 *    mode-bootloader = 0x03). Kept as a fallback, but it is known NOT to work
 *    here: the register is cleared before LK reads it -- verified by poking it
 *    with wdtreg and watching the value not survive a reset.
 *
 * Why this matters: LK only decrements the A/B retry counter on an *unexpected*
 * reset, so an ordinary reboot re-selects slot B forever. Without the BCB the
 * only route back to fastboot was letting the watchdog fire repeatedly until
 * the retries ran out -- minutes per flash.
 *
 *   usage: rebootbl [mode]        (default "bootloader"; also "recovery")
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/fs.h>
#include <linux/reboot.h>

/* Refuse to write anything that is not plausibly `misc`. Real misc is well
 * under a megabyte; a big device here means the name mapping moved and we are
 * about to corrupt something important. */
#define MISC_MAX_BYTES	(16UL * 1024 * 1024)

static int write_bcb(const char *dev, const char *cmd)
{
	unsigned char msg[64];
	unsigned long long sz = 0;
	int fd, ok = 0;

	fd = open(dev, O_RDWR | O_SYNC);
	if (fd < 0)
		return 0;

	if (ioctl(fd, BLKGETSIZE64, &sz) == 0 && sz > MISC_MAX_BYTES) {
		fprintf(stderr, "rebootbl: %s is %llu bytes, refusing (not misc?)\n",
			dev, sz);
		close(fd);
		return 0;
	}

	/* bootloader_message: char command[32]; char status[32]; ... */
	memset(msg, 0, sizeof(msg));
	strncpy((char *)msg, cmd, 31);

	if (lseek(fd, 0, SEEK_SET) == 0 &&
	    write(fd, msg, sizeof(msg)) == (ssize_t)sizeof(msg)) {
		ok = 1;
		printf("rebootbl: wrote BCB command \"%s\" to %s (%llu bytes)\n",
		       cmd, dev, sz);
	}
	fsync(fd);
	close(fd);
	return ok;
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "bootloader";
	/* LK's [recovery_check] compares misc_msg.command against these exact
	 * strings (seen in the LK image); AOSP's "bootonce-bootloader" is NOT
	 * one of them and is silently ignored. */
	const char *bcb  = !strcmp(mode, "recovery") ? "boot-recovery"
						     : "boot-fastboot";
	static const char *cands[] = {
		"/dev/block/by-name/misc", "/dev/sdc1", "/dev/block/sdc1", NULL
	};
	int i, wrote = 0;

	for (i = 0; cands[i] && !wrote; i++)
		wrote = write_bcb(cands[i], bcb);

	if (!wrote)
		fprintf(stderr, "rebootbl: could not write BCB; "
				"falling back to RESTART2 (known not to work here)\n");

	sync();
	printf("rebootbl: rebooting (%s)\n", mode);
	fflush(stdout);
	sleep(1);

	syscall(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, mode);

	perror("rebootbl: RESTART2 failed");
	return 1;
}
