// SPDX-License-Identifier: GPL-2.0-only
/*
 * bootctl - read the A/B bootloader_control block.
 *
 * Why this exists: a kernel that dies AFTER LK hands off is, from LK's point of
 * view, a successful boot -- LK loaded the image fine. So LK never decrements
 * the retry counter and never falls back to the other slot. On 2026-08-03 that
 * left the device cycling on a bad slot A for 8+ minutes with a known-good slot
 * B sitting right there, because slot B was ALSO still flagged unbootable from
 * an earlier incident and nothing had re-armed it.
 *
 * The fix is the same one Android uses: userspace marks the running slot
 * "successful" only once it has actually proved itself (here: network up). A
 * kernel that never gets that far never marks itself, so its retry count winds
 * down and LK falls back to the other slot on its own -- no button presses.
 *
 * DELIBERATELY READ-ONLY BY DEFAULT. The struct layout below is from AOSP, but
 * this device's LK is the authority, so `dump` must be cross-checked against
 * `fastboot getvar slot-successful:a / slot-retry-count:a / slot-unbootable:a`
 * BEFORE trusting any write. Writing a wrong CRC or wrong offsets here would
 * make BOTH slots unbootable, which is exactly the failure this is meant to
 * prevent.
 *
 *   bootctl dump              decode and print (safe, read-only)
 *
 * Mutation commands were retired in 2026-08-11. A caller-provided slot letter
 * is not running-image proof, and this initramfs binary cannot bind that claim
 * to exact deployed A/B images. Use the host-side slot-guard.py, which derives
 * the running slot from live GNU notes and exact partition hashes.
 *
 * misc is /dev/block/by-name/misc == /dev/sdc1 on this device; the control
 * block lives at offset 2048.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define MISC_DEV      "/dev/sdc1"
#define BC_OFFSET     2048
#define BC_MAGIC      0x42414342u   /* "BACB" */

struct slot_metadata {
	uint8_t priority_tries;   /* priority:4, tries_remaining:3, successful:1 */
	uint8_t flags;            /* verity_corrupted:1, reserved:7 */
} __attribute__((packed));

struct bootloader_control {
	char     slot_suffix[4];
	uint32_t magic;
	uint8_t  version;
	uint8_t  flags;           /* nb_slot:3, recovery_tries:3, merge_status:2 */
	uint8_t  reserved0[2];
	struct slot_metadata slot_info[4];
	uint8_t  reserved1[8];
	uint32_t crc32_le;
} __attribute__((packed));

/* Standard zlib/ethernet CRC-32, computed without a table to keep this tiny. */
static uint32_t crc32_le_calc(const uint8_t *p, size_t n)
{
	uint32_t crc = 0xffffffffu;
	while (n--) {
		crc ^= *p++;
		for (int i = 0; i < 8; i++)
			crc = (crc >> 1) ^ (0xedb88320u & (-(int32_t)(crc & 1)));
	}
	return ~crc;
}

static int prio(const struct slot_metadata *s) { return  s->priority_tries        & 0x0f; }
static int tries(const struct slot_metadata *s){ return (s->priority_tries >> 4)  & 0x07; }
static int succ(const struct slot_metadata *s) { return (s->priority_tries >> 7)  & 0x01; }

int main(int argc, char **argv)
{
	struct bootloader_control bc;
	const char *cmd = argc > 1 ? argv[1] : "dump";
	int fd, i;

	fd = open(MISC_DEV, O_RDONLY);
	if (fd < 0) { perror("bootctl: open " MISC_DEV); return 1; }
	if (pread(fd, &bc, sizeof(bc), BC_OFFSET) != (ssize_t)sizeof(bc)) {
		perror("bootctl: pread"); close(fd); return 1;
	}

	uint32_t want = crc32_le_calc((const uint8_t *)&bc,
				      sizeof(bc) - sizeof(bc.crc32_le));

	printf("magic=0x%08x %s  version=%u  suffix=%.4s\n", bc.magic,
	       bc.magic == BC_MAGIC ? "(BACB ok)" : "(BAD MAGIC)",
	       bc.version, bc.slot_suffix);
	printf("crc stored=0x%08x computed=0x%08x %s\n", bc.crc32_le, want,
	       bc.crc32_le == want ? "(match)" : "(MISMATCH -- layout is wrong,"
					         " do NOT write)");
	for (i = 0; i < 2; i++)
		printf("  slot %c: priority=%d tries_remaining=%d successful=%d\n",
		       'a' + i, prio(&bc.slot_info[i]), tries(&bc.slot_info[i]),
		       succ(&bc.slot_info[i]));

	if (!strcmp(cmd, "dump")) { close(fd); return 0; }

	fprintf(stderr,
		"bootctl: REFUSING: mutation command '%s' is retired; "
		"use host-side slot-guard.py with exact A/B image evidence\n",
		cmd);
	close(fd);
	return 2;
}
