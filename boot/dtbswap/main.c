// SPDX-License-Identifier: GPL-2.0-only
/*
 * dtbswap -- swap LK's device tree for ours, then boot the real kernel.
 *
 * Runs with MMU and caches off, so everything here is plain loads and stores
 * on physical addresses. No libc, no libfdt: the only device-tree work needed
 * is "find a property and overwrite its bytes", which is a short walk of the
 * flattened structure block. Vendoring libfdt for that would be more code
 * than the job.
 *
 * FAIL SAFE. Every failure path returns LK's original fdt, so a bad build
 * boots exactly like a stock one instead of killing an A/B slot. On this
 * device a dead slot costs a boot cycle with no log, so the stub must never
 * be the reason a slot dies.
 *
 * What we copy from LK's tree into ours, because LK fills these in at run
 * time and a statically built dtb cannot know them:
 *
 *   /chosen bootargs             - LK builds the whole command line itself
 *   /chosen linux,initrd-start   - ramdisk LK already placed in DRAM
 *   /chosen linux,initrd-end
 *   /memory  reg                 - LK patches the real DRAM size
 *
 * Each target property must already exist in our dtb, big enough to hold
 * LK's value; pack.sh checks that at build time so it cannot fail here.
 */

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;

#define FDT_MAGIC	0xd00dfeed
#define FDT_BEGIN_NODE	0x1
#define FDT_END_NODE	0x2
#define FDT_PROP	0x3
#define FDT_NOP		0x4
#define FDT_END		0x9

struct fdt_header {
	u32 magic, totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap;
	u32 version, last_comp_version, boot_cpuid_phys;
	u32 size_dt_strings, size_dt_struct;
};

struct payload_tab { u32 dtb_off, dtb_len, kern_off, kern_len; };
extern struct payload_tab payload;
extern unsigned long jump_target;

/* Where the real kernel is relocated to. DRAM starts at 0x40000000 and the
 * first reserved carve-out is aee_debug_kinfo at 0x48080000, so this window
 * is free, and it is 2 MiB aligned as the arm64 boot protocol wants. */
#define KERNEL_RELOC_PA	0x44000000UL

static u32 be32(const void *p)
{
	const u8 *b = p;
	return ((u32)b[0] << 24) | ((u32)b[1] << 16) | ((u32)b[2] << 8) | b[3];
}

static void memcpy_(void *d, const void *s, unsigned long n)
{
	u8 *dst = d; const u8 *src = s;
	while (n--) *dst++ = *src++;
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return *a == *b;
}

/*
 * Walk the structure block for /<node>/<prop>. Depth tracking keeps us to
 * top-level nodes, which is all we need (/chosen and /memory*). Returns a
 * pointer to the property data and stores its length, or 0.
 */
static void *fdt_find(void *fdt, const char *node, const char *prop, u32 *len)
{
	struct fdt_header *h = fdt;
	u8 *base = fdt;
	u8 *p = base + be32(&h->off_dt_struct);
	u8 *end = p + be32(&h->size_dt_struct);
	const char *strs = (const char *)(base + be32(&h->off_dt_strings));
	int depth = 0, in = 0;

	while (p < end) {
		u32 tag = be32(p); p += 4;

		if (tag == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			unsigned long l = 0;
			while (p[l]) l++;
			p += (l + 4) & ~3UL;
			depth++;
			/* Match "memory" against "memory@40000000" too. */
			if (depth == 1) {
				const char *a = name, *b = node;
				while (*b && *a == *b) { a++; b++; }
				in = (!*b && (!*a || *a == '@'));
			}
		} else if (tag == FDT_END_NODE) {
			if (depth == 1) in = 0;
			depth--;
		} else if (tag == FDT_PROP) {
			u32 plen = be32(p), noff = be32(p + 4);
			u8 *data = p + 8;
			p = data + ((plen + 3) & ~3U);
			if (in && depth == 1 && streq(strs + noff, prop)) {
				*len = plen;
				return data;
			}
		} else if (tag == FDT_NOP) {
			continue;
		} else {
			break;	/* FDT_END or garbage */
		}
	}
	return 0;
}

/* Copy one property across. Ours must be at least as large as LK's. */
static int copy_prop(void *dst, void *src, const char *node, const char *prop)
{
	u32 slen = 0, dlen = 0;
	void *s = fdt_find(src, node, prop, &slen);
	void *d = fdt_find(dst, node, prop, &dlen);

	if (!s || !d || slen > dlen)
		return -1;
	memcpy_(d, s, slen);
	/* Pad the remainder so a shorter string stays NUL-terminated. */
	for (u32 i = slen; i < dlen; i++)
		((u8 *)d)[i] = 0;
	return 0;
}

unsigned long dtbswap_main(unsigned long lk_fdt, unsigned long base)
{
	void *lk = (void *)lk_fdt;
	void *our = (void *)(base + payload.dtb_off);
	void *kern_src = (void *)(base + payload.kern_off);
	void *kern_dst = (void *)KERNEL_RELOC_PA;

	/* The kernel moves either way; only the fdt choice is conditional. */
	memcpy_(kern_dst, kern_src, payload.kern_len);
	jump_target = KERNEL_RELOC_PA;

	if (!lk || be32(lk) != FDT_MAGIC)
		return lk_fdt;			/* nothing sane to copy from */
	if (be32(our) != FDT_MAGIC)
		return lk_fdt;			/* our payload is broken */

	if (copy_prop(our, lk, "chosen", "bootargs") ||
	    copy_prop(our, lk, "chosen", "linux,initrd-start") ||
	    copy_prop(our, lk, "chosen", "linux,initrd-end") ||
	    copy_prop(our, lk, "memory", "reg"))
		return lk_fdt;			/* boot stock rather than guess */

	return (unsigned long)our;
}
