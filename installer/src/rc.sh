#!/bin/busybox sh
# Second stage of the DC-1 installer initramfs, run in the BACKGROUND by
# /init. Everything here is best-effort: /init keeps painting the status
# screen regardless of whether any of this works.
#
# Jobs, in order:
#   1. watchdog keepalive -- LK arms a hardware watchdog and the kernel is
#      built with CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=n, so if nobody pets
#      /dev/watchdog the board resets mid-install. Unlike the bring-up
#      initramfs (whose bounded "deadman" was a recovery feature), the
#      installer pets unconditionally for as long as it runs: the way out of
#      installation mode is an explicit reboot at the end of the install.
#   2. USB gadget completion: insmod staged modules, retry the UDC bind with
#      the real name, bring up usb0 at 172.16.42.1/24.
#   3. shells: nc on TCP 4444, interactive sh on ttyGS1/ttyACM0/ttyS0/tty1,
#      one-way kmsg stream on ttyGS0.
#   4. the on-device touch front-end (tui.sh: Wi-Fi + network install; if
#      the touch UI cannot run it exits and only the USB flow remains).
#   5. the USB installer daemon: one connection at a time on TCP 5555,
#      handled by /etc/installer/receive.sh. Always running, so a host can
#      take over regardless of what the touch UI is doing (a writelib lock
#      keeps the two transports from ever writing concurrently).

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
exec 2>&1

log() { echo "[rc] $*" > /dev/kmsg 2>/dev/null; echo "[rc] $*" > /dev/tty0 2>/dev/null; }
status() { echo "$*" > /tmp/installer-status 2>/dev/null; log "status: $*"; }

# MUST be the absolute path: busybox refuses to --install when argv[0] is
# relative, which is what you get when the shell resolves it through PATH.
/bin/busybox --install -s /bin 2>/dev/null || log "busybox --install failed"

log "installer second stage start: $(cat /proc/version)"
mkdir -p /tmp

# ------------------------------------------------------------ 1. watchdog
# Pet forever. If the node never appears, LK's own 31s timer will reset us --
# there is nothing userspace can do about that except say so.
( for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -c /dev/watchdog ] && break; sleep 1
  done
  if [ -c /dev/watchdog ]; then
      log "watchdog: petting /dev/watchdog for the whole install session"
      exec 3>/dev/watchdog
      while :; do
          echo a >&3 2>/dev/null
          sleep 10
      done
  else
      log "watchdog: no /dev/watchdog node -- if LK armed its timer, the board resets in ~31s"
  fi ) &

# ------------------------------------------------------------- 2. USB gadget
# The gadget stack may be modular (libcomposite, u_serial, usb_f_acm, u_ether,
# usb_f_ecm); build.sh stages flat .ko files into /lib/modules when MODDIR is
# given. Order matters: dependencies first.
if [ -d /lib/modules ]; then
    for m in libcomposite.ko u_serial.ko usb_f_acm.ko u_ether.ko usb_f_ecm.ko; do
        [ -f "/lib/modules/$m" ] && { insmod "/lib/modules/$m" 2>/dev/null \
            && log "insmod ok $m" || log "insmod FAIL $m"; }
    done
fi

# /init already tried ACM+ECM over configfs with a guessed UDC name. If that
# failed only because the guess was wrong, fix it here using the real name.
G=/sys/kernel/config/usb_gadget/g1
if [ -d $G ] && [ -z "$(cat $G/UDC 2>/dev/null)" ]; then
    U=$(ls /sys/class/udc 2>/dev/null | head -1)
    if [ -n "$U" ]; then
        echo "$U" > $G/UDC 2>/dev/null && log "gadget bound to real UDC $U"
    fi
fi

# Static addressing on purpose: no DHCP server is assumed on the host side,
# and a fixed address means the host route never changes between boots.
#   device 172.16.42.1/24   host 172.16.42.2/24
( for _ in $(seq 1 30); do [ -e /sys/class/net/usb0 ] && break; sleep 0.5; done
  if [ ! -e /sys/class/net/usb0 ]; then
      log "usbnet: no usb0 (is CONFIG_USB_CONFIGFS_ECM enabled and ecm.0 linked?)"
      status "ERROR: NO USB NETWORK"
  else
      ip link set usb0 up 2>/dev/null
      ip addr show usb0 2>/dev/null | grep -q 'inet ' || \
          ip addr add 172.16.42.1/24 dev usb0 2>/dev/null
      log "usbnet: usb0 up at 172.16.42.1 (host side: 172.16.42.2/24)"
      status "WAITING FOR HOST
USB: 172.16.42.1
RUN DC1-INSTALL.SH ON HOST"
  fi ) &

# ------------------------------------------------------------- 3. channels
# Debug shell over TCP, and SSH. BOTH are bound to the USB address only, never
# 0.0.0.0: a network install brings Wi-Fi up on this same image, and an
# unauthenticated root shell reachable from the user's LAN would be a real
# exposure. Binding is the control, so wait for usb0 to be addressed first.
( for _ in $(seq 1 60); do
      ip addr show usb0 2>/dev/null | grep -q '172\.16\.42\.1' && break
      sleep 1
  done
  if ! ip addr show usb0 2>/dev/null | grep -q '172\.16\.42\.1'; then
      log "usb0 never got 172.16.42.1 -- NOT starting shells (refusing to bind 0.0.0.0)"
      exit 0
  fi

  # One connection at a time; respawned so a dropped connection does not end
  # it. This is the recovery channel, not the installer protocol channel
  # (that one is 5555).
  setsid /bin/busybox sh -c \
      'while : ; do /bin/busybox nc -l -s 172.16.42.1 -p 4444 -e /bin/sh; sleep 1; done' \
      </dev/null >/dev/null 2>&1 &
  log "debug shell listening on 172.16.42.1:4444"

  # SSH: a real PTY, scp for pulling logs off the device, and port forwarding.
  # -R generates a host key on first use (into the tmpfs initramfs, so it is
  # per-boot and never shipped); -B permits the blank-password root login this
  # image deliberately carries (see build.sh).
  if [ -x /usr/sbin/dropbear ]; then
      mkdir -p /dev/pts /etc/dropbear
      mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null
      if /usr/sbin/dropbear -R -B -p 172.16.42.1:22 2>/dev/null; then
          log "sshd listening on 172.16.42.1:22 (ssh root@172.16.42.1, blank password)"
      else
          log "dropbear failed to start"
      fi
  else
      log "dropbear not staged; SSH unavailable"
  fi ) &

# One-way kmsg stream on the first ACM function: the host just opens
# /dev/ttyACM0 and receives the entire kernel log with zero typing.
( for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -c /dev/ttyGS0 ] && break; sleep 1
  done
  if [ -c /dev/ttyGS0 ]; then
      log "streaming /dev/kmsg -> ttyGS0 (read /dev/ttyACM0 on the host)"
      { echo; echo "=== DC-1 INSTALLER: /dev/kmsg full boot log ==="
        cat /proc/version; echo "=== kmsg (replays from boot, then follows) ==="
        cat /dev/kmsg; } > /dev/ttyGS0 2>&1
  else
      log "ttyGS0 never appeared -- USB ACM gadget did not enumerate"
  fi ) &

# Interactive shell on the second ACM function.
( for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -c /dev/ttyGS1 ] && break; sleep 1
  done
  if [ -c /dev/ttyGS1 ]; then
      log "interactive shell on ttyGS1 (host: second /dev/ttyACM*)"
      while : ; do
          setsid sh -c 'exec sh </dev/ttyGS1 >/dev/ttyGS1 2>&1'
          sleep 1
      done
  fi ) &

for t in ttyS0 tty1; do
    [ -c "/dev/$t" ] || continue
    log "spawning shell on /dev/$t"
    setsid sh -c "exec sh </dev/$t >/dev/$t 2>&1" &
done

# ------------------------------------------------- 4. touch UI front-end
# The primary install path: pick Wi-Fi on the panel, download the release,
# feed the shared write core. Backgrounded and optional by design -- if
# dc1-ask cannot acquire the framebuffer or touchscreen, tui.sh exits and
# everything below still works exactly as before.
if [ -x /etc/installer/tui.sh ] && [ -x /bin/dc1-ask ]; then
    log "starting touch installer UI"
    setsid sh /etc/installer/tui.sh </dev/null >/dev/null 2>&1 &
else
    log "touch UI not staged; USB install only"
fi

# ------------------------------------------------------- 5. installer daemon
# One install session at a time. receive.sh talks the DC1-INSTALL-V1 protocol
# on the socket, writes progress to /tmp/installer-status (painted by /init),
# and reboots to the bootloader on success -- so this loop normally never
# comes back around after a successful install.
log "installer daemon listening on TCP 5555"
while : ; do
    /bin/busybox nc -l -p 5555 -e /etc/installer/receive.sh
    sleep 1
done
