#!/bin/sh
# Offline regression for the inline Alpine APK pins and the production
# validation/fetch/verify/extract path. Never source or run the full builder.
# All payloads and tools are synthetic: no root, network, or device access.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$HERE/../build.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail() { echo "test-alpine-apk-pins: FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "  ok: $*"; }

# Exact semantic boundaries, not line numbers or an early-exiting range:
# scan the entire input so missing, repeated, reversed, or truncated blocks
# cannot silently become empty/partial shell snippets. Include START, omit
# END, and require the final nonblank line of the complete block.
extract_block() {
	awk -v start="$2" -v stop="$3" -v tail="$4" '
		$0 == start {
			starts++
			if (state != 0) bad = 1
			state = 1
		}
		$0 == stop {
			stops++
			if (state != 1) bad = 1
			state = 2
			next
		}
		state == 1 {
			print
			if (NF) last = $0
			lines++
		}
		END {
			if (bad || starts != 1 || stops != 1 || state != 2 ||
			    lines < 2 || last != tail) exit 1
		}
	' "$1" >"$5"
}

extract_block "$BUILD" 'fatal() {' 'command -v "$CC" >/dev/null || fatal "no compiler: $CC"' \
	'}' "$TMP/fatal.sh" || fail "cannot extract complete fatal()"
extract_block "$BUILD" 'ALPINE_APKS="' 'set -- $ALPINE_APKS' \
	'"' "$TMP/pins.sh" || fail "cannot extract complete inline pin declarations"
extract_block "$BUILD" 'set -- $ALPINE_APKS' 'verify_blob() {' \
	"' || fatal \"malformed or duplicate Alpine package SHA-256 pin\"" \
	"$TMP/validate.sh" || fail "cannot extract complete pin validation"
extract_block "$BUILD" 'fetch() {   # fetch URL OUT -- cache-aware, fail-closed' \
	'mkdir -p "$DL/firmware" "$DL/apk" "$DL/apkroot"' '}' \
	"$TMP/fetch.sh" || fail "cannot extract complete fetch()"
extract_block "$BUILD" \
	'# Fetch + unpack the pinned Alpine packages into one merged tree. An .apk is' \
	'BUSYBOX=${BUSYBOX:-"$DL/apkroot/bin/busybox.static"}' \
	'rm -rf "$DL/apkroot/.SIGN"* 2>/dev/null || true' \
	"$TMP/packages.sh" || fail "cannot extract complete APK verification/extraction"

# Require both complete loops and their load-bearing operations; parsing the
# assembled harness below also rejects unterminated functions/quotes/loops.
require_line() {
	awk -v line="$2" -v count="$3" '$0 == line { n++ } END { exit n != count }' \
		"$1" || fail "incomplete production block: $2"
}
require_line "$TMP/packages.sh" 'for pkg in $ALPINE_APKS; do' 2
require_line "$TMP/packages.sh" 'done' 2
require_line "$TMP/packages.sh" '	fetch "$ALPINE_MIRROR/$pkg.apk" "$DL/apk/$pkg.apk"' 1
require_line "$TMP/packages.sh" '	got=$(sha256sum "$DL/apk/$pkg.apk" | cut -d'"' '"' -f1)' 1
require_line "$TMP/packages.sh" '	tar -xzf "$DL/apk/$pkg.apk" -C "$DL/apkroot" 2>/dev/null ||' 1

# Guard the guard itself: malformed boundaries must never yield runnable
# snippets merely because awk otherwise exits successfully on empty input.
printf 'begin\nbody\nend\n' >"$TMP/boundaries"
extract_block "$TMP/boundaries" begin end body "$TMP/snippet" || fail "valid boundaries rejected"
for shape in missing-start missing-end duplicate-start duplicate-end reversed truncated; do
	case "$shape" in
		missing-start) printf 'body\nend\n' ;;
		missing-end) printf 'begin\nbody\n' ;;
		duplicate-start) printf 'begin\nbegin\nbody\nend\n' ;;
		duplicate-end) printf 'begin\nbody\nend\nend\n' ;;
		reversed) printf 'end\nbegin\nbody\n' ;;
		truncated) printf 'begin\nend\n' ;;
	esac >"$TMP/boundaries"
	if extract_block "$TMP/boundaries" begin end body "$TMP/snippet"; then
		fail "$shape extraction accepted"
	fi
done
ok "semantic extraction rejects missing, repeated, reversed, and truncated blocks"

# Independently check the real declarations as data before sourcing only this
# restricted pair of literal assignments. Exact names must be unique and have
# a bijection with 32 lowercase, full-length SHA-256 entries.
awk '
	NR == 1 && $0 == "ALPINE_APKS=\"" { state = 1; next }
	state == 1 && $0 == "\"" { state = 2; next }
	state == 2 && $0 == "ALPINE_APK_SHA256S=\"" { state = 3; next }
	state == 3 && $0 == "\"" { state = 4; next }
	state == 4 && NF == 0 { next }
	state == 1 {
		if ($0 !~ /^[a-z0-9][a-z0-9+_.-]*-[0-9][a-zA-Z0-9+_.~]*-r[0-9]+$/ ||
		    names[$0]++) exit 1
		n++; next
	}
	state == 3 {
		if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
		    pins[$2]++ || !($2 in names)) exit 1
		p++; next
	}
	{ exit 1 }
	END {
		if (state != 4 || n != 32 || p != 32) exit 1
		for (name in names) if (!(name in pins)) exit 1
	}
' "$TMP/pins.sh" || fail "real 32-entry pin list is not a unique exact-name/hash bijection"
ok "real 32 package names and well-formed hashes have a one-to-one mapping"

{
	printf '#!/bin/sh\nset -eu\n'
	cat "$TMP/fatal.sh" "$TMP/fetch.sh"
	printf '. "$1"\n'
	cat "$TMP/validate.sh"
	printf '[ "${VALIDATE_ONLY:-0}" = 1 ] && exit 0\n'
	cat "$TMP/packages.sh"
	printf 'echo "APK extraction completed"\n'
} >"$TMP/harness.sh"
sh -n "$TMP/harness.sh" || fail "extracted harness is not complete POSIX shell"
VALIDATE_ONLY=1 sh "$TMP/harness.sh" "$TMP/pins.sh" >"$TMP/real.log" 2>&1 ||
	fail "production validation rejects real pins"
ok "real pins pass extracted production validation"

STUB="$TMP/stub"
PAYLOADS="$TMP/payloads"
mkdir -p "$STUB" "$PAYLOADS"
ALPHA=alpha-1.0-r0
BETA=beta-2.0-r1
printf 'synthetic alpha archive\n' >"$PAYLOADS/$ALPHA.apk"
printf 'synthetic beta archive\n' >"$PAYLOADS/$BETA.apk"
REAL_SHA256SUM=$(command -v sha256sum)
SHA_A=$(sha256sum "$PAYLOADS/$ALPHA.apk" | cut -d' ' -f1)
SHA_B=$(sha256sum "$PAYLOADS/$BETA.apk" | cut -d' ' -f1)
TEST_MIRROR=https://apk.invalid/alpine/edge/main/aarch64
export REAL_SHA256SUM PAYLOADS TEST_MIRROR ALPHA BETA

# No request can escape this stub, and unknown URLs fail. Log every call so
# fallback URLs, retries, cache bypasses, and extraction ordering are visible.
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
set -eu
out= url=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		--retry) shift 2 ;;
		-fsSL|--retry-all-errors) shift ;;
		-*) exit 97 ;;
		*) [ -z "$url" ] || exit 97; url=$1; shift ;;
	esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 97
printf 'curl %s\n' "$url" >>"$CASE/events"
case "$url" in
	"$TEST_MIRROR/$ALPHA.apk"|"$TEST_MIRROR/$BETA.apk") ;;
	*) exit 97 ;;
esac
case "$CURL_MODE" in
	valid) cp "$PAYLOADS/${url##*/}" "$out" ;;
	corrupt) printf 'corrupt downloaded archive\n' >"$out" ;;
	404) printf 'partial HTTP error body\n' >"$out"; exit 22 ;;
	*) exit 97 ;;
esac
EOF
cat >"$STUB/sha256sum" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] || exit 97
printf 'hash %s\n' "${1##*/}" >>"$CASE/events"
exec "$REAL_SHA256SUM" "$@"
EOF
cat >"$STUB/tar" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 4 ] && [ "$1" = -xzf ] && [ "$3" = -C ] || exit 97
name=${2##*/}
printf 'tar %s\n' "$name" >>"$CASE/events"
[ "${TAR_MODE:-valid}" = valid ] || exit 2
# Positive extraction control: record the merged-tree output, without using
# real archives or evaluating any archive-provided code.
printf 'extracted %s\n' "$name" >"$4/$name.extracted"
EOF
chmod +x "$STUB/curl" "$STUB/sha256sum" "$STUB/tar"

new_case() {
	CASE="$TMP/case-$1"
	DL="$CASE/dl"
	CURL_MODE=valid
	TAR_MODE=valid
	mkdir -p "$DL/apk"
	: >"$CASE/events"
	export CASE DL CURL_MODE TAR_MODE
}
write_fixture() {
	# Arguments are only test-controlled literal names/hashes, never APK data.
	printf 'ALPINE_MIRROR="%s"\nALPINE_APKS="%s"\nALPINE_APK_SHA256S="%s"\n' \
		"$TEST_MIRROR" "$1" "$2" >"$CASE/pins.sh"
}
write_valid_fixture() {
	write_fixture "$ALPHA $BETA" "$SHA_A $ALPHA
$SHA_B $BETA"
}
cache_valid() {
	cp "$PAYLOADS/$ALPHA.apk" "$DL/apk/$ALPHA.apk"
	cp "$PAYLOADS/$BETA.apk" "$DL/apk/$BETA.apk"
}
run_case() {
	# A separate shell retains real set -e behavior even when the test checks
	# failure with if; never run extracted blocks in a conditional subshell.
	PATH="$STUB:$PATH" DC1_FETCH_RETRIES=1 \
		sh "$TMP/harness.sh" "$CASE/pins.sh" >"$CASE/log" 2>&1
}
expect_failure() {
	if run_case; then fail "$1 unexpectedly succeeded"; fi
	grep -Fq "$2" "$CASE/log" || fail "$1 failed for an unrelated reason"
	if grep -q '^tar ' "$CASE/events"; then fail "$1 extracted before all hashes passed"; fi
	ok "$1 rejected before any extraction"
}
expect_events() {
	printf '%s\n' "$1" >"$CASE/expected-events"
	cmp -s "$CASE/expected-events" "$CASE/events" || fail "unexpected call order in $CASE"
}

echo "== malformed and inconsistent synthetic pins =="
SHORT=${SHA_A#?}
LONG=${SHA_A}0
UPPER=$(printf '%s' "$SHA_A" | tr 'a-f' 'A-F')
NONHEX=g${SHA_A#?}
for kind in empty short long uppercase nonhex missing-name extra-field; do
	new_case "malformed-$kind"
	case "$kind" in
		empty) entry=" $ALPHA" ;;
		short) entry="$SHORT $ALPHA" ;;
		long) entry="$LONG $ALPHA" ;;
		uppercase) entry="$UPPER $ALPHA" ;;
		nonhex) entry="$NONHEX $ALPHA" ;;
		missing-name) entry="$SHA_A" ;;
		extra-field) entry="$SHA_A $ALPHA extra" ;;
	esac
	write_fixture "$ALPHA" "$entry"
	expect_failure "malformed hash ($kind)" 'FATAL:'
	[ ! -s "$CASE/events" ] || fail "malformed $kind reached fetch/hash/extraction"
done

for kind in identical differing; do
	new_case "duplicate-$kind"
	duplicate=$SHA_A
	[ "$kind" != differing ] || duplicate=$SHA_B
	write_fixture "$ALPHA $BETA" "$SHA_A $ALPHA
$duplicate $ALPHA"
	expect_failure "duplicate hash mapping ($kind digest)" 'malformed or duplicate Alpine package SHA-256 pin'
	[ ! -s "$CASE/events" ] || fail "duplicate mapping reached package processing"
done

new_case fewer-pins
write_fixture "$ALPHA $BETA" "$SHA_A $ALPHA"
expect_failure 'fewer hashes than packages' 'Alpine package/pin count mismatch'
[ ! -s "$CASE/events" ] || fail "count mismatch reached package processing"
new_case extra-pin
write_fixture "$ALPHA" "$SHA_A $ALPHA
$SHA_B $BETA"
expect_failure 'more hashes than packages' 'Alpine package/pin count mismatch'
[ ! -s "$CASE/events" ] || fail "count mismatch reached package processing"

new_case missing-mapping
write_fixture "$ALPHA $BETA" "$SHA_A $ALPHA
$SHA_B gamma-3.0-r0"
cache_valid
expect_failure 'missing mapping despite matching counts' "no SHA-256 pin for Alpine package $BETA"
expect_events "hash $ALPHA.apk"

echo "== cache/download verification and extraction barrier =="
new_case valid-cache
write_valid_fixture
cache_valid
CURL_MODE=404
run_case || fail "valid cached archives were re-fetched or rejected"
expect_events "hash $ALPHA.apk
hash $BETA.apk
tar $ALPHA.apk
tar $BETA.apk"
[ -f "$DL/apkroot/$ALPHA.apk.extracted" ] && [ -f "$DL/apkroot/$BETA.apk.extracted" ] ||
	fail "positive cached extraction control did not run both archives"
ok "valid cache skips curl, verifies every archive, and extracts both"

# Corrupt the LAST package: successfully verifying the first one must never
# permit even its extraction. Preserve an existing tree as a second barrier
# assertion, so moving the rm -rf ahead of verification is detected too.
new_case corrupt-cache
write_valid_fixture
cache_valid
printf 'corrupt cached archive\n' >"$DL/apk/$BETA.apk"
mkdir -p "$DL/apkroot"
printf 'previous tree\n' >"$DL/apkroot/keep"
CURL_MODE=404
expect_failure 'corrupt last cached package' "Alpine package $BETA has SHA-256"
expect_events "hash $ALPHA.apk
hash $BETA.apk"
[ -f "$DL/apkroot/keep" ] || fail "failed verification destroyed existing extraction tree"
ok "a later hash failure preserves the tree and blocks ALL extraction"

new_case valid-download
write_valid_fixture
run_case || fail "matching synthetic downloads were rejected"
expect_events "curl $TEST_MIRROR/$ALPHA.apk
hash $ALPHA.apk
curl $TEST_MIRROR/$BETA.apk
hash $BETA.apk
tar $ALPHA.apk
tar $BETA.apk"
for pkg in "$ALPHA" "$BETA"; do
	cmp -s "$PAYLOADS/$pkg.apk" "$DL/apk/$pkg.apk" || fail "downloaded bytes differ for $pkg"
	[ ! -e "$DL/apk/$pkg.apk.part" ] || fail "successful download left a .part file"
	[ -f "$DL/apkroot/$pkg.apk.extracted" ] || fail "positive download extraction control missing $pkg"
done
grep -Fq 'APK extraction completed' "$CASE/log" || fail "positive harness did not finish"
ok "valid downloads use exact pinned URLs and extract only after all hashes pass"

new_case corrupt-download
write_valid_fixture
cp "$PAYLOADS/$ALPHA.apk" "$DL/apk/$ALPHA.apk"
CURL_MODE=corrupt
expect_failure 'corrupt last downloaded package' "Alpine package $BETA has SHA-256"
expect_events "hash $ALPHA.apk
curl $TEST_MIRROR/$BETA.apk
hash $BETA.apk"

new_case exact-404
write_valid_fixture
CURL_MODE=404
expect_failure 'HTTP 404 for exact pinned URL' "download failed: $TEST_MIRROR/$ALPHA.apk"
expect_events "curl $TEST_MIRROR/$ALPHA.apk"
[ ! -e "$DL/apk/$ALPHA.apk" ] && [ ! -e "$DL/apk/$ALPHA.apk.part" ] ||
	fail "failed download left final or partial cache file"
ok "404 fails closed without alternate URLs or versions and removes partial bytes"

new_case extraction-error
write_valid_fixture
cache_valid
TAR_MODE=fail
if run_case; then fail "failed extraction unexpectedly succeeded"; fi
grep -Fq "cannot extract verified Alpine package $ALPHA" "$CASE/log" ||
	fail "failed extraction did not report the verified package"
expect_events "hash $ALPHA.apk
hash $BETA.apk
tar $ALPHA.apk"
ok "tar failure remains fatal after successful hash verification"

echo "test-alpine-apk-pins: $pass checks passed"
