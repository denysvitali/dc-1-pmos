// SPDX-License-Identifier: GPL-2.0-only
/*
 * dc1-slotctl -- guarded A/B slot metadata operations for the Daylight DC-1.
 *
 * The DC-1's bootloader (LK + the preloader) picks the A/B slot from a 32-byte
 * bootloader_control block at byte 2048 of the `misc` partition. This tool
 * decodes, validates, and -- with the same invariant every writer must honour
 * -- mutates that block. It is the ON-DEVICE counterpart of the host-side
 * slot-guard.py (private repo), and the write path is a deliberate re-entry of
 * the mutation that bootctl (the initramfs dump tool) retired, now that the
 * layout is pinned against real blocks from this device rather than assumed.
 *
 * BLOCK LAYOUT (verified against real blocks, matching boot_control.py and
 * internal/bootctl):
 *
 *   +0x00  slot_suffix[4]    "_a\0\0" or "_b\0\0" (LK's INTENT, not what booted)
 *   +0x04  magic             bytes 42 43 41 42 (u32 0x42414342 little-endian)
 *   +0x08  version           1
 *   +0x09  nb_slot:3         == 2
 *   +0x0c  slot A metadata   priority:b0-3, tries:b4-6, successful:b7
 *   +0x0e  slot B metadata   (same packing)
 *   +0x1c  crc32_le          over the first 28 bytes (zlib/IEEE, same as
 *                            binascii.crc32 and Go's crc32.ChecksumIEEE)
 *
 * `get_suffix` in both bootloaders picks "_b" whenever priority_a < priority_b
 * (see BOOT-CHAIN-RE.md), so reordering priority is the switch.
 *
 * SAFETY INVARIANT, enforced on the computed block before writing and again on
 * the read-back after: at least one slot must remain bootable, where
 *   bootable <=> priority > 0 and (successful == 1 or tries > 0).
 * A block that leaves zero bootable slots is never written.
 *
 * COMMANDS (each reads, validates, mutates, re-checks, writes, reads back):
 *
 *   status                     decode and print both slots (read-only)
 *   validate-hex HEX           validate a 32-byte hex block, print its state
 *   prefer <a|b>               boot <slot> next WITHOUT clearing successful_boot
 *   arm <a|b> [--tries N]      arm an UNPROVEN slot for N tries (clears
 *                              successful); requires the OTHER slot proven
 *   mark-successful <a|b>      mark <slot> proven (successful=1, tries=0)
 *
 * `-n`/`--dry-run` prints what would be written and changes nothing.
 * `--misc DEV` uses DEV instead of resolving PARTNAME=misc.
 *
 * WHY `arm`/`mark-successful` DO NOT prove the running slot: on-device there is
 * no GNU-notes/partition-hash channel (that is what the host-side slot-guard.py
 * does over SSH). The on-device proof lives in the CALLER: dc1-boot-update.sh
 * derives inactive from the validated slot_suffix and never arms the slot it
 * just read as active, and the mark-successful service verifies the running
 * kernel release (uname -r) matches the one it armed before it calls here.
 * This tool is the low-level primitive; the survivability invariant is the
 * hard floor that holds even if the caller is wrong.
 *
 * Test hooks: DC1_SYSBLOCK / DC1_DEVDIR (via dc1-misc.c) and --misc.
 */

#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include "dc1-misc.h"

#define BCB_OFFSET	2048
#define BCB_SIZE	32

/* "BCAB" on the wire: the little-endian u32 0x42414342 AOSP calls BOOTCTRL_MAGIC. */
static const uint8_t BCB_MAGIC[4] = { 0x42, 0x43, 0x41, 0x42 };

/* crc32 over a byte range, zlib/IEEE (poly 0xedb88320, init ~0, final ~). This
 * is exactly what binascii.crc32 and Go's crc32.ChecksumIEEE produce, and what
 * the existing Go bootctl test pins against a real block. */
static uint32_t crc32_le(const uint8_t *p, size_t n)
{
	uint32_t crc = 0xffffffffu;
	size_t i;
	int j;

	for (i = 0; i < n; i++) {
		crc ^= p[i];
		for (j = 0; j < 8; j++)
			crc = (crc >> 1) ^ (0xedb88320u &
				(uint32_t)-(int32_t)(crc & 1u));
	}
	return ~crc;
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v & 0xff);
	p[1] = (uint8_t)((v >> 8) & 0xff);
	p[2] = (uint8_t)((v >> 16) & 0xff);
	p[3] = (uint8_t)((v >> 24) & 0xff);
}

struct slot_state {
	int priority;
	int tries;
	int successful;
};

static int slot_off(char slot)
{
	if (slot == 'a')
		return 12;
	if (slot == 'b')
		return 14;
	return -1;
}

static int bootable(struct slot_state s)
{
	return s.priority > 0 && (s.successful == 1 || s.tries > 0);
}

static int proven(struct slot_state s)
{
	return s.priority > 0 && s.successful == 1;
}

/* validate returns 0 if the block is exactly what this device's bootloaders
 * read, and prints a specific reason to stderr otherwise. */
static int validate(const uint8_t *b)
{
	uint32_t stored, calc;

	if (memcmp(b + 4, BCB_MAGIC, 4) != 0) {
		fprintf(stderr, "dc1-slotctl: bad BCB magic %02x%02x%02x%02x "
			"(expected %02x%02x%02x%02x)\n",
			b[4], b[5], b[6], b[7],
			BCB_MAGIC[0], BCB_MAGIC[1], BCB_MAGIC[2], BCB_MAGIC[3]);
		return -1;
	}
	if (memcmp(b, "_a\0\0", 4) != 0 && memcmp(b, "_b\0\0", 4) != 0) {
		fprintf(stderr, "dc1-slotctl: invalid BCB intent suffix %.4s\n", b);
		return -1;
	}
	if (b[8] != 1) {
		fprintf(stderr, "dc1-slotctl: unsupported BCB version %u\n", b[8]);
		return -1;
	}
	if ((b[9] & 0x07) != 2) {
		fprintf(stderr, "dc1-slotctl: unsupported BCB slot count %u\n",
			b[9] & 0x07);
		return -1;
	}
	stored = le32(b + 28);
	calc = crc32_le(b, 28);
	if (stored != calc) {
		fprintf(stderr, "dc1-slotctl: BCB crc mismatch "
			"(stored 0x%08x, computed 0x%08x)\n", stored, calc);
		return -1;
	}
	return 0;
}

static struct slot_state decode(const uint8_t *b, char slot)
{
	uint8_t v = b[slot_off(slot)];

	return (struct slot_state){
		.priority = v & 0x0f,
		.tries = (v >> 4) & 0x07,
		.successful = (v >> 7) & 0x01,
	};
}

/* The slot LK's get_suffix selects, which is the running slot on any device
 * that booted cleanly: "_b" iff priority_a < priority_b, else "_a". The
 * slot_suffix FIELD at offset 0 is LK's INTENT (written by set_active), NOT
 * what get_suffix computes -- get_suffix compares priority -- so the running
 * slot must be derived from priority, never from the field. */
static char active_slot(const uint8_t *b)
{
	return decode(b, 'a').priority < decode(b, 'b').priority ? 'b' : 'a';
}

/* set_slot writes the packed metadata byte. Ranges are the caller's contract
 * (they are checked in the command handlers before calling here). */
static void set_slot(uint8_t *b, char slot, int priority, int tries, int successful)
{
	b[slot_off(slot)] = (uint8_t)(priority | (tries << 4) | (successful << 7));
}

static int assert_survivable(const uint8_t *b)
{
	struct slot_state a = decode(b, 'a');
	struct slot_state s = decode(b, 'b');

	if (!bootable(a) && !bootable(s)) {
		fprintf(stderr, "dc1-slotctl: this change would leave zero bootable "
			"slots (a=%d/%d/%d, b=%d/%d/%d); refusing\n",
			a.priority, a.tries, a.successful,
			s.priority, s.tries, s.successful);
		return -1;
	}
	return 0;
}

static void reseal(uint8_t *b)
{
	put_le32(b + 28, crc32_le(b, 28));
}

static void show(const uint8_t *b, const char *prefix)
{
	struct slot_state a = decode(b, 'a');
	struct slot_state s = decode(b, 'b');

	printf("%sslot a: pri=%-2d tries=%d ok=%d %s   "
	       "slot b: pri=%-2d tries=%d ok=%d %s\n",
	       prefix, a.priority, a.tries, a.successful,
	       bootable(a) ? "BOOTABLE" : "dead",
	       s.priority, s.tries, s.successful,
	       bootable(s) ? "BOOTABLE" : "dead");
}

static void describe(const uint8_t *b)
{
	printf("suffix=%c active=%c version=%u nb_slot=%u crc=0x%08x\n",
	       (b[0] == '_') ? b[1] : '?', active_slot(b), b[8], b[9] & 0x07,
	       le32(b + 28));
	show(b, "  ");
}

/* read_bcb pulls the 32 bytes at BCB_OFFSET and validates them. Returns a
 * malloc'd copy or NULL. */
static uint8_t *read_bcb(const char *dev)
{
	uint8_t *b = malloc(BCB_SIZE);
	int fd = open(dev, O_RDONLY);
	ssize_t got;

	if (!b) {
		fprintf(stderr, "dc1-slotctl: out of memory\n");
		return NULL;
	}
	if (fd < 0) {
		fprintf(stderr, "dc1-slotctl: open %s failed\n", dev);
		free(b);
		return NULL;
	}
	got = pread(fd, b, BCB_SIZE, BCB_OFFSET);
	close(fd);
	if (got != BCB_SIZE) {
		fprintf(stderr, "dc1-slotctl: short read of %s at %d (%zd bytes)\n",
			dev, BCB_OFFSET, got);
		free(b);
		return NULL;
	}
	if (validate(b) < 0) {
		fprintf(stderr, "dc1-slotctl: refusing to act on an invalid block\n");
		free(b);
		return NULL;
	}
	return b;
}

/* write_bcb writes back the block, then reads it back and requires a byte
 * match. Returns 0 on success. */
static int write_bcb(const char *dev, const uint8_t *b, int dry_run)
{
	int fd;
	uint8_t back[BCB_SIZE];

	if (dry_run) {
		printf("dc1-slotctl: would write to %s+%d:\n", dev, BCB_OFFSET);
		show(b, "  would: ");
		return 0;
	}

	fd = open(dev, O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "dc1-slotctl: open %s for write failed\n", dev);
		return -1;
	}
	if (pwrite(fd, b, BCB_SIZE, BCB_OFFSET) != BCB_SIZE) {
		fprintf(stderr, "dc1-slotctl: short write of %s\n", dev);
		close(fd);
		return -1;
	}
	fsync(fd);
	if (pread(fd, back, BCB_SIZE, BCB_OFFSET) != BCB_SIZE) {
		fprintf(stderr, "dc1-slotctl: short read-back of %s\n", dev);
		close(fd);
		return -1;
	}
	close(fd);

	if (memcmp(back, b, BCB_SIZE) != 0) {
		fprintf(stderr, "dc1-slotctl: read-back differs from what we wrote "
			"(wrote %02x..%02x, read %02x..%02x); NOT reporting success\n",
			b[0], b[31], back[0], back[31]);
		return -1;
	}
	if (assert_survivable(back) < 0) {
		fprintf(stderr, "dc1-slotctl: the written block violates the "
			"survivability invariant\n");
		return -1;
	}
	return 0;
}

/* parse_hex decodes exactly 32 bytes from a 64-char hex string, ignoring
 * surrounding whitespace. Returns 0 and fills b on success. */
static int parse_hex(const char *text, uint8_t *b)
{
	size_t i, j = 0;
	int hi = -1;

	for (i = 0; text[i]; i++) {
		int nib;
		char c = text[i];

		if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
			continue;
		if (c >= '0' && c <= '9')
			nib = c - '0';
		else if (c >= 'a' && c <= 'f')
			nib = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			nib = c - 'A' + 10;
		else {
			fprintf(stderr, "dc1-slotctl: non-hex character %c in block\n", c);
			return -1;
		}
		if (hi < 0) {
			hi = nib;
		} else {
			if (j >= BCB_SIZE) {
				fprintf(stderr, "dc1-slotctl: block longer than %d bytes\n",
					BCB_SIZE);
				return -1;
			}
			b[j++] = (uint8_t)((hi << 4) | nib);
			hi = -1;
		}
	}
	if (hi >= 0 || j != BCB_SIZE) {
		fprintf(stderr, "dc1-slotctl: block is %zu bytes, expected exactly %d\n",
			j, BCB_SIZE);
		return -1;
	}
	return 0;
}

static void usage(FILE *f)
{
	fprintf(f, "usage: dc1-slotctl <status|validate-hex HEX|prefer SLOT|"
		"arm SLOT|mark-successful SLOT> [-n] [--misc DEV] [--tries N]\n");
}

int main(int argc, char **argv)
{
	const char *cmd;
	const char *misc_arg = NULL;
	char slot = 0;
	int dry_run = 0, tries = 1, i;
	uint8_t *b = NULL;
	char misc[PATH_MAX];

	if (argc < 2) {
		usage(stderr);
		return 2;
	}
	cmd = argv[1];

	/* validate-hex is the offline test hook: a bare 64-char hex block, no
	 * device, no slot, no options. Handle it before the option loop so the
	 * hex string is never mistaken for an option or a slot. */
	if (!strcmp(cmd, "validate-hex")) {
		uint8_t blk[BCB_SIZE];

		if (argc != 3) {
			usage(stderr);
			return 2;
		}
		if (parse_hex(argv[2], blk) < 0)
			return 1;
		if (validate(blk) < 0)
			return 1;
		describe(blk);
		return 0;
	}

	/* Pull the trailing options; the leading positional arg is the slot for
	 * prefer/arm/mark-successful. */
	for (i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "-n") || !strcmp(argv[i], "--dry-run"))
			dry_run = 1;
		else if (!strcmp(argv[i], "--misc") && i + 1 < argc)
			misc_arg = argv[++i];
		else if (!strcmp(argv[i], "--tries") && i + 1 < argc) {
			char *end = NULL;
			long v = strtol(argv[++i], &end, 10);
			if (*end != '\0' || v < 1 || v > 7) {
				fprintf(stderr, "dc1-slotctl: --tries must be 1..7\n");
				return 2;
			}
			tries = (int)v;
		} else if (slot == 0 && argv[i][0] != '-' &&
			   (argv[i][0] == 'a' || argv[i][0] == 'b') &&
			   argv[i][1] == '\0') {
			slot = argv[i][0];
		} else {
			fprintf(stderr, "dc1-slotctl: unknown argument %s\n", argv[i]);
			usage(stderr);
			return 2;
		}
	}

	if (!strcmp(cmd, "status")) {
		if (misc_arg)
			dc1_fmt(misc, sizeof(misc), "%s%s", misc_arg, "");
		else if (dc1_resolve_misc(misc, sizeof(misc)) < 0) {
			fprintf(stderr, "dc1-slotctl: cannot resolve misc\n");
			return 1;
		}
		b = read_bcb(misc);
		if (!b)
			return 1;
		describe(b);
		free(b);
		return 0;
	}

	if (!strcmp(cmd, "prefer") || !strcmp(cmd, "arm") ||
	    !strcmp(cmd, "mark-successful")) {
		char other;
		struct slot_state st, ot;

		if (slot == 0) {
			usage(stderr);
			return 2;
		}
		other = (slot == 'a') ? 'b' : 'a';

		if (misc_arg)
			dc1_fmt(misc, sizeof(misc), "%s%s", misc_arg, "");
		else if (dc1_resolve_misc(misc, sizeof(misc)) < 0) {
			fprintf(stderr, "dc1-slotctl: cannot resolve misc\n");
			return 1;
		}
		b = read_bcb(misc);
		if (!b)
			return 1;

		printf("dc1-slotctl: misc = %s\n", misc);
		show(b, "before: ");

		st = decode(b, slot);
		ot = decode(b, other);

		if (!strcmp(cmd, "prefer")) {
			if (!bootable(st)) {
				fprintf(stderr, "dc1-slotctl: slot %c is not bootable "
					"(%d/%d/%d); `prefer` will not resurrect it -- "
					"flash and `arm` it instead\n",
					slot, st.priority, st.tries, st.successful);
				free(b);
				return 1;
			}
			/* Priority only: successful and tries are left exactly as they
			 * are, which is the whole point of prefer -- the fallback
			 * stays proven. */
			set_slot(b, slot, 15, st.tries, st.successful);
			set_slot(b, other, 14, ot.tries, ot.successful);
		} else if (!strcmp(cmd, "arm")) {
			/* Refuse to arm the slot LK currently selects (get_suffix, i.e.
			 * the higher-priority slot): on a device that booted cleanly
			 * that is the running slot, and arming it would clobber the
			 * kernel we are running from. The slot_suffix FIELD is NOT used
			 * for this -- get_suffix compares priority, not the field. */
			if (slot == active_slot(b)) {
				fprintf(stderr, "dc1-slotctl: slot %c is the currently "
					"selected (running) slot; refusing to arm it -- arm "
					"the OTHER slot\n", slot);
				free(b);
				return 1;
			}
			if (!proven(ot)) {
				fprintf(stderr, "dc1-slotctl: the other slot (%c) is not "
					"proven (%d/%d/%d). Arming clears successful_boot "
					"on %c, so this would leave no reliable fallback.\n",
					other, ot.priority, ot.tries, ot.successful, slot);
				free(b);
				return 1;
			}
			set_slot(b, slot, 15, tries, 0);
			set_slot(b, other, 14, ot.tries, ot.successful);
		} else { /* mark-successful */
			/* Refuse to mark a slot proven that LK is not currently
			 * selecting: the caller proves the running kernel via its
			 * release string, and on a clean boot the running slot IS the
			 * selected slot. This is the on-device proxy for slot-guard.py's
			 * independent running-slot proof, and it fails safe. */
			if (slot != active_slot(b)) {
				fprintf(stderr, "dc1-slotctl: slot %c is not the currently "
					"selected slot (%c); refusing to mark it successful\n",
					slot, active_slot(b));
				free(b);
				return 1;
			}
			set_slot(b, slot, st.priority, 0, 1);
		}

		if (assert_survivable(b) < 0) {
			free(b);
			return 1;
		}
		reseal(b);

		if (write_bcb(misc, b, dry_run) < 0) {
			free(b);
			return 1;
		}
		show(b, dry_run ? "after : " : "after : ");
		printf("dc1-slotctl: %s\n",
			dry_run ? "dry run -- nothing written"
			        : "verified: read-back matches, at least one slot bootable");
		free(b);
		return 0;
	}

	fprintf(stderr, "dc1-slotctl: unknown command %s\n", cmd);
	usage(stderr);
	return 2;
}
