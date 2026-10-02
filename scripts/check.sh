#!/bin/sh
# Shared local/CI verification. Never installs packages or deploys artifacts.
set -eu

usage() {
	cat <<'EOF'
usage: sh scripts/check.sh [--check-deps] [GROUP ...]

Run selected groups, or all groups when none are supplied:
  syntax     Parse repository shell scripts and APKBUILDs
  packaging  Verify package inputs, source pins, and export/release helpers
  installer  Run unprivileged installer and device-helper regression tests
  c          Compile installer init programs and device C helpers
  go         Build, vet, and test both Go modules; compile installer for arm64
  dtbswap    Build the freestanding arm64 stub in a temporary directory

--check-deps  Check required executables without running any tests
--help        Show this help

Missing tools fail the selected checks; no packages are installed. The Go
group may download module dependencies or its declared toolchain on first use.
Set GOPROXY=off GOTOOLCHAIN=local to require an already prepared Go cache.
DTBSWAP_LLVM and DTBSWAP_LLD select the stub toolchain, as in installer/build.sh
(defaults: /usr/lib/llvm20/bin/ and ld.lld).
EOF
}

deps_only=no
case "${1:-}" in
	--help|-h) usage; exit 0 ;;
	--check-deps) deps_only=yes; shift ;;
esac
[ "$#" -gt 0 ] || set -- syntax packaging installer c go dtbswap
for group do
	case "$group" in
		syntax|packaging|installer|c|go|dtbswap) ;;
		*) printf 'unknown check group: %s\n' "$group" >&2; usage >&2; exit 2 ;;
	esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"
# Non-root Ubuntu PATHs can omit the e2fsprogs executables.
PATH="$PATH:/usr/sbin:/sbin"
export PATH
export PYTHONDONTWRITEBYTECODE=1
stub_llvm=${DTBSWAP_LLVM:-/usr/lib/llvm20/bin/}
stub_lld=${DTBSWAP_LLD:-ld.lld}

missing=no
require() {
	for tool do
		if ! command -v "$tool" >/dev/null 2>&1; then
			printf '%s: missing required executable: %s\n' "$group" "$tool" >&2
			missing=yes
		fi
	done
}

# Preflight every requested group before spending time on any of them. In
# particular, installer tests must not silently skip their compiler/ext4 cases.
for group do
	case "$group" in
		syntax) require sh ;;
		packaging)
			require sh python3 gjs git openssl zstd tar gzip sha256sum sha512sum \
				mkfs.ext4 e2fsck dumpe2fs debugfs
			;;
		installer) require sh python3 gcc "${CC:-cc}" openssl mkfs.ext4 blkid ;;
		c) require gcc ;;
		go) require go ;;
		dtbswap) require make "${stub_llvm}clang" "${stub_llvm}llvm-objcopy" "$stub_lld" ;;
	esac
done
if [ "$missing" = yes ]; then
	printf 'Install the missing tools, then rerun this command. See CONTRIBUTING.md (Local setup).\n' >&2
	exit 1
fi
if [ "$deps_only" = yes ]; then
	printf 'Required executables available for: %s\n' "$*"
	exit 0
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/dc1-check.XXXXXX")
trap 'rm -rf -- "$scratch"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for group do
	printf '\nChecking %s\n' "$group"
	case "$group" in
		syntax)
			# `sh -n file1 file2` only parses file1; check each file separately.
			for source in scripts/*.sh scripts/tests/*.sh boot/*.sh \
				boot/dtbswap/*.sh installer/*.sh installer/src/*.sh \
				installer/src/*.script installer/src/system/*.sh \
				installer/host/*.sh installer/tests/*.sh \
				pmaports/device/testing/*/APKBUILD; do
				sh -n "$source"
			done
			;;
		packaging) sh scripts/verify.sh ;;
		installer) sh installer/tests/run-tests.sh ;;
		c)
			# Match installer/build.sh's static builds and vendored DRM UAPI.
			for source in installer/src/init.c installer/src/system/init.c; do
				gcc -static -Os -Wall -Wextra -D__user= -I installer/src/uapi \
					-o "$scratch/init" "$source"
				printf 'compiled %s\n' "$source"
			done
			device=pmaports/device/testing/device-daylight-jagar
			for tool in dc1-reboot-fastboot dc1-slotctl; do
				gcc -Wall -Wextra -Os -o "$scratch/$tool" \
					"$device/$tool.c" "$device/dc1-misc.c"
				printf 'compiled %s + dc1-misc.c\n' "$tool"
			done
			for tool in dc1-pwrkey dc1-mn29-probe; do
				gcc -Wall -Wextra -Os -o "$scratch/$tool" "$device/$tool.c"
				printf 'compiled %s\n' "$tool"
			done
			;;
		go)
			mkdir -p "$scratch/go"
			(
				cd boot/mkboot
				go build -o "$scratch/go/" ./...
				go vet ./...
				go test ./...
			)
			(
				cd installer/gotools
				export CGO_ENABLED=0
				go build -o "$scratch/go/" ./...
				go vet ./...
				go test ./...
				GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' \
					-o "$scratch/go/dc1tools-arm64" .
			)
			;;
		dtbswap)
			mkdir -p "$scratch/dtbswap"
			for source in Makefile head.S main.c dtbswap.lds; do
				cp "boot/dtbswap/$source" "$scratch/dtbswap/"
			done
			make -C "$scratch/dtbswap" LLVM="$stub_llvm" LLD="$stub_lld"
			;;
	esac
done
printf '\nChecks passed: %s\n' "$*"
