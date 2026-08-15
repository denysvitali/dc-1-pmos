#!/bin/sh
# finalize.sh DEVICE [ANSWERS] -- mount, grow, provision, unmount.
#
# The non-byte-critical tail of an install, split out so dc1-installd (Go) can
# own the part that must be exact -- receiving the image, writing it, and
# proving the bytes on the device are the bytes that were sent -- while the
# proven provisioning logic stays where it is.
#
# DC1_SKIP_PROVISION=1 installs the image without applying answers and without
# the idempotence marker, so the installed system's Flutter onboarding runs on
# first boot.
set -eu

HERE=$(dirname "$0")
DC1_DEV=${1:?usage: finalize.sh DEVICE [ANSWERS]}
ANSWERS=${2:-}
export DC1_DEV

say() { echo "$*"; }
fail() { echo "finalize: $*" >&2; exit 1; }

. "$HERE/partlib.sh"
. "$HERE/writelib.sh"

# dc1-installd already resolved and wrote the target; wr_finalize only needs
# WR_DEV, which it takes from DC1_DEV via wr_open_target.
wr_open_target
wr_finalize "$ANSWERS"

say "FINALIZED ${WR_RESIZE_NOTE:-}"
