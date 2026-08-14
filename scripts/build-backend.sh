#!/bin/sh
# build-backend.sh -- compile the DC-1 control plane (ui/backend) into the
# single static binary the dc1-ui package ships.
#
#   sh scripts/build-backend.sh OUTPUT_FILE
#
# CGO_ENABLED=0 is the whole point: the binary runs on the device's musl
# rootfs, and a cgo build here would link against the build host's libc. The
# result is asserted to be a statically linked aarch64 ELF rather than
# assumed to be one -- a dynamically linked binary installs cleanly and then
# fails to exec on the device, with no log line to say why.
set -eu

usage() {
	echo "usage: $0 OUTPUT_FILE" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
	""|/|/dev|/dev/*) echo "refusing unsafe output file: $1" >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
module_dir=$(CDPATH= cd -- "$script_dir/../ui/backend" && pwd)

fatal() {
	echo "build-backend: $*" >&2
	exit 1
}

[ -f "$module_dir/go.mod" ] || fatal "no Go module at $module_dir"
command -v go >/dev/null || fatal "go is not on PATH"

output_dir=$(dirname -- "$1")
mkdir -p -- "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
output="$output_dir/$(basename -- "$1")"

# -trimpath keeps the build host's directory layout out of a published
# binary; -s -w drop the symbol and DWARF tables (~2 MB on a rootfs that is
# published as a compressed image and written to the device byte for byte).
(
	cd "$module_dir"
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build -trimpath -ldflags "-s -w" -o "$output" ./cmd/dc1-backend
) || fatal "go build failed"

[ -s "$output" ] || fatal "go build produced nothing at $output"

# ELF magic, then e_machine == EM_AARCH64 (0xB7, little endian), then the
# absence of a PT_INTERP program header -- the three properties that decide
# whether this file can run on the device at all.
elf_magic=$(od -An -tx1 -N4 "$output" | tr -d ' \n')
[ "$elf_magic" = 7f454c46 ] || fatal "$output is not an ELF binary"
elf_machine=$(od -An -tx1 -j18 -N2 "$output" | tr -d ' \n')
[ "$elf_machine" = b700 ] || fatal "$output is not aarch64 (e_machine=$elf_machine)"
if command -v readelf >/dev/null; then
	! readelf -l "$output" 2>/dev/null | grep -q INTERP ||
		fatal "$output is dynamically linked; CGO_ENABLED=0 did not take"
else
	echo "build-backend: warning: readelf absent, INTERP check skipped" >&2
fi

chmod 755 "$output"
echo "built $output ($(wc -c < "$output" | tr -d ' ') bytes, static aarch64)"
