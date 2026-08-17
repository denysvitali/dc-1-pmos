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
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <time.h>

static int g_kmsg = -1;

/* Watchdog handoff to systemd. The mtk_wdt driver is built with nowayout=0
 * (CONFIG_WATCHDOG_NOWAYOUT is not set in jagar_defconfig) and advertises
 * WDIOF_MAGICCLOSE, so writing 'V' and closing stops the watchdog cleanly --
 * systemd's RuntimeWatchdogSec then re-opens it and pings only while healthy.
 * This closes the hole where a live-but-wedged system kept being petted
 * forever: once systemd owns the watchdog, a hung systemd (or a hung critical
 * service with WatchdogSec) stops the ping and the board resets in
 * RuntimeWatchdogSec instead of sitting dark. The handoff is gated on the new
 * root actually running systemd; a non-systemd root keeps the pet-forever
 * petter. */
static pid_t g_petter_pid = -1;
static volatile sig_atomic_t g_petter_handoff = 0;
static void on_watchdog_handoff(int sig) { (void)sig; g_petter_handoff = 1; }

/* Debug-channel handoff to systemd, for the same reason and by the same
 * mechanism as the watchdog handoff above. The channels below survive
 * switch_root, but dc1-debug-shell.service re-provides both of them in the
 * installed system, so keeping ours costs a duplicate owner of ttyGS0/ttyGS1
 * and -- the reason this exists -- a 90s stall on every reboot: the ttyGS1
 * shell has a tty on stdin, so busybox ash treats it as interactive and sets
 * SIGTERM to SIG_IGN. systemd-shutdown broadcasts SIGTERM, cannot reap it, and
 * waits DefaultTimeoutStopSec before escalating to SIGKILL ("Waiting for
 * process: 154 (busybox)"), with the panel still showing the last compositor
 * frame because this device has no fbcon. So exit on SIGUSR1 instead.
 *
 * The shell itself ignores SIGTERM, so the supervisor SIGKILLs it: uncatchable,
 * and there is nothing to clean up. Both actions are async-signal-safe, so the
 * handler does the work directly rather than setting a flag -- these children
 * block in read()/waitpid(), which musl's signal() restarts on return, and a
 * flag checked after a restarted waitpid() would never be looked at again.
 *
 * The supervisor blocks SIGUSR1 across fork() and the g_shell_child store. A
 * signal that lands in that window is delivered at the unblock, by which time
 * the handler can see the pid it has to kill; without the block it would exit
 * and leave behind exactly the process this is meant to remove. */
static pid_t g_kmsg_pid = -1, g_shell_pid = -1;
static volatile sig_atomic_t g_shell_child = 0;
static void on_debug_handoff(int sig)
{
	(void)sig;
	if (g_shell_child > 0)
		kill((pid_t)g_shell_child, SIGKILL);
	_exit(0);
}

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

/* Deadman lease. A watchdog that is petted unconditionally is not a watchdog,
 * it is a keep-alive: it holds a dead board alive instead of resetting it, and
 * -- worse -- it defeats the A/B recovery LK already implements, because a
 * board that never resets is never retried and never falls back to the other
 * slot. A failed boot must therefore stop being petted.
 *
 * Petting is unconditional only while the boot is still making progress. Once
 * we drop to the rescue shell, the petter switches to a lease: it keeps the
 * board alive only while someone demonstrably still has it, and the lease is
 * renewed from outside (`touch /tmp/wd-lease` over the debug shell). Walk away
 * -- or lose the cable -- and the board arms the fastboot boot mode and stops
 * petting, so the watchdog reset lands in LK fastboot (a recoverable state you
 * can re-flash from) instead of rebooting the same slot or sitting dark. */
#define WD_DEADMAN       "/tmp/wd-deadman"
#define WD_LEASE         "/tmp/wd-lease"
#define WD_LEASE_SECONDS 1800   /* ~30 min; petting is manual in rescue */

static void touch_file(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return;
	(void)write(fd, "1\n", 2);
	close(fd);
}

static int lease_is_fresh(void)
{
	struct stat st;
	time_t now;
	if (stat(WD_LEASE, &st) < 0)
		return 0;
	now = time(NULL);
	/* No usable clock: fail towards staying alive rather than resetting a
	 * board someone may be actively debugging. */
	if (now == (time_t)-1 || now < st.st_mtime)
		return 1;
	return (now - st.st_mtime) <= WD_LEASE_SECONDS;
}

/* Set the boot mode nibble LK reads on the way up so the pending watchdog
 * reset lands in fastboot, not the same slot. The hardware reset itself can
 * run no code, so this MUST happen before the petter stops petting. It is the
 * same write the (hardware-verified) dc1-reboot-fastboot tool performs --
 * low nibble of WDT_NONRST_REG2 (0x10007000 + 0x24) == 3 == fastboot -- kept
 * inline because this is a forked child whose exec path is not trustworthy
 * after switch_root. Best-effort: a plain reset is the safe failure mode. */
#define WDT_NONRST2_BASE 0x10007000UL
#define WDT_NONRST2_OFF  0x24
#define BOOT_MODE_FASTBOOT 3

static void arm_fastboot_nibble(void)
{
	volatile unsigned int *p;
	unsigned int old, want;
	int fd = open("/dev/mem", O_RDWR | O_SYNC);

	if (fd < 0) {
		say("watchdog: no /dev/mem -- the reset will be a plain one");
		return;
	}
	p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		 (off_t)WDT_NONRST2_BASE);
	close(fd);
	if (p == MAP_FAILED) {
		say("watchdog: mmap /dev/mem failed -- the reset will be a plain one");
		return;
	}
	old = p[WDT_NONRST2_OFF / 4];
	want = (old & ~0x0fU) | BOOT_MODE_FASTBOOT;
	p[WDT_NONRST2_OFF / 4] = want;
	__sync_synchronize();
	if ((p[WDT_NONRST2_OFF / 4] & 0x0fU) != BOOT_MODE_FASTBOOT)
		say("watchdog: nibble write did not take -- the reset will be a plain one");
	else
		say("watchdog: armed fastboot boot mode; the reset will reach LK fastboot");
	munmap((void *)p, 0x1000);
}

/* Fork the sole watchdog owner. It holds the fd open -- including across
 * switch_root, where its root points at the (deleted) initramfs but the open
 * fd keeps working -- and pets every 10s against LK's ~31s timer. On SIGUSR1
 * (sent by main just before switch_root, only when the new root is systemd)
 * it magic-closes and exits, leaving the watchdog for systemd to re-open. */
static void start_watchdog_petter(void)
{
	pid_t pid = fork();
	if (pid != 0) {
		if (pid < 0)
			say("watchdog: fork FAILED -- board may reset in ~31s");
		else
			g_petter_pid = pid;
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
	signal(SIGUSR1, on_watchdog_handoff);
	say("watchdog: petter running (sole owner, survives switch_root)");
	for (;;) {
		if (g_petter_handoff) {
			say("watchdog: handing off to systemd (magic close)");
			(void)write(fd, "V", 1);
			close(fd);
			_exit(0);
		}
		if (access(WD_DEADMAN, F_OK) == 0 && !lease_is_fresh()) {
			say("watchdog: deadman lease expired -- arming fastboot"
			    " and ceasing to pet; the reset will land in LK fastboot");
			/* Point the reset at fastboot, then stop petting. Do not
			 * exit: exiting is indistinguishable from a crash, and
			 * staying parked keeps the fd owned so nothing else
			 * re-arms it before the reset lands. */
			arm_fastboot_nibble();
			for (;;)
				sleep(3600);
		}
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
		/* Reopen on error, forever. The gadget can be torn down and rebound
		 * underneath us (adding a function re-enumerates the device), which
		 * invalidates the old fd; a one-shot streamer would go silent for
		 * the rest of the boot. */
		char buf[4096];
		signal(SIGUSR1, on_debug_handoff);
		for (;;) {
			int out = open("/dev/ttyGS0", O_WRONLY | O_NOCTTY);
			int k = out >= 0 ? open("/dev/kmsg", O_RDONLY) : -1;
			if (out < 0 || k < 0) {
				if (out >= 0) close(out);
				sleep(1);
				continue;
			}
			for (;;) {
				ssize_t n = read(k, buf, sizeof buf);
				if (n <= 0) break;
				if (write(out, buf, n) < 0)
					break;      /* gadget went away; reopen */
			}
			close(k);
			close(out);
			sleep(1);
		}
	}
	if (p > 0)
		g_kmsg_pid = p;

	p = fork();
	if (p == 0) {
		/* RESPAWN, like the installer's rc.sh does. This shell is the only
		 * interactive way into a failed boot; losing it permanently (as a
		 * one-shot exec does the moment the gadget re-enumerates) strands
		 * the device with no way to drive it. */
		sigset_t usr1, prev;
		sigemptyset(&usr1);
		sigaddset(&usr1, SIGUSR1);
		signal(SIGUSR1, on_debug_handoff);
		for (;;) {
			int fd = open("/dev/ttyGS1", O_RDWR | O_NOCTTY);
			pid_t c;
			if (fd < 0) { sleep(1); continue; }
			sigprocmask(SIG_BLOCK, &usr1, &prev);
			c = fork();
			if (c == 0) {
				sigprocmask(SIG_SETMASK, &prev, NULL);
				setsid();
				dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
				if (fd > 2) close(fd);
				char *av[] = { (char *)"/bin/busybox", (char *)"sh", NULL };
				execv("/bin/busybox", av);
				_exit(127);
			}
			close(fd);
			if (c > 0)
				g_shell_child = (sig_atomic_t)c;
			/* Unblock: a handoff that raced the fork lands here, with
			 * g_shell_child already set for the handler to kill. */
			sigprocmask(SIG_SETMASK, &prev, NULL);
			if (c > 0) {
				while (waitpid(c, NULL, 0) < 0 && errno == EINTR)
					;
				sigprocmask(SIG_BLOCK, &usr1, NULL);
				g_shell_child = 0;
				sigprocmask(SIG_SETMASK, &prev, NULL);
			}
			sleep(1);
		}
	}
	if (p > 0)
		g_shell_pid = p;
}

/* Stop the debug channels, mirroring the watchdog handoff: signal, then reap
 * with a bounded wait so the shells have released ttyGS0/ttyGS1 before the
 * installed system's dc1-debug-shell.service opens them. */
static void stop_debug_channels(void)
{
	pid_t kid[2] = { g_kmsg_pid, g_shell_pid };

	for (int i = 0; i < 2; i++)
		if (kid[i] > 0)
			kill(kid[i], SIGUSR1);
	for (int i = 0; i < 2; i++) {
		if (kid[i] <= 0)
			continue;
		for (int n = 0; n < 50; n++) {
			if (waitpid(kid[i], NULL, WNOHANG) == kid[i])
				break;
			usleep(100000);
		}
	}
}

/* Rescue: a respawning shell on each plausible console. Never returns. */
static void rescue(const char *why)
{
	static const char *tty[] = { "/dev/tty1", "/dev/ttyS0", "/dev/console" };
	pid_t kid[3] = { 0, 0, 0 };

	say2("RESCUE SHELL: ", why);
	say("nothing was written; fix the problem or reflash from fastboot");

	/* Arm the deadman. From here the board stays alive only while someone
	 * renews the lease; otherwise it resets, which is what lets LK retry the
	 * slot and eventually fall back. Seed it once so an operator who is
	 * already attached has WD_LEASE_SECONDS to notice and take over. */
	touch_file(WD_LEASE);
	touch_file(WD_DEADMAN);
	say("watchdog: deadman armed -- renew with: touch " WD_LEASE
	    " (else the board resets)");
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

	/* Hand the watchdog to systemd before switch_root. Gate on the new root
	 * actually running systemd, so a non-systemd root keeps the pet-forever
	 * petter unchanged. The petter magic-closes on SIGUSR1; wait for it to
	 * exit so systemd's immediately-following open does not hit EBUSY. Bounded:
	 * the handler exits in microseconds, 5s is a pathological upper bound. */
	if (access("/mnt/root/usr/lib/systemd/systemd", X_OK) == 0) {
		if (g_petter_pid > 0) {
			say("watchdog: systemd root -- handing the watchdog over");
			kill(g_petter_pid, SIGUSR1);
			for (int i = 0; i < 50; i++) {
				if (waitpid(g_petter_pid, NULL, WNOHANG) == g_petter_pid)
					break;
				usleep(100000);
			}
		}
		/* Same gate, same reason: dc1-debug-shell.service re-provides both
		 * channels, and ours would otherwise stall every reboot for
		 * DefaultTimeoutStopSec. A switch_root that fails after this still
		 * has the rescue shell on tty1/ttyS0, which is already the case --
		 * the UDC unbind below drops ttyGS0/ttyGS1 regardless. */
		say("debug channels: systemd root -- handing ttyGS0/ttyGS1 over");
		stop_debug_channels();
	}

	/* Cleanly unbind the initramfs gadget's UDC before switch_root.
	 *
	 * switch_root deletes the configfs tree (MNT_DETACH) while this gadget is
	 * still bound to the UDC, which leaves the UDC half-bound to a dangling
	 * gadget. The installed system's dc1-usb-gadget.service then rebinds and
	 * configures usb0 successfully on the device side, but the host never sees
	 * a re-enumeration (no new 18d1:4ee7, no D+ re-assert) -- so the device
	 * boots to a working system that is unreachable over USB. Unbinding here,
	 * while the configfs tree still exists, leaves the UDC free for a clean
	 * rebind. The debug serial channels (ttyGS0/ttyGS1) drop for the ~1s
	 * switch_root window; the rescue shell is on tty1/ttyS0 and the deadman
	 * watchdog still covers a failed switch_root, so nothing is stranded. */
	wr("/sys/kernel/config/usb_gadget/g1/UDC", "\n");
	say("gadget: unbound UDC for switch_root");

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
