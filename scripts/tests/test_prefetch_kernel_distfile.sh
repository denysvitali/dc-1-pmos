#!/bin/sh
# Offline coverage for the kernel distfile prefetch: a valid cached file is
# left alone, a matching download is accepted, and a bad payload is retried
# rather than turned into "Use 'abuild checksum'".
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script="$here/../prefetch-kernel-distfile.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "prefetch-kernel-distfile test failed: $*" >&2; exit 1; }

payload="$tmp/payload.tar.gz"
printf 'kernel-archive\n' >"$payload"
hash=$(sha512sum "$payload" | awk '{ print $1 }')
name='linux-postmarketos-mediatek-mt6789-0123456789abcdef0123456789abcdef01234567.tar.gz'

apkbuild="$tmp/APKBUILD"
cat >"$apkbuild" <<EOF
pkgname=linux-postmarketos-mediatek-mt6789
_repository="dc-1-linux-kernel"
_commit="0123456789abcdef0123456789abcdef01234567"
source="
	\$pkgname-\$_commit.tar.gz::file://$payload
"
sha512sums="
$hash  $name
"
EOF

dest="$tmp/distfiles"
mkdir -p "$dest"

# Positive control: download via file:// and keep the verified name.
DC1_KERNEL_APKBUILD="$apkbuild" DC1_PREFETCH_RETRIES=2 \
	sh "$script" "$dest" >"$tmp/log" 2>&1 || {
	cat "$tmp/log" >&2
	fail "refused a matching file:// archive"
}
[ -f "$dest/$name" ] || fail "did not write $name"
echo "$hash  $dest/$name" | sha512sum -c >/dev/null || fail "wrote a bad hash"

# A valid cached file must not be re-fetched. A curl that always fails would
# still succeed on this path.
DC1_KERNEL_APKBUILD="$apkbuild" DC1_PREFETCH_RETRIES=1 DC1_CURL="$tmp/no-curl" \
	sh "$script" "$dest" >"$tmp/log2" 2>&1 || {
	cat "$tmp/log2" >&2
	fail "re-fetched a valid cached distfile"
}
grep -q 'already valid' "$tmp/log2" || fail "did not short-circuit a valid cache"

# A corrupt payload is retried, then accepted once the wrapper returns the
# matching bytes.
fake="$tmp/fake-curl"
cat >"$fake" <<'EOF'
#!/bin/sh
# last non-option argument is the URL; -o FILE is the destination.
out=""
url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		-*) shift ;;
		*) url=$1; shift ;;
	esac
done
state=${TMPDIR:-/tmp}/fake-curl-state
n=0
[ -f "$state" ] && n=$(cat "$state")
n=$((n + 1))
printf '%s\n' "$n" >"$state"
if [ "$n" -lt 2 ]; then
	printf 'corrupt\n' >"$out"
	exit 0
fi
# The URL is file://payload; copy those bytes.
src=${url#file://}
cat "$src" >"$out"
EOF
chmod +x "$fake"
rm -f "$dest/$name"
export TMPDIR="$tmp"
DC1_KERNEL_APKBUILD="$apkbuild" DC1_PREFETCH_RETRIES=3 DC1_PREFETCH_SLEEP=0 DC1_CURL="$fake" \
	sh "$script" "$dest" >"$tmp/log3" 2>&1 || {
	cat "$tmp/log3" >&2
	fail "did not recover from a corrupt first download"
}
echo "$hash  $dest/$name" | sha512sum -c >/dev/null || fail "retry wrote a bad hash"
grep -q 'attempt 2/3' "$tmp/log3" || fail "did not retry after the corrupt payload"

# Exhausted retries must fail closed.
failing="$tmp/always-bad"
cat >"$failing" <<'EOF'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		-*) shift ;;
		*) shift ;;
	esac
done
printf 'nope\n' >"$out"
EOF
chmod +x "$failing"
rm -f "$dest/$name"
DC1_KERNEL_APKBUILD="$apkbuild" DC1_PREFETCH_RETRIES=2 DC1_PREFETCH_SLEEP=0 DC1_CURL="$failing" \
	sh "$script" "$dest" >"$tmp/log4" 2>&1 && fail "accepted a consistently bad payload"
[ ! -f "$dest/$name" ] || fail "left a bad distfile behind"
grep -q 'failed sha512 after 2 attempts' "$tmp/log4" || fail "did not report exhausted retries"

echo "prefetch-kernel-distfile tests passed"
