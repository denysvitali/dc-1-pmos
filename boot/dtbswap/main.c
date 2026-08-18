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

/*
 * Trace word, so a failed swap can be diagnosed without a console.
 *
 * The framebuffer reservation is 0x173e000 bytes but only 1216*1600*4 is
 * scanned out, so this sits ~8 MiB in: past anything visible, inside a range
 * that is reserved (nothing else allocates it) yet not "no-map" (so Linux can
 * still read it afterwards via /dev/mem). Written as a magic plus the last
 * step reached.
 */
#define TRACE_PA	0xff0c1000UL
#define TRACE_MAGIC	0x44544253u	/* "DTBS" */

/*
 * Report the outcome as a COUNT OF BARS on LK's live scanout.
 *
 * The DC-1 panel is monochrome, so colour carries no information -- every hue
 * lands on a similar grey. Count and position do survive: this clears a strip
 * to white and draws N black bars, so the result is read by counting them.
 * Drawn within milliseconds of getting control, using only the buffer LK is
 * already scanning out. Geometry matches jagar_fbcon.
 */
#define FB_PA		0xfe8c1000UL
#define FB_STRIDE	4864U
#define FB_W		1200U
#define BAR_H		30U
#define BAR_GAP		20U
#define STRIP_H		((BAR_H + BAR_GAP) * 9U)

#define WHITE		0xffffffffu
#define BLACK		0xff000000u

static void fill_rows(u32 y0, u32 rows, u32 argb)
{
	volatile u32 *fb = (volatile u32 *)FB_PA;
	for (u32 y = y0; y < y0 + rows; y++)
		for (u32 x = 0; x < FB_W; x++)
			fb[(y * FB_STRIDE) / 4 + x] = argb;
}

/* n bars = the step reached; 8 bars means the swap succeeded. */
static void report(u32 n)
{
	fill_rows(0, STRIP_H, WHITE);
	for (u32 i = 0; i < n && i < 9; i++)
		fill_rows(BAR_GAP + i * (BAR_H + BAR_GAP), BAR_H, BLACK);
}

static void trace(u32 step)
{
	volatile u32 *t = (volatile u32 *)TRACE_PA;
	t[0] = TRACE_MAGIC;
	t[1] = step;
}

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
	int depth = 0, in = 0;	/* root is itself a node, so top level is depth 2 */

	while (p < end) {
		u32 tag = be32(p); p += 4;

		if (tag == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			unsigned long l = 0;
			while (p[l]) l++;
			p += (l + 4) & ~3UL;
			depth++;
			/* Match "memory" against "memory@40000000" too. */
			if (depth == 2) {
				const char *a = name, *b = node;
				while (*b && *a == *b) { a++; b++; }
				in = (!*b && (!*a || *a == '@'));
			}
		} else if (tag == FDT_END_NODE) {
			if (depth == 2) in = 0;
			depth--;
		} else if (tag == FDT_PROP) {
			u32 plen = be32(p), noff = be32(p + 4);
			u8 *data = p + 8;
			p = data + ((plen + 3) & ~3U);
			if (in && depth == 2 && streq(strs + noff, prop)) {
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

/*
 * Copy a fixed-size property. The length must match exactly: LK writes
 * linux,initrd-start/end as 4-byte cells here, and dropping 4 bytes into an
 * 8-byte big-endian slot would leave the value in the high half -- a silently
 * wrong address rather than a failure. If the sizes ever disagree we would
 * rather fall back and boot stock.
 */
static int copy_exact(void *dst, void *src, const char *node, const char *prop)
{
	u32 slen = 0, dlen = 0;
	void *s = fdt_find(src, node, prop, &slen);
	void *d = fdt_find(dst, node, prop, &dlen);

	if (!s || !d || slen != dlen)
		return -1;
	memcpy_(d, s, slen);
	return 0;
}

/*
 * Flags our tree needs that LK's command line will never carry.
 *
 * LK builds the whole cmdline itself and we copy it verbatim, which means the
 * DTS bootargs are discarded -- including pd_ignore_unused. Without it genpd
 * powers the DISP domain off at ~4.8s ("PM: genpd: Disabling unused power
 * domains") before mtk-smi has claimed it, so every SMI probe defers and dies
 * at the 16s timeout, taking the whole display pipeline with it. LK leaves
 * that domain on for its own scanout; we just have to stop Linux turning it
 * off before the drivers arrive.
 */
/*
 * jagar_mt6789_probe_stage: the GCE (CMDQ mailbox) driver carries a bringup
 * staging gate that defaults to 0, which makes gce0 probe return -ENODEV
 * forever. mmsys names gce0 in mediatek,gce-client-reg, so fw_devlink holds
 * mmsys unprobed -- silently, no log line -- and with no mmsys there is no
 * clk-mt6789-mm, so SMI, mutex, the disp blocks and DSI all sit at -110.
 * Stage 4 is the plain upstream probe path.
 */
static const char extra_args[] =
	" pd_ignore_unused clk_ignore_unused regulator_ignore_unused"
	" mtk_cmdq_mailbox.jagar_mt6789_probe_stage=4";

/* Copy LK's cmdline, then append the flags above. Needs the padding pack.sh
 * puts on /chosen/bootargs; refuses rather than truncate. */
static int copy_bootargs(void *dst, void *src)
{
	u32 slen = 0, dlen = 0, n = 0;
	u8 *s = fdt_find(src, "chosen", "bootargs", &slen);
	u8 *d = fdt_find(dst, "chosen", "bootargs", &dlen);

	if (!s || !d)
		return -1;
	while (n < slen && s[n])		/* LK's string, without its NUL */
		n++;
	u32 extra = sizeof(extra_args) - 1;
	if (n + extra + 1 > dlen)
		return -1;
	memcpy_(d, s, n);
	memcpy_(d + n, extra_args, extra);
	for (u32 i = n + extra; i < dlen; i++)
		d[i] = 0;
	return 0;
}

unsigned long dtbswap_main(unsigned long lk_fdt, unsigned long base)
{
	void *lk = (void *)lk_fdt;
	void *our = (void *)(base + payload.dtb_off);
	void *kern_src = (void *)(base + payload.kern_off);
	void *kern_dst = (void *)KERNEL_RELOC_PA;

	trace(1);
	/* The kernel moves either way; only the fdt choice is conditional. */
	memcpy_(kern_dst, kern_src, payload.kern_len);
	jump_target = KERNEL_RELOC_PA;
	trace(2);

	if (!lk || be32(lk) != FDT_MAGIC) {
		report(2);			/* 2 bars: LK handed us no usable fdt */
		return lk_fdt;
	}
	trace(3);
	if (be32(our) != FDT_MAGIC) {
		report(3);			/* 3 bars: our payload is not an fdt */
		return lk_fdt;
	}
	trace(4);

	if (copy_bootargs(our, lk)) {
		report(4);			/* 4 bars: bootargs copy failed */
		return lk_fdt;
	}
	trace(5);
	if (copy_exact(our, lk, "chosen", "linux,initrd-start")) {
		report(5);			/* 5 bars: initrd-start failed */
		return lk_fdt;
	}
	trace(6);
	if (copy_exact(our, lk, "chosen", "linux,initrd-end")) {
		report(6);			/* 6 bars: initrd-end failed */
		return lk_fdt;
	}
	trace(7);
	if (copy_exact(our, lk, "memory", "reg")) {
		report(7);			/* 7 bars: /memory reg failed */
		return lk_fdt;
	}
	trace(8);

	report(8);				/* 8 bars: swapped, booting our dtb */
	return (unsigned long)our;
}
