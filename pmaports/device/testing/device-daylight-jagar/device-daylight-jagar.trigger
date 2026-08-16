#!/bin/sh
# apk trigger: run when the kernel apk drops a new /boot/vmlinuz or
# /usr/share/kernel/<flavor>/kernel.release, i.e. on every kernel upgrade.
# Deploys the matching boot image to the inactive A/B slot and arms it, so the
# next reboot lands on the new kernel. Best-effort by design: a failure here
# (no network, download error) must not break the apk transaction -- the
# boot-time dc1-boot-sync oneshot retries on the next boot.
exec /usr/libexec/dc1-boot-sync --deploy
