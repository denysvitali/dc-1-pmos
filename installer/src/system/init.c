/*
 * dc1-system-init -- PID 1 of the DC-1 SYSTEM boot initramfs (the one inside
 * jagar-boot.img, i.e. what boots the installed postmarketOS).
 *
 * Job, in order, all fail-closed:
 *   1. mount proc / sysfs / devtmpfs (devtmpfs is NOT auto-mounted on an
 *      initramfs boot; see the comments in ../init.c)
 *   2. fork a watchdog petter that keeps /dev/watchdog open and petted
 *      ACROSS the switch_root, forever. LK arms the SoC watchdog and the
 *      kernel is built with CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=n, so the
 *      board resets if nobody pets. The petter deliberately survives the
 *      handoff (it only needs its already-open fd) and is the SOLE owner:
 *      /dev/watchdog is single-open, so handing over to an in-rootfs
 *      watchdog daemon would need a close-and-reopen gap -- and whether this
 *      driver honours magic-close (vs nowayout) has never been measured, so
 *      closing is not known to be safe. Cost of this choice: a userspace-only
 *      hang does not auto-reset (a kernel hang still does, because the petter
 *      dies with it).
 *   3. run /etc/boot.sh (busybox sh, FOREGROUND): resolve userdata by GPT
 *      PARTNAME, require ext4 labelled jagar-root, optional fsck, mount at
 *      /mnt/root, leave the device name in /tmp/rootdev.
 *   4. verify, move /dev /proc /sys into the new root, and exec busybox
 *      switch_root /mnt/root /sbin/init. switch_root only works from PID 1,
 *      which is why the pivot lives here and not in boot.sh (a background
 *      exec would replace only the script -- a bug the bring-up initramfs
 *      actually hit).
 *
 * ANY failure drops to a rescue shell on the consoles instead of writing
 * anything. The petter keeps running in rescue so the operator has more than
 * one watchdog period to type.
 */

#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <stdlib.h>

static int g_kmsg = -1;

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

static int wr(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_TRUNC);
	if (fd < 0) return -1;
	int r = (int)write(fd, val, slen(val));
	close(fd);
	return r < 0 ? -1 : 0;
}

/* Broadcast one line to every text channel we might have. */
static void say(const char *msg)
{
	static const char *tty[] = { "/dev/tty0", "/dev/tty1", "/dev/console",
				     "/dev/ttyS0", NULL };
	char line[512];
	size_t n = slen(msg);
	if (n > sizeof(line) - 16) n = sizeof(line) - 16;

	memcpy(line, "[dc1-boot] ", 11);
	memcpy(line + 11, msg, n);
	line[11 + n] = '\n';
	size_t len = 11 + n + 1;

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

/* Fork the sole watchdog owner. It holds the fd open forever -- including
 * across switch_root, where its root points at the (deleted) initramfs but
 * the open fd keeps working. Pet interval 10s against LK's ~31s timer. */
static void start_watchdog_petter(void)
{
	pid_t pid = fork();
	if (pid != 0) {
		if (pid < 0)
			say("watchdog: fork FAILED -- board may reset in ~31s");
		return;
	}
	int fd = -1;
	for (int i = 0; i < 10 && fd < 0; i++) {
		fd = open("/dev/watchdog", O_WRONLY);
		if (fd < 0) sleep(1);
	}
	if (fd < 0) {
		say("watchdog: no /dev/watchdog -- if LK armed its timer, the board resets");
		_exit(0);
	}
	say("watchdog: petter running (sole owner, survives switch_root)");
	for (;;) {
		(void)write(fd, "a", 1);
		sleep(10);
	}
}

/* Run "/bin/busybox sh <script>" in the foreground; returns its exit code
 * or -1. */
static int run_script(const char *script)
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		char *av[] = { (char *)"/bin/busybox", (char *)"sh",
			       (char *)script, NULL };
		execv("/bin/busybox", av);
		_exit(127);
	}
	int st = 0;
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
		;
	if (WIFEXITED(st))
		return WEXITSTATUS(st);
	return -1;
}

/* Bring up a CDC-ACM composite gadget over configfs so the SYSTEM initramfs
 * has a debug channel BEFORE the rootfs/OpenRC runs. This is the only way to
 * read the boot log when boot.sh or switch_root hangs: without it the hang is
 * invisible (the rescue shell below writes only to tty1/ttyS0, which are not
 * reachable over USB). Mirrors the installer initramfs gadget() minus ECM --
 * a serial stream + a shell are all a diagnosable boot needs. The MUSB UDC
 * name candidates match the installer. Fails silently. */
static void gadget(void)
{
	const char *G = "/sys/kernel/config/usb_gadget/g1";
	char p[256];

	if (mkdir("/sys/kernel/config/usb_gadget/g1", 0755) && errno != EEXIST) {
		say("gadget: no configfs usb_gadget");
		return;
	}
#define P(sub) (memcpy(p, G, slen(G)), memcpy(p + slen(G), sub, slen(sub) + 1), p)
	wr(P("/idVendor"),  "0x18d1\n");
	wr(P("/idProduct"), "0x4ee7\n");
	mkdir(P("/strings/0x409"), 0755);
	wr(P("/strings/0x409/manufacturer"), "daylight\n");
	wr(P("/strings/0x409/product"),      "dc1-system\n");
	wr(P("/strings/0x409/serialnumber"), "dc1-system\n");
	mkdir(P("/configs/c.1"), 0755);
	mkdir(P("/configs/c.1/strings/0x409"), 0755);
	wr(P("/configs/c.1/strings/0x409/configuration"), "acm\n");
	mkdir(P("/functions/acm.0"), 0755);
	mkdir(P("/functions/acm.1"), 0755);
	symlink(P("/functions/acm.0"), "/sys/kernel/config/usb_gadget/g1/configs/c.1/acm.0");
	symlink(P("/functions/acm.1"), "/sys/kernel/config/usb_gadget/g1/configs/c.1/acm.1");

	static const char *cand[] = { "musb-hdrc.1.auto", "musb-hdrc.0.auto",
				      "11201000.usb", "11200000.usb", NULL };
	for (int i = 0; cand[i]; i++) {
		if (wr(P("/UDC"), cand[i]) == 0) { say2("gadget: bound UDC ", cand[i]); return; }
	}
	say("gadget: UDC bind failed");
#undef P
}

/* Fork a one-way kmsg stream on ttyGS0 and an interactive root shell on
 * ttyGS1, best-effort. These make the boot diagnosable from the host
 * (/dev/ttyACM0 and /dev/ttyACM1) regardless of what boot.sh/switch_root do. */
static void start_debug_channels(void)
{
	pid_t p;

	p = fork();
	if (p == 0) {
		int out = -1, k;
		for (int i = 0; i < 10 && out < 0; i++) {
			out = open("/dev/ttyGS0", O_WRONLY | O_NOCTTY);
			if (out < 0) sleep(1);
		}
		if (out < 0) _exit(0);
		k = open("/dev/kmsg", O_RDONLY);
		if (k < 0) _exit(0);
		/* Blocking read streams one log entry at a time, following the
		 * kernel ring from boot. */
		char buf[4096];
		for (;;) {
			ssize_t n = read(k, buf, sizeof buf);
			if (n > 0) (void)write(out, buf, n);
		}
	}

	p = fork();
	if (p == 0) {
		for (int i = 0; i < 10; i++) {
			int fd = open("/dev/ttyGS1", O_RDWR | O_NOCTTY);
			if (fd >= 0) {
				setsid();
				dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
				if (fd > 2) close(fd);
				char *av[] = { (char *)"/bin/busybox", (char *)"sh", NULL };
				execv("/bin/busybox", av);
				_exit(127);
			}
			sleep(1);
		}
		_exit(0);
	}
}

/* Rescue: a respawning shell on each plausible console. Never returns. */
static void rescue(const char *why)
{
	static const char *tty[] = { "/dev/tty1", "/dev/ttyS0", "/dev/console" };
	pid_t kid[3] = { 0, 0, 0 };

	say2("RESCUE SHELL: ", why);
	say("nothing was written; fix the problem or reflash from fastboot");
	for (;;) {
		for (int i = 0; i < 3; i++) {
			if (kid[i] > 0 && waitpid(kid[i], NULL, WNOHANG) == 0)
				continue;   /* still running */
			int fd = open(tty[i], O_RDWR | O_NOCTTY);
			if (fd < 0) { kid[i] = 0; continue; }
			pid_t pid = fork();
			if (pid == 0) {
				setsid();
				dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
				if (fd > 2) close(fd);
				char *av[] = { (char *)"/bin/busybox",
					       (char *)"sh", NULL };
				execv("/bin/busybox", av);
				_exit(127);
			}
			close(fd);
			kid[i] = pid > 0 ? pid : 0;
		}
		/* reap strays */
		while (waitpid(-1, NULL, WNOHANG) > 0) { }
		sleep(2);
	}
}

int main(void)
{
	if (getpid() != 1 && !getenv("DC1_FORCE")) {
		static const char m[] =
			"dc1-system-init: refusing to run: not PID 1.\n";
		(void)write(2, m, sizeof(m) - 1);
		return 1;
	}

	say("init: system initramfs starting");

	mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755);
	mkdir("/tmp", 0755); mkdir("/mnt", 0755); mkdir("/mnt/root", 0755);
	mount("proc",  "/proc", "proc",  0, NULL);
	mount("sysfs", "/sys",  "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");

	g_kmsg = open("/dev/kmsg", O_WRONLY);
	say("init: proc/sys/dev mounted");

	/* USB debug channel: configfs + ACM gadget + log/shell, BEFORE boot.sh,
	 * so a hang there is observable from the host (/dev/ttyACM0 log,
	 * /dev/ttyACM1 shell). This is what makes a boot failure diagnosable. */
	mkdir("/sys/kernel/config", 0755);
	mount("configfs", "/sys/kernel/config", "configfs", 0, NULL);
	gadget();
	start_debug_channels();

	start_watchdog_petter();

	if (access("/bin/busybox", X_OK) != 0)
		rescue("/bin/busybox missing from initramfs");
	if (access("/etc/boot.sh", R_OK) != 0)
		rescue("/etc/boot.sh missing from initramfs");

	int rc = run_script("/etc/boot.sh");
	if (rc != 0)
		rescue("boot.sh failed (root not found/verified)");

	/* boot.sh proved the rootfs and left its device name behind. */
	char dev[64];
	ssize_t got = -1;
	int fd = open("/tmp/rootdev", O_RDONLY);
	if (fd >= 0) {
		got = read(fd, dev, sizeof(dev) - 1);
		close(fd);
	}
	if (got <= 0)
		rescue("boot.sh left no /tmp/rootdev");
	while (got > 0 && (dev[got - 1] == '\n' || dev[got - 1] == ' '))
		got--;
	dev[got] = '\0';

	struct stat old_root, new_root;
	if (stat("/", &old_root) < 0 || stat("/mnt/root", &new_root) < 0 ||
	    old_root.st_dev == new_root.st_dev)
		rescue("/mnt/root is not a separate filesystem");
	if (access("/mnt/root/sbin/init", X_OK) < 0)
		rescue("no executable /sbin/init in the new root");

	say2("init: switching root from verified device ", dev);
	{
		const char *old_mounts[] = { "/dev", "/proc", "/sys" };
		const char *new_mounts[] = {
			"/mnt/root/dev", "/mnt/root/proc", "/mnt/root/sys"
		};
		int moved = 0;
		for (int i = 0; i < 3; i++) {
			if (mount(old_mounts[i], new_mounts[i], NULL,
				  MS_MOVE, NULL) < 0)
				break;
			moved++;
		}
		if (moved == 3) {
			execl("/bin/busybox", "switch_root",
			      "/mnt/root", "/sbin/init", (char *)NULL);
			say("init: switch_root exec FAILED");
		}
		while (moved > 0) {
			moved--;
			(void)mount(new_mounts[moved], old_mounts[moved],
				    NULL, MS_MOVE, NULL);
		}
	}
	rescue("switch_root failed; kernel filesystems rolled back");
	return 0;   /* unreachable */
}
