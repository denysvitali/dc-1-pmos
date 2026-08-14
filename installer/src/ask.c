/*
 * dc1-ask -- single-purpose touch prompt screen for the DC-1 installer.
 *
 *   dc1-ask menu   TITLE OPTION...     -> prints the chosen 0-based index
 *   dc1-ask text   TITLE [DEFAULT]     -> on-screen keyboard, prints the text
 *   dc1-ask secret TITLE               -> like text, echoed as '*'
 *   dc1-ask info   TITLE [LINE...]     -> message + OK button, prints nothing
 *
 * Exit codes: 0 answered, 1 cancelled (text/secret X button), 2 unusable
 * (no framebuffer or no touchscreen -- callers fall back to the USB flow).
 *
 * Why hand-rolled instead of buffyboard/unl0kr: buffyboard injects keys via
 * /dev/uinput, which the pinned jagar kernel does not enable
 * (CONFIG_INPUT_UINPUT is absent from jagar_defconfig); unl0kr is no longer
 * packaged in Alpine, shows only a hardcoded password prompt, and drags in
 * libinput + xkbcommon + a running udevd -- none of which can be exercised
 * before first boot on hardware. This tool reuses the two interfaces the
 * installer ALREADY proves out: the framebuffer painting path from
 * src/init.c (fbdev-or-devmem, cached shadow buffer) and the built-in
 * evdev touchscreen (CONFIG_TOUCHSCREEN_ILITEK=y, CONFIG_INPUT_EVDEV=y).
 * It is static, musl/glibc-agnostic, and has zero runtime dependencies.
 *
 * Secrets: the entered text goes to stdout only. Nothing is written to
 * kmsg, no temp files, no argv leakage.
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include <linux/input.h>

/* Fallback geometry, measured from the live LK atag videolfb (see init.c). */
#define FB_PHYS    0xfe8c1000UL
#define FB_LEN     0x1650000UL
#define FB_W       1200
#define FB_H       1600
#define FB_STRIDE  ((1200 + 16) * 4)

#define MAX_TEXT   63          /* WPA-PSK maximum; longest field we collect */

/* ------------------------------ 5x7 font -------------------------------- */
/* Column-major, bit0 = top scanline, ASCII 0x20..0x7E (classic 5x7 forms). */
static const unsigned char font[95][5] = {
	{0x00,0x00,0x00,0x00,0x00}, {0x00,0x00,0x5f,0x00,0x00}, /*   ! */
	{0x00,0x07,0x00,0x07,0x00}, {0x14,0x7f,0x14,0x7f,0x14}, /* " # */
	{0x24,0x2a,0x7f,0x2a,0x12}, {0x23,0x13,0x08,0x64,0x62}, /* $ % */
	{0x36,0x49,0x55,0x22,0x50}, {0x00,0x05,0x03,0x00,0x00}, /* & ' */
	{0x00,0x1c,0x22,0x41,0x00}, {0x00,0x41,0x22,0x1c,0x00}, /* ( ) */
	{0x14,0x08,0x3e,0x08,0x14}, {0x08,0x08,0x3e,0x08,0x08}, /* * + */
	{0x00,0x50,0x30,0x00,0x00}, {0x08,0x08,0x08,0x08,0x08}, /* , - */
	{0x00,0x60,0x60,0x00,0x00}, {0x20,0x10,0x08,0x04,0x02}, /* . / */
	{0x3e,0x51,0x49,0x45,0x3e}, {0x00,0x42,0x7f,0x40,0x00}, /* 0 1 */
	{0x42,0x61,0x51,0x49,0x46}, {0x21,0x41,0x45,0x4b,0x31}, /* 2 3 */
	{0x18,0x14,0x12,0x7f,0x10}, {0x27,0x45,0x45,0x45,0x39}, /* 4 5 */
	{0x3c,0x4a,0x49,0x49,0x30}, {0x01,0x71,0x09,0x05,0x03}, /* 6 7 */
	{0x36,0x49,0x49,0x49,0x36}, {0x06,0x49,0x49,0x29,0x1e}, /* 8 9 */
	{0x00,0x36,0x36,0x00,0x00}, {0x00,0x56,0x36,0x00,0x00}, /* : ; */
	{0x00,0x08,0x14,0x22,0x41}, {0x14,0x14,0x14,0x14,0x14}, /* < = */
	{0x41,0x22,0x14,0x08,0x00}, {0x02,0x01,0x51,0x09,0x06}, /* > ? */
	{0x32,0x49,0x79,0x41,0x3e},                              /* @   */
	{0x7e,0x11,0x11,0x11,0x7e}, {0x7f,0x49,0x49,0x49,0x36}, /* A B */
	{0x3e,0x41,0x41,0x41,0x22}, {0x7f,0x41,0x41,0x22,0x1c}, /* C D */
	{0x7f,0x49,0x49,0x49,0x41}, {0x7f,0x09,0x09,0x09,0x01}, /* E F */
	{0x3e,0x41,0x49,0x49,0x7a}, {0x7f,0x08,0x08,0x08,0x7f}, /* G H */
	{0x00,0x41,0x7f,0x41,0x00}, {0x20,0x40,0x41,0x3f,0x01}, /* I J */
	{0x7f,0x08,0x14,0x22,0x41}, {0x7f,0x40,0x40,0x40,0x40}, /* K L */
	{0x7f,0x02,0x0c,0x02,0x7f}, {0x7f,0x04,0x08,0x10,0x7f}, /* M N */
	{0x3e,0x41,0x41,0x41,0x3e}, {0x7f,0x09,0x09,0x09,0x06}, /* O P */
	{0x3e,0x41,0x51,0x21,0x5e}, {0x7f,0x09,0x19,0x29,0x46}, /* Q R */
	{0x46,0x49,0x49,0x49,0x31}, {0x01,0x01,0x7f,0x01,0x01}, /* S T */
	{0x3f,0x40,0x40,0x40,0x3f}, {0x1f,0x20,0x40,0x20,0x1f}, /* U V */
	{0x7f,0x20,0x18,0x20,0x7f}, {0x63,0x14,0x08,0x14,0x63}, /* W X */
	{0x03,0x04,0x78,0x04,0x03}, {0x61,0x51,0x49,0x45,0x43}, /* Y Z */
	{0x00,0x7f,0x41,0x41,0x00}, {0x02,0x04,0x08,0x10,0x20}, /* [ \ */
	{0x00,0x41,0x41,0x7f,0x00}, {0x04,0x02,0x01,0x02,0x04}, /* ] ^ */
	{0x40,0x40,0x40,0x40,0x40}, {0x00,0x01,0x02,0x04,0x00}, /* _ ` */
	{0x20,0x54,0x54,0x54,0x78}, {0x7f,0x48,0x44,0x44,0x38}, /* a b */
	{0x38,0x44,0x44,0x44,0x20}, {0x38,0x44,0x44,0x48,0x7f}, /* c d */
	{0x38,0x54,0x54,0x54,0x18}, {0x08,0x7e,0x09,0x01,0x02}, /* e f */
	{0x0c,0x52,0x52,0x52,0x3e}, {0x7f,0x08,0x04,0x04,0x78}, /* g h */
	{0x00,0x44,0x7d,0x40,0x00}, {0x20,0x40,0x44,0x3d,0x00}, /* i j */
	{0x7f,0x10,0x28,0x44,0x00}, {0x00,0x41,0x7f,0x40,0x00}, /* k l */
	{0x7c,0x04,0x18,0x04,0x78}, {0x7c,0x08,0x04,0x04,0x78}, /* m n */
	{0x38,0x44,0x44,0x44,0x38}, {0x7c,0x14,0x14,0x14,0x08}, /* o p */
	{0x08,0x14,0x14,0x18,0x7c}, {0x7c,0x08,0x04,0x04,0x08}, /* q r */
	{0x48,0x54,0x54,0x54,0x20}, {0x04,0x3f,0x44,0x40,0x20}, /* s t */
	{0x3c,0x40,0x40,0x20,0x7c}, {0x1c,0x20,0x40,0x20,0x1c}, /* u v */
	{0x3c,0x40,0x30,0x40,0x3c}, {0x44,0x28,0x10,0x28,0x44}, /* w x */
	{0x0c,0x50,0x50,0x50,0x3c}, {0x44,0x64,0x54,0x4c,0x44}, /* y z */
	{0x00,0x08,0x36,0x41,0x00}, {0x00,0x00,0x7f,0x00,0x00}, /* { | */
	{0x00,0x41,0x36,0x08,0x00}, {0x08,0x04,0x08,0x10,0x08}, /* } ~ */
};

/* --------------------------- framebuffer -------------------------------- */

struct fb {
	volatile uint8_t *mem;
	uint8_t *shadow;
	unsigned long len, one;
	unsigned w, h, stride, bpp;
};

static void px(struct fb *f, unsigned x, unsigned y, uint32_t c)
{
	if (x >= f->w || y >= f->h)
		return;
	unsigned long off = (unsigned long)y * f->stride + (unsigned long)x * 4;
	if (off + 4 <= f->one)
		*(uint32_t *)(f->shadow + off) = c;
}

static void fillrect(struct fb *f, int x0, int y0, int w, int h, uint32_t c)
{
	for (int y = y0; y < y0 + h; y++)
		for (int x = x0; x < x0 + w; x++)
			px(f, (unsigned)x, (unsigned)y, c);
}

static void blit(struct fb *f)
{
	if (f->one <= f->len)
		memcpy((void *)f->mem, f->shadow, f->one);
}

static void draw_text(struct fb *f, int x0, int y0, int s, uint32_t c,
		      const char *str)
{
	int x = x0;
	for (const char *p = str; *p; p++) {
		int idx = (*p >= 0x20 && *p <= 0x7e) ? *p - 0x20 : 0;
		const unsigned char *g = font[idx];
		for (int col = 0; col < 5; col++)
			for (int row = 0; row < 7; row++)
				if (g[col] & (1 << row))
					fillrect(f, x + col * s, y0 + row * s, s, s, c);
		x += 6 * s;
	}
}

static int text_w(int s, const char *str)
{
	return (int)strlen(str) * 6 * s;
}

static int fb_shadow(struct fb *f)
{
	if (f->bpp != 32 || !f->w || !f->h || f->stride < f->w * 4)
		return -1;
	f->one = (unsigned long)f->stride * f->h;
	if (f->one > f->len)
		return -1;
	void *s = mmap(NULL, f->one, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (s == MAP_FAILED)
		return -1;
	f->shadow = s;
	return 0;
}

static int fb_open(struct fb *f)
{
	struct fb_var_screeninfo v;
	struct fb_fix_screeninfo x;
	int fd = open("/dev/fb0", O_RDWR);

	if (fd >= 0 && !ioctl(fd, FBIOGET_VSCREENINFO, &v) &&
	    !ioctl(fd, FBIOGET_FSCREENINFO, &x)) {
		unsigned long len = x.smem_len ? x.smem_len
				  : (unsigned long)x.line_length * v.yres;
		void *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED,
			       fd, 0);
		if (m != MAP_FAILED) {
			f->mem = m;
			f->len = len;
			f->w = v.xres;
			f->h = v.yres;
			f->stride = x.line_length ? x.line_length : v.xres * 4;
			f->bpp = v.bits_per_pixel ? v.bits_per_pixel : 32;
			if (!fb_shadow(f))
				return 0;
			munmap(m, len);
		}
	}
	if (fd >= 0)
		close(fd);

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0)
		return -1;
	void *m = mmap(NULL, FB_LEN, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		       (off_t)FB_PHYS);
	if (m == MAP_FAILED) {
		close(fd);
		return -1;
	}
	f->mem = m;
	f->len = FB_LEN;
	f->w = FB_W;
	f->h = FB_H;
	f->stride = FB_STRIDE;
	f->bpp = 32;
	if (fb_shadow(f)) {
		munmap(m, FB_LEN);
		close(fd);
		return -1;
	}
	return 0;
}

/* ------------------------------ touch ----------------------------------- */

struct touch {
	int fd;
	int min_x, max_x, min_y, max_y;
	int x, y;              /* latest raw position */
	int down;
};

static int has_bit(const unsigned long *bits, int bit)
{
	return (bits[bit / (8 * sizeof(long))] >>
		(bit % (8 * sizeof(long)))) & 1;
}

static int touch_open(struct touch *t)
{
	char path[64];

	for (int i = 0; i < 32; i++) {
		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		int fd = open(path, O_RDONLY);
		if (fd < 0)
			continue;
		unsigned long abs_bits[(ABS_MAX + 8 * sizeof(long)) /
				       (8 * sizeof(long))];
		memset(abs_bits, 0, sizeof(abs_bits));
		if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits) < 0) {
			close(fd);
			continue;
		}
		int ax = -1, ay = -1;
		if (has_bit(abs_bits, ABS_MT_POSITION_X) &&
		    has_bit(abs_bits, ABS_MT_POSITION_Y)) {
			ax = ABS_MT_POSITION_X;
			ay = ABS_MT_POSITION_Y;
		} else if (has_bit(abs_bits, ABS_X) && has_bit(abs_bits, ABS_Y)) {
			ax = ABS_X;
			ay = ABS_Y;
		}
		if (ax < 0) {
			close(fd);
			continue;
		}
		struct input_absinfo ix, iy;
		if (ioctl(fd, EVIOCGABS(ax), &ix) < 0 ||
		    ioctl(fd, EVIOCGABS(ay), &iy) < 0) {
			close(fd);
			continue;
		}
		t->fd = fd;
		t->min_x = ix.minimum;
		t->max_x = ix.maximum > ix.minimum ? ix.maximum : ix.minimum + 1;
		t->min_y = iy.minimum;
		t->max_y = iy.maximum > iy.minimum ? iy.maximum : iy.minimum + 1;
		t->x = t->y = 0;
		t->down = 0;
		return 0;
	}
	return -1;
}

/* Block until a complete tap (touch down then up); return the release
 * position scaled to screen coordinates. */
static int touch_tap(struct touch *t, struct fb *f, int *sx, int *sy)
{
	struct input_event ev;
	int was_down = t->down;

	for (;;) {
		ssize_t n = read(t->fd, &ev, sizeof(ev));
		if (n != (ssize_t)sizeof(ev))
			return -1;
		switch (ev.type) {
		case EV_ABS:
			if (ev.code == ABS_MT_POSITION_X || ev.code == ABS_X)
				t->x = ev.value;
			else if (ev.code == ABS_MT_POSITION_Y || ev.code == ABS_Y)
				t->y = ev.value;
			else if (ev.code == ABS_MT_TRACKING_ID)
				t->down = (ev.value >= 0);
			break;
		case EV_KEY:
			if (ev.code == BTN_TOUCH)
				t->down = ev.value ? 1 : 0;
			break;
		case EV_SYN:
			if (was_down && !t->down) {
				*sx = (int)((long)(t->x - t->min_x) * f->w /
					    (t->max_x - t->min_x));
				*sy = (int)((long)(t->y - t->min_y) * f->h /
					    (t->max_y - t->min_y));
				return 0;
			}
			was_down = t->down;
			break;
		}
	}
}

static int in_rect(int x, int y, int rx, int ry, int rw, int rh)
{
	return x >= rx && x < rx + rw && y >= ry && y < ry + rh;
}

/* ------------------------------ chrome ---------------------------------- */

#define C_BG     0xff000000u
#define C_FG     0xffffffffu
#define C_ACCENT 0xff00ff00u
#define C_KEY    0xff303030u
#define C_KEYTXT 0xffffffffu
#define C_BOX    0xff202020u
#define C_DIM    0xff808080u

static void draw_title(struct fb *f, const char *title)
{
	fillrect(f, 0, 0, (int)f->w, (int)f->h, C_BG);
	fillrect(f, 0, 0, (int)f->w, 8, C_FG);
	int s = 5;
	while (s > 2 && text_w(s, title) > (int)f->w - 80)
		s--;
	draw_text(f, 40, 60, s, C_FG, title);
}

/* One rounded-off button; label centred. */
static void draw_button(struct fb *f, int x, int y, int w, int h,
			uint32_t bg, uint32_t fg, int s, const char *label)
{
	fillrect(f, x, y, w, h, bg);
	while (s > 1 && text_w(s, label) > w - 20)
		s--;
	int tx = x + (w - text_w(s, label)) / 2;
	int ty = y + (h - 7 * s) / 2;
	draw_text(f, tx, ty, s, fg, label);
}

/* ------------------------------ menu ------------------------------------ */

#define MENU_PAGE 6

static int run_menu(struct fb *f, struct touch *t, const char *title,
		    int n, char **opts)
{
	int page = 0;
	int pages = (n + MENU_PAGE - 1) / MENU_PAGE;
	int bx = 40, bw = (int)f->w - 80, bh = 130, gap = 24, by0 = 220;

	if (pages < 1)
		pages = 1;
	for (;;) {
		draw_title(f, title);
		int first = page * MENU_PAGE;
		int count = n - first;
		if (count > MENU_PAGE)
			count = MENU_PAGE;
		for (int i = 0; i < count; i++)
			draw_button(f, bx, by0 + i * (bh + gap), bw, bh,
				    C_KEY, C_KEYTXT, 4, opts[first + i]);
		int more_y = by0 + MENU_PAGE * (bh + gap) + 20;
		if (pages > 1) {
			char lbl[32];
			snprintf(lbl, sizeof(lbl), "MORE (%d/%d)", page + 1,
				 pages);
			draw_button(f, bx, more_y, bw, bh, C_BOX, C_ACCENT, 4,
				    lbl);
		}
		blit(f);

		int x, y;
		if (touch_tap(t, f, &x, &y) < 0)
			return -1;
		for (int i = 0; i < count; i++)
			if (in_rect(x, y, bx, by0 + i * (bh + gap), bw, bh))
				return first + i;
		if (pages > 1 && in_rect(x, y, bx, more_y, bw, bh))
			page = (page + 1) % pages;
	}
}

/* ------------------------------ info ------------------------------------ */

static int run_info(struct fb *f, struct touch *t, const char *title,
		    int n, char **lines)
{
	int bx = 40, bw = (int)f->w - 80, bh = 130;
	int ok_y = (int)f->h - 200;

	draw_title(f, title);
	int y = 220;
	for (int i = 0; i < n && y < ok_y - 40; i++) {
		int s = 3;
		while (s > 1 && text_w(s, lines[i]) > (int)f->w - 80)
			s--;
		draw_text(f, 40, y, s, C_FG, lines[i]);
		y += 60;
	}
	draw_button(f, bx, ok_y, bw, bh, 0xff006000u, C_FG, 5, "OK");
	blit(f);

	for (;;) {
		int x, ty;
		if (touch_tap(t, f, &x, &ty) < 0)
			return -1;
		if (in_rect(x, ty, bx, ok_y, bw, bh))
			return 0;
	}
}

/* ------------------------- text entry + keyboard ------------------------- */

/* Special key codes (never printable ASCII). */
#define K_NONE  0
#define K_SHIFT 1
#define K_SYM   2
#define K_BS    3
#define K_OK    4
#define K_CANCEL 5

/* Layer rows: 10 cells each for rows 0..3; row 4 is fixed special. */
static const char *rows_lower[4]  = { "1234567890", "qwertyuiop",
				      "asdfghjkl-", "\001zxcvbnm.\003" };
static const char *rows_upper[4]  = { "1234567890", "QWERTYUIOP",
				      "ASDFGHJKL-", "\001ZXCVBNM.\003" };
static const char *rows_sym[4]    = { "1234567890", "!@#$%^&*()",
				      "-_=+[]{};:", "\002'\",<>/?\\\003" };
/* note: rows_sym[3] has 9 cells + backspace = 10 */

struct kb_geom {
	int top, cell_w, cell_h;
};

static void kb_geometry(struct fb *f, struct kb_geom *g)
{
	g->cell_h = (int)f->h / 11;
	g->top = (int)f->h - 5 * g->cell_h;
	g->cell_w = (int)f->w / 10;
}

static void draw_key(struct fb *f, int x, int y, int w, int h, uint32_t bg,
		     const char *label)
{
	fillrect(f, x + 4, y + 4, w - 8, h - 8, bg);
	int s = 4;
	while (s > 1 && text_w(s, label) > w - 16)
		s--;
	draw_text(f, x + (w - text_w(s, label)) / 2, y + (h - 7 * s) / 2, s,
		  C_KEYTXT, label);
}

static void draw_keyboard(struct fb *f, struct kb_geom *g, int layer,
			  int shifted)
{
	const char **rows = layer ? rows_sym : (shifted ? rows_upper
						       : rows_lower);
	char lbl[2] = { 0, 0 };

	fillrect(f, 0, g->top, (int)f->w, 5 * g->cell_h, C_BG);
	for (int r = 0; r < 4; r++) {
		int y = g->top + r * g->cell_h;
		const char *row = rows[r];
		int len = (int)strlen(row);
		for (int c = 0; c < len && c < 10; c++) {
			int x = c * g->cell_w;
			switch (row[c]) {
			case K_SHIFT:
				draw_key(f, x, y, g->cell_w, g->cell_h,
					 shifted ? 0xff005000u : C_BOX, "SH");
				break;
			case K_SYM:
				draw_key(f, x, y, g->cell_w, g->cell_h,
					 C_BOX, "AB");
				break;
			case K_BS:
				draw_key(f, x, y, g->cell_w, g->cell_h,
					 C_BOX, "<X");
				break;
			default:
				lbl[0] = row[c];
				draw_key(f, x, y, g->cell_w, g->cell_h,
					 C_KEY, lbl);
			}
		}
	}
	/* row 4: [SYM/ABC x2][SPACE x5][@ or ~ x1][OK x2] */
	int y = g->top + 4 * g->cell_h;
	draw_key(f, 0, y, 2 * g->cell_w, g->cell_h, C_BOX,
		 layer ? "abc" : "?123");
	draw_key(f, 2 * g->cell_w, y, 5 * g->cell_w, g->cell_h, C_KEY, " ");
	draw_key(f, 7 * g->cell_w, y, g->cell_w, g->cell_h, C_KEY,
		 layer ? "~" : "@");
	draw_key(f, 8 * g->cell_w, y, 2 * g->cell_w, g->cell_h, 0xff006000u,
		 "OK");
}

/* Map a tap to a key: returns a printable char, or a K_* code. */
static int kb_hit(struct fb *f, struct kb_geom *g, int layer, int shifted,
		  int x, int y)
{
	(void)f;
	if (y < g->top)
		return K_NONE;
	int r = (y - g->top) / g->cell_h;
	int c = x / g->cell_w;
	if (c > 9)
		c = 9;
	if (r < 4) {
		const char **rows = layer ? rows_sym
					  : (shifted ? rows_upper : rows_lower);
		const char *row = rows[r];
		if (c >= (int)strlen(row))
			return K_NONE;
		return (unsigned char)row[c];
	}
	if (c < 2)
		return K_SYM;
	if (c < 7)
		return ' ';
	if (c < 8)
		return layer ? '~' : '@';
	return K_OK;
}

static int run_text(struct fb *f, struct touch *t, const char *title,
		    const char *initial, int secret)
{
	char buf[MAX_TEXT + 1];
	int len = 0, layer = 0, shifted = 0;
	struct kb_geom g;

	kb_geometry(f, &g);
	buf[0] = 0;
	if (initial && !secret) {
		strncpy(buf, initial, MAX_TEXT);
		buf[MAX_TEXT] = 0;
		len = (int)strlen(buf);
	}

	for (;;) {
		draw_title(f, title);
		/* cancel box, top right */
		int cx = (int)f->w - 140, cy = 30, cw = 100, ch = 100;
		draw_button(f, cx, cy, cw, ch, C_BOX, C_DIM, 5, "X");

		/* entry box */
		int ey = 260, eh = 120;
		fillrect(f, 40, ey, (int)f->w - 80, eh, C_BOX);
		char shown[MAX_TEXT + 2];
		if (secret) {
			for (int i = 0; i < len; i++)
				shown[i] = '*';
			shown[len] = 0;
		} else {
			memcpy(shown, buf, (size_t)len + 1);
		}
		int s = 4;
		int maxcols = ((int)f->w - 120) / (6 * s);
		const char *tail = shown;
		if ((int)strlen(shown) > maxcols)
			tail = shown + strlen(shown) - (size_t)maxcols;
		draw_text(f, 60, ey + (eh - 7 * s) / 2, s, C_ACCENT, tail);
		/* caret */
		fillrect(f, 60 + text_w(s, tail) + 4, ey + 20, 8, eh - 40,
			 C_ACCENT);

		draw_keyboard(f, &g, layer, shifted);
		blit(f);

		int x, y;
		if (touch_tap(t, f, &x, &y) < 0)
			return -1;
		if (in_rect(x, y, cx, cy, cw, ch))
			return 1;                          /* cancelled */
		int k = kb_hit(f, &g, layer, shifted, x, y);
		switch (k) {
		case K_NONE:
			break;
		case K_SHIFT:
			shifted = !shifted;
			break;
		case K_SYM:
			layer = !layer;
			shifted = 0;
			break;
		case K_BS:
			if (len > 0)
				buf[--len] = 0;
			break;
		case K_OK:
			fputs(buf, stdout);
			fputc('\n', stdout);
			fflush(stdout);
			return 0;
		default:
			if (k >= 0x20 && k <= 0x7e && len < MAX_TEXT) {
				buf[len++] = (char)k;
				buf[len] = 0;
				if (shifted)
					shifted = 0;
			}
		}
	}
}

/* ------------------------------- main ------------------------------------ */

int main(int argc, char **argv)
{
	struct fb f;
	struct touch t;

	if (argc < 3) {
		fprintf(stderr,
			"usage: dc1-ask menu|text|secret|info TITLE ...\n");
		return 2;
	}
	memset(&f, 0, sizeof(f));
	if (fb_open(&f)) {
		fprintf(stderr, "dc1-ask: no framebuffer\n");
		return 2;
	}
	if (touch_open(&t)) {
		fprintf(stderr, "dc1-ask: no touchscreen\n");
		return 2;
	}

	const char *mode = argv[1];
	const char *title = argv[2];

	if (!strcmp(mode, "menu")) {
		if (argc < 4) {
			fprintf(stderr, "dc1-ask: menu needs options\n");
			return 2;
		}
		int r = run_menu(&f, &t, title, argc - 3, argv + 3);
		if (r < 0)
			return 2;
		printf("%d\n", r);
		return 0;
	}
	if (!strcmp(mode, "text")) {
		int r = run_text(&f, &t, title, argc > 3 ? argv[3] : "", 0);
		return r < 0 ? 2 : r;
	}
	if (!strcmp(mode, "secret")) {
		int r = run_text(&f, &t, title, NULL, 1);
		return r < 0 ? 2 : r;
	}
	if (!strcmp(mode, "info")) {
		int r = run_info(&f, &t, title, argc - 3, argv + 3);
		return r < 0 ? 2 : 0;
	}
	fprintf(stderr, "dc1-ask: unknown mode %s\n", mode);
	return 2;
}
