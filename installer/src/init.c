/*
 * dc1-installer-init -- PID 1 of the DC-1 "installation mode" initramfs.
 *
 * Single purpose: bring the device to a state where the host-side installer
 * (installer/host/dc1-install.sh) can reach it over the USB cable that
 * fastboot already used, and show the user what is happening on the panel.
 *
 * It does exactly four things and then loops forever:
 *   1. mount proc / sysfs / devtmpfs / configfs
 *   2. bring up the USB gadget (2x CDC-ACM serial + CDC-ECM ethernet)
 *   3. fork /etc/rc.sh (busybox second stage: network, shells, installd)
 *   4. paint an "INSTALLER" status screen from /tmp/installer-status
 *
 * Derived from the bring-up initramfs init for this device, minus everything
 * an installer does not need (boot-proof animation, switch_root, deadman
 * lease machinery). The hardware facts encoded here cost boot cycles to
 * learn; do not re-derive them:
 *
 *   - devtmpfs is NOT auto-mounted on an initramfs boot: devtmpfs_mount() is
 *     only called from prepare_namespace(), which the kernel skips when it
 *     runs rdinit. /init must mount it or /dev/kmsg and /dev/dri/card0 never
 *     appear.
 *   - the panel is dark at boot and only lights via a DRM atomic commit after
 *     the runtime display gate is opened (see open_panel_gate()); /dev/fb0 and
 *     the LK scanout buffer are dead instruments on this panel. See the gate
 *     block below -- this cost boot cycles to learn, do not re-derive it.
 *   - the UDC name candidates below are the ones the MTU3 driver actually
 *     registers on this SoC; rc.sh retries with the real name from
 *     /sys/class/udc if the guess misses.
 *
 * If /init exits the kernel panics, so it never exits.
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>
#include <errno.h>
#include <stdlib.h>

#define STATUS_FILE "/tmp/installer-status"

static int g_kmsg = -1;

/* ---------------- tiny write helpers (no stdio dependency) --------------- */

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

static char *u2s(unsigned long v, char *buf)   /* buf must be >= 21 bytes */
{
	char tmp[21];
	int i = 0;
	if (!v) tmp[i++] = '0';
	while (v) { tmp[i++] = '0' + (v % 10); v /= 10; }
	int j = 0;
	while (i) buf[j++] = tmp[--i];
	buf[j] = 0;
	return buf;
}

/* Broadcast one line to every text channel we might have. */
static void say(const char *msg)
{
	static const char *tty[] = { "/dev/tty0", "/dev/tty1", "/dev/console",
				     "/dev/ttyS0", "/dev/ttyGS0", NULL };
	char line[512];
	size_t n = slen(msg);
	if (n > sizeof(line) - 16) n = sizeof(line) - 16;

	memcpy(line, "[dc1-installer] ", 16);
	memcpy(line + 16, msg, n);
	line[16 + n] = '\n';
	size_t len = 16 + n + 1;

	(void)write(1, line, len);
	(void)write(2, line, len);
	if (g_kmsg >= 0) (void)write(g_kmsg, line, len);

	for (int i = 0; tty[i]; i++) {
		int fd = open(tty[i], O_WRONLY | O_NONBLOCK | O_NOCTTY);
		if (fd < 0) continue;
		(void)write(fd, line, len);
		close(fd);
	}
}

static void say2(const char *a, const char *b)
{
	char buf[512];
	size_t la = slen(a), lb = slen(b);
	if (la > 240) la = 240;
	if (lb > 240) lb = 240;
	memcpy(buf, a, la);
	memcpy(buf + la, b, lb);
	buf[la + lb] = 0;
	say(buf);
}

/* ---------------------------- 5x7 bitmap font ---------------------------- */
/* One byte per column, bit0 = top scanline. A-Z 0-9 and light punctuation. */
static const unsigned char font5x7[][5] = {
	{0x00,0x00,0x00,0x00,0x00}, /* ' ' */
	{0x7e,0x11,0x11,0x11,0x7e}, /* A */
	{0x7f,0x49,0x49,0x49,0x36}, /* B */
	{0x3e,0x41,0x41,0x41,0x22}, /* C */
	{0x7f,0x41,0x41,0x22,0x1c}, /* D */
	{0x7f,0x49,0x49,0x49,0x41}, /* E */
	{0x7f,0x09,0x09,0x09,0x01}, /* F */
	{0x3e,0x41,0x49,0x49,0x7a}, /* G */
	{0x7f,0x08,0x08,0x08,0x7f}, /* H */
	{0x00,0x41,0x7f,0x41,0x00}, /* I */
	{0x20,0x40,0x41,0x3f,0x01}, /* J */
	{0x7f,0x08,0x14,0x22,0x41}, /* K */
	{0x7f,0x40,0x40,0x40,0x40}, /* L */
	{0x7f,0x02,0x0c,0x02,0x7f}, /* M */
	{0x7f,0x04,0x08,0x10,0x7f}, /* N */
	{0x3e,0x41,0x41,0x41,0x3e}, /* O */
	{0x7f,0x09,0x09,0x09,0x06}, /* P */
	{0x3e,0x41,0x51,0x21,0x5e}, /* Q */
	{0x7f,0x09,0x19,0x29,0x46}, /* R */
	{0x46,0x49,0x49,0x49,0x31}, /* S */
	{0x01,0x01,0x7f,0x01,0x01}, /* T */
	{0x3f,0x40,0x40,0x40,0x3f}, /* U */
	{0x1f,0x20,0x40,0x20,0x1f}, /* V */
	{0x7f,0x20,0x18,0x20,0x7f}, /* W */
	{0x63,0x14,0x08,0x14,0x63}, /* X */
	{0x03,0x04,0x78,0x04,0x03}, /* Y */
	{0x61,0x51,0x49,0x45,0x43}, /* Z */
	{0x3e,0x51,0x49,0x45,0x3e}, /* 0 */
	{0x00,0x42,0x7f,0x40,0x00}, /* 1 */
	{0x42,0x61,0x51,0x49,0x46}, /* 2 */
	{0x21,0x41,0x45,0x4b,0x31}, /* 3 */
	{0x18,0x14,0x12,0x7f,0x10}, /* 4 */
	{0x27,0x45,0x45,0x45,0x39}, /* 5 */
	{0x3c,0x4a,0x49,0x49,0x30}, /* 6 */
	{0x01,0x71,0x09,0x05,0x03}, /* 7 */
	{0x36,0x49,0x49,0x49,0x36}, /* 8 */
	{0x06,0x49,0x49,0x29,0x1e}, /* 9 */
	{0x08,0x08,0x08,0x08,0x08}, /* - */
	{0x00,0x36,0x36,0x00,0x00}, /* : */
	{0x00,0x60,0x60,0x00,0x00}, /* . */
	{0x08,0x08,0x3e,0x08,0x08}, /* + */
	{0x00,0x00,0x5f,0x00,0x00}, /* ! */
	{0x20,0x10,0x08,0x04,0x02}, /* / */
	{0x14,0x14,0x14,0x14,0x14}, /* = */
};

static int glyph(char c)
{
	if (c >= 'a' && c <= 'z') c -= 32;
	if (c == ' ')  return 0;
	if (c >= 'A' && c <= 'Z') return 1  + (c - 'A');
	if (c >= '0' && c <= '9') return 27 + (c - '0');
	if (c == '-')  return 37;
	if (c == ':')  return 38;
	if (c == '.')  return 39;
	if (c == '+')  return 40;
	if (c == '!')  return 41;
	if (c == '/')  return 42;
	if (c == '=')  return 43;
	return 0;
}

/* --------------------------- framebuffer painting ----------------------- */

struct fbinfo {
	volatile uint8_t *mem;        /* the real scanout buffer (uncached) */
	uint8_t *shadow;              /* normal cached RAM we actually draw into */
	unsigned long len;            /* bytes mapped from the device */
	unsigned long one;            /* bytes in ONE frame = stride * h */
	unsigned int w, h, stride, bpp;
	int fd;                       /* DRM fd owning the buffer; never closed */
	const char *how;              /* provenance, for the log */
};

/* All drawing goes to the shadow buffer, never straight to the framebuffer:
 * a /dev/mem or fbdev mapping is uncached Device memory, and per-pixel 4-byte
 * stores there are pathologically slow. Draw cached, then memcpy scanlines. */
static void px(struct fbinfo *f, unsigned x, unsigned y, uint32_t argb)
{
	if (x >= f->w || y >= f->h) return;
	unsigned long off = (unsigned long)y * f->stride + (unsigned long)x * 4;
	if (off + 4 > f->one) return;
	*(uint32_t *)(f->shadow + off) = argb;
}

static void blit(struct fbinfo *f)
{
	if (f->one <= f->len)
		memcpy((void *)f->mem, f->shadow, f->one);
}

static void fillrect(struct fbinfo *f, unsigned x0, unsigned y0,
		     unsigned w, unsigned h, uint32_t argb)
{
	for (unsigned y = y0; y < y0 + h; y++)
		for (unsigned x = x0; x < x0 + w; x++)
			px(f, x, y, argb);
}

static void text(struct fbinfo *f, unsigned x0, unsigned y0, unsigned s,
		 uint32_t fg, const char *str)
{
	unsigned x = x0;
	for (const char *p = str; *p; p++) {
		const unsigned char *g = font5x7[glyph(*p)];
		for (int col = 0; col < 5; col++)
			for (int row = 0; row < 7; row++)
				if (g[col] & (1 << row))
					fillrect(f, x + col * s, y0 + row * s, s, s, fg);
		x += 6 * s;
	}
}

/* Only 32bpp is handled; anything else and we bail rather than draw garbage.
 * The DC-1's LK scanout is a8r8g8b8, so this is the expected case. */
static int fb_alloc_shadow(struct fbinfo *f)
{
	if (f->bpp != 32 || !f->w || !f->h || f->stride < f->w * 4) return -1;
	f->one = (unsigned long)f->stride * f->h;
	if (f->one > f->len) return -1;
	void *s = mmap(NULL, f->one, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (s == MAP_FAILED) return -1;
	f->shadow = s;
	return 0;
}

/* --------------------------- display gate + DRM --------------------------
 * The DC-1 panel is held OFF at boot: the panel driver parks its probe behind
 * two module parameters (jagar_probe_stage=0 "hold", jagar_production_sequence
 * N) until a user gates them on at runtime. Opening them too early during boot
 * DOES NOT BOOT (LK falls back to the other slot), so this stays a runtime
 * step. The gate is runtime-only -- module params plus deferred-probe pokes --
 * it resets on reboot and writes no storage.
 *
 * And /dev/fb0 does NOT reach the glass on this panel: two maximally different
 * framebuffers written through the fbdev emulation produced photographically
 * identical panels. Only a DRM atomic commit reaches the glass. The legacy
 * SETCRTC ioctl below is used because the kernel routes it through the atomic
 * path internally, which is the only citable display channel. */

static int wr(const char *path, const char *val);

static int exists(const char *p) { return access(p, F_OK) == 0; }

static int wait_for(const char *path, int seconds)
{
	for (int n = 0; n < seconds; n++) {
		if (exists(path)) return 0;
		sleep(1);
	}
	return -1;
}

/* Open the panel gate. Returns 0 once /dev/dri/card0 is bound. */
static int open_panel_gate(void)
{
	static const char *panel = "/sys/module/panel_novatek_nt36523/parameters";
	static const char *skip  = "/sys/module/mediatek_drm/parameters/jagar_skip_drm_client";
	static const char *gce_param = "/sys/module/mtk_cmdq_mailbox/parameters/jagar_mt6789_probe_stage";
	static const char *gce_drv   = "/sys/bus/platform/devices/10228000.gce/driver";
	static const char *dsi_dev   = "/sys/bus/mipi-dsi/devices/14013000.dsi.0";
	static const char *prod = "/sys/module/panel_novatek_nt36523/parameters/jagar_production_sequence";
	static const char *stage = "/sys/module/panel_novatek_nt36523/parameters/jagar_probe_stage";

	if (!exists(panel)) { say("gate: no panel driver (wrong kernel?)"); return -1; }

	/* Tell mediatek-drm to skip its intermediate DRM client, so no fbdev
	 * helper performs the first modeset -- the first real KMS client (us)
	 * gets the panel. */
	if (wr(skip, "Y\n") != 0) { say("gate: cannot set skip_drm_client"); return -1; }

	/* Bind GCE/CMDQ before the panel gate (safe probe order: opening the
	 * panel first makes GCE registration trigger the whole dependent DRM
	 * chain synchronously and can wedge the interconnect). */
	if (!exists(gce_drv)) {
		if (wr(gce_param, "4\n") != 0 ||
		    wr("/sys/bus/platform/drivers_probe", "10228000.gce\n") != 0) {
			say("gate: GCE bind write failed");
			return -1;
		}
		if (wait_for(gce_drv, 5) != 0) {
			say("gate: GCE did not bind"); return -1;
		}
	}

	if (wait_for(dsi_dev, 15) != 0) {
		say("gate: DSI panel device did not appear"); return -1;
	}

	/* Silence the kernel console before the display controller changes
	 * owners (prevents a jagarfb-style console from repainting the stale
	 * scanout). Our own status goes to /dev/kmsg and serial, which printk
	 * level does not gate. */
	(void)wr("/proc/sys/kernel/printk", "1 4 1 7\n");

	/* Power the panel and poke the deferred probe to retry. */
	if (wr(prod, "Y\n") != 0 ||
	    wr(stage, "3\n") != 0 ||
	    wr("/sys/bus/mipi-dsi/drivers_probe", "14013000.dsi.0\n") != 0) {
		say("gate: panel open write failed");
		return -1;
	}

	if (wait_for("/dev/dri/card0", 15) != 0) {
		say("gate: /dev/dri/card0 did not appear"); return -1;
	}
	say("gate: display opened");
	return 0;
}

/* Acquire the display via DRM: open the gate, allocate a dumb buffer, scan it
 * out, and leave it mapped for paint()/blit() to draw into.
 *
 * 32 bpp XRGB8888 only: the existing painter is 32 bpp. The 1200x1600 buffer
 * is 7.68 MB of contiguous coherent memory; the postmarketOS kernel satisfies
 * this via its CMA pool (CREATE_DUMB 32bpp verified OK on the installer kernel
 * 2026-08-14). The bring-up diagnostic kernel could not (its only CMA area
 * sits at 4 GB behind a 32-bit OVL master), but that is a different config. If
 * a future config regresses, we give up cleanly and fall back to serial-only
 * status rather than paint garbage. */
static int fb_via_drm(struct fbinfo *f)
{
	struct drm_mode_card_res res;
	struct drm_mode_get_connector conn;
	struct drm_mode_modeinfo modes[8];
	struct drm_mode_create_dumb dumb;
	struct drm_mode_fb_cmd2 fb;
	struct drm_mode_map_dumb mreq;
	struct drm_mode_crtc set;
	uint32_t conns[8], crtcs[8], encs[8], fbs[8];
	uint32_t conn_id = 0, crtc_id = 0;
	struct drm_mode_modeinfo *m = NULL;
	int fd, i;

	if (open_panel_gate() != 0)
		return -1;

	fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { say("fb: no /dev/dri/card0"); return -1; }

	/* SET_MASTER fails harmlessly when we already own it (best effort). */
	(void)ioctl(fd, DRM_IOCTL_SET_MASTER, 0);

	/* Two-pass GETRESOURCES: first counts, then the id arrays. */
	memset(&res, 0, sizeof res);
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) { close(fd); return -1; }
	if (res.count_connectors > 8) res.count_connectors = 8;
	if (res.count_crtcs > 8)      res.count_crtcs = 8;
	if (res.count_encoders > 8)   res.count_encoders = 8;
	if (res.count_fbs > 8)        res.count_fbs = 8;
	res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
	res.crtc_id_ptr      = (uint64_t)(uintptr_t)crtcs;
	res.encoder_id_ptr   = (uint64_t)(uintptr_t)encs;
	res.fb_id_ptr        = (uint64_t)(uintptr_t)fbs;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) { close(fd); return -1; }
	if (!res.count_connectors || !res.count_crtcs) {
		say("fb: no DRM connector/crtc"); close(fd); return -1;
	}
	crtc_id = crtcs[0];

	/* Find a connected connector and take its first mode. */
	for (i = 0; i < (int)res.count_connectors; i++) {
		memset(&conn, 0, sizeof conn);
		conn.connector_id = conns[i];
		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) continue;
		if (conn.count_modes > 8) conn.count_modes = 8;
		conn.modes_ptr = (uint64_t)(uintptr_t)modes;
		conn.props_ptr = 0; conn.prop_values_ptr = 0; conn.encoders_ptr = 0;
		conn.count_props = 0; conn.count_encoders = 0;
		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) continue;
		if (conn.connection == 1 /* DRM_MODE_CONNECTED */ && conn.count_modes) {
			conn_id = conns[i];
			m = &modes[0];
			break;
		}
	}
	if (!m) { say("fb: no connected DRM connector"); close(fd); return -1; }

	memset(&dumb, 0, sizeof dumb);
	dumb.width = m->hdisplay;
	dumb.height = m->vdisplay;
	dumb.bpp = 32;
	if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb) < 0) {
		say("fb: CREATE_DUMB 32bpp failed -- no display");
		close(fd); return -1;
	}

	memset(&fb, 0, sizeof fb);
	fb.width = m->hdisplay;
	fb.height = m->vdisplay;
	fb.pixel_format = DRM_FORMAT_XRGB8888;
	fb.handles[0] = dumb.handle;
	fb.pitches[0] = dumb.pitch;
	if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) { say("fb: ADDFB2 failed"); close(fd); return -1; }

	memset(&mreq, 0, sizeof mreq);
	mreq.handle = dumb.handle;
	if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) { say("fb: MAP_DUMB failed"); close(fd); return -1; }
	void *mem = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
	if (mem == MAP_FAILED) { say("fb: dumb buffer mmap failed"); close(fd); return -1; }

	/* First atomic commit: the scanout switches to our buffer and the panel
	 * lights (it was held dark until this point). */
	memset(&set, 0, sizeof set);
	set.crtc_id = crtc_id;
	set.fb_id = fb.fb_id;
	set.set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id;
	set.count_connectors = 1;
	set.mode = *m;
	set.mode_valid = 1;
	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &set) < 0) {
		say("fb: SETCRTC failed -- panel stays dark");
		munmap(mem, dumb.size); close(fd); return -1;
	}

	f->mem = mem;
	f->len = dumb.size;
	f->w = m->hdisplay;
	f->h = m->vdisplay;
	f->stride = dumb.pitch;
	f->bpp = 32;
	f->fd = fd;               /* owned for our lifetime; init never exits */
	f->how = "DRM dumb-buffer";
	if (fb_alloc_shadow(f)) { munmap(mem, dumb.size); close(fd); return -1; }

	/* The frontlight comes up at 0, so a committed frame is invisible until
	 * the white channel is raised. */
	(void)wr("/sys/class/backlight/lcd-backlight/brightness", "10\n");
	return 0;
}

/* Paint the installer status screen: banner + up to 8 status lines + tick. */
static void paint(struct fbinfo *f, const char *status, unsigned long tick)
{
	char buf[24], line[64];

	fillrect(f, 0, 0, f->w, f->h, 0xff000000);
	fillrect(f, 0, 0, f->w, 8, 0xffffffff);          /* top rule */
	text(f, 40, 60,  8, 0xffffffff, "DC-1");
	text(f, 40, 140, 8, 0xffffffff, "INSTALLER");

	unsigned y = 300;
	const char *p = status;
	int lines = 0;
	while (*p && lines < 8) {
		size_t n = 0;
		while (p[n] && p[n] != '\n' && n < 44) n++;
		memcpy(line, p, n);
		line[n] = 0;
		text(f, 40, y, 4, 0xff00ff00, line);
		y += 60;
		p += n;
		while (*p == '\n') p++;
		lines++;
	}

	memcpy(line, "TICK ", 5);
	u2s(tick, buf);
	memcpy(line + 5, buf, slen(buf) + 1);
	text(f, 40, f->h - 100, 3, 0xff808080, line);
}

/* ------------------------------- USB gadget ----------------------------- */

static int wr(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_TRUNC);
	if (fd < 0) return -1;
	int r = (int)write(fd, val, slen(val));
	close(fd);
	return r < 0 ? -1 : 0;
}

/* Bring up a composite gadget via configfs: two CDC-ACM serial functions
 * (ttyGS0 = one-way kmsg stream, ttyGS1 = interactive shell) plus CDC-ECM
 * ethernet (usb0, the installer transfer channel). ECM rather than RNDIS:
 * the host side is Linux (cdc_ether) and RNDIS is deprecated. Fixed MACs so
 * the host does not see a new interface every boot -- the host installer
 * finds the link by the host-side MAC 02:1a:11:00:00:01.
 *
 * The gadget functions may be modules (libcomposite, u_serial, usb_f_acm,
 * u_ether, usb_f_ecm); rc.sh insmods anything staged in /lib/modules before
 * retrying the UDC bind, so a failure here is not final. Fails silently. */
static void gadget(void)
{
	const char *G = "/sys/kernel/config/usb_gadget/g1";
	char p[256];

	if (mkdir("/sys/kernel/config/usb_gadget/g1", 0755) && errno != EEXIST) {
		say("gadget: no configfs usb_gadget (USB_CONFIGFS=m, module not loaded?)");
		return;
	}
#define P(sub) (memcpy(p, G, slen(G)), memcpy(p + slen(G), sub, slen(sub) + 1), p)
	wr(P("/idVendor"),  "0x18d1\n");
	wr(P("/idProduct"), "0x4ee7\n");
	mkdir(P("/strings/0x409"), 0755);
	wr(P("/strings/0x409/manufacturer"), "daylight\n");
	wr(P("/strings/0x409/product"),      "dc1-installer\n");
	wr(P("/strings/0x409/serialnumber"), "dc1-installer\n");
	mkdir(P("/configs/c.1"), 0755);
	mkdir(P("/configs/c.1/strings/0x409"), 0755);
	wr(P("/configs/c.1/strings/0x409/configuration"), "acm+ecm\n");
	mkdir(P("/functions/acm.0"), 0755);
	mkdir(P("/functions/acm.1"), 0755);
	mkdir(P("/functions/ecm.0"), 0755);
	wr(P("/functions/ecm.0/dev_addr"),  "02:1a:11:00:00:02\n");
	wr(P("/functions/ecm.0/host_addr"), "02:1a:11:00:00:01\n");
	symlink(P("/functions/acm.0"),   "/sys/kernel/config/usb_gadget/g1/configs/c.1/acm.0");
	symlink(P("/functions/acm.1"),   "/sys/kernel/config/usb_gadget/g1/configs/c.1/acm.1");
	symlink(P("/functions/ecm.0"),   "/sys/kernel/config/usb_gadget/g1/configs/c.1/ecm.0");

	/* bind to whatever UDC the MTU3 driver registered */
	int d = open("/sys/class/udc", O_RDONLY | O_DIRECTORY);
	if (d < 0) { say("gadget: no /sys/class/udc -- MTU3 did not register a UDC"); return; }
	close(d);
	static const char *cand[] = { "musb-hdrc.1.auto", "musb-hdrc.0.auto",
				      "11201000.usb", "11200000.usb", NULL };
	for (int i = 0; cand[i]; i++) {
		if (wr(P("/UDC"), cand[i]) == 0) { say2("gadget: bound UDC ", cand[i]); return; }
	}
	say("gadget: UDC bind failed (rc.sh retries with the real /sys/class/udc name)");
#undef P
}

/* ---------------------------------- main -------------------------------- */

int main(void)
{
	char status[512];
	pid_t rc_pid = -1;

	/* Refuse to run anywhere except as PID 1: every mount() below is
	 * unconditional and the loop never exits. */
	if (getpid() != 1 && !getenv("DC1_FORCE")) {
		static const char m[] =
			"dc1-installer-init: refusing to run: not PID 1.\n"
			"This mounts devtmpfs/proc/sys over the running system and never exits.\n"
			"Set DC1_FORCE=1 only if you really mean it.\n";
		(void)write(2, m, sizeof(m) - 1);
		return 1;
	}

	say("init: entered userspace (installation mode)");

	mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755);
	mkdir("/tmp", 0755);
	mount("proc",  "/proc", "proc",  0, NULL);
	mount("sysfs", "/sys",  "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
	mkdir("/sys/kernel/config", 0755);
	mount("configfs", "/sys/kernel/config", "configfs", 0, NULL);

	g_kmsg = open("/dev/kmsg", O_WRONLY);
	say("init: proc/sys/dev/configfs mounted");

	/* Grab a controlling tty so kernel messages and our writes coexist. */
	int t = open("/dev/tty1", O_RDWR);
	if (t >= 0) { dup2(t, 0); dup2(t, 1); dup2(t, 2); if (t > 2) close(t); }

	gadget();

	/* Initial status; rc.sh and installd overwrite it as they progress. */
	{
		int fd = open(STATUS_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) {
			static const char s[] = "STARTING\n";
			(void)write(fd, s, sizeof(s) - 1);
			close(fd);
		}
	}

	/* Second stage in the background so a broken script cannot cost us the
	 * screen. It does: busybox --install, module insmod, UDC retry, usb0
	 * addressing, shells, and the installer daemon. Its first job is to pet
	 * /dev/watchdog -- see the display-gate note below. */
	if (access("/etc/rc.sh", X_OK) == 0 && access("/bin/busybox", X_OK) == 0) {
		rc_pid = fork();
		if (rc_pid == 0) {
			char *av[] = { (char *)"/bin/busybox", (char *)"sh",
				       (char *)"/etc/rc.sh", NULL };
			execv("/bin/busybox", av);
			_exit(127);
		}
		if (rc_pid < 0)
			say("init: rc.sh fork FAILED");
	} else {
		say("init: /etc/rc.sh or /bin/busybox missing -- no installer daemon");
	}

	/* Acquire the display only once rc.sh is up: LK arms a ~31s hardware
	 * watchdog and this kernel does not auto-pet it, so the display gate --
	 * which can spend up to ~35s on its GCE + DSI + card0 waits in a
	 * pathological case -- must not run while the watchdog is unpetted. The
	 * panel is dark until this returns anyway, so nothing is lost by waiting. */
	struct fbinfo f;
	memset(&f, 0, sizeof f);
	int have_fb = (fb_via_drm(&f) == 0);
	if (have_fb)
		say2("fb: acquired via ", f.how);
	else
		say("fb: no display -- status only on serial/kmsg");

	/* Never exit: repaint the status screen, reap children, heartbeat. */
	for (unsigned long n = 0;; n++) {
		status[0] = 0;
		int fd = open(STATUS_FILE, O_RDONLY);
		if (fd >= 0) {
			ssize_t got = read(fd, status, sizeof(status) - 1);
			if (got > 0) status[got] = 0;
			close(fd);
		}
		if (!status[0])
			memcpy(status, "WAITING FOR HOST\n", 18);

		/* While the touch UI (dc1-ask, run by tui.sh) owns the panel
		 * it creates /tmp/ui-active; painting over it would fight the
		 * keyboard screen. The status screen resumes the moment the
		 * flag is gone. */
		if (have_fb && access("/tmp/ui-active", F_OK) != 0) {
			paint(&f, status, n);
			blit(&f);
		}
		if ((n % 15) == 0) {
			char hb[64], num[21];
			memcpy(hb, "[dc1-installer] tick=", 21);
			char *nn = u2s(n, num);
			size_t l = slen(nn);
			memcpy(hb + 21, nn, l);
			hb[21 + l] = '\n';
			if (g_kmsg >= 0) (void)write(g_kmsg, hb, 22 + l);
		}
		while (waitpid(-1, NULL, WNOHANG) > 0) { }
		sleep(1);
	}
	return 0;   /* unreachable */
}
