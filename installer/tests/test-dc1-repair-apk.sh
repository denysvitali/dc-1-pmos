#!/bin/sh
# Offline tests for installer/host/dc1-repair-apk.sh: the sums parser, the
# trust-anchor decision (absent/install, identical/skip, differing/REFUSE),
# repo-list idempotency, the best-effort key-link pass -- plus end-to-end
# runs of the whole repair against a fixture release with stubbed curl/apk.
# No root, no network, no device.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failn=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $*"; }

# Not exported: the end-to-end runs below must reach the real main path.
DC1_REPAIR_APK_LIB=1
. "$HERE/../host/dc1-repair-apk.sh"

SHA_A=1111111111111111111111111111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222222222222222222222222222

echo "== sums_digest =="

cat > "$TMP/SUMS" <<EOF
$SHA_A  dc1-apk.rsa.pub
$SHA_B *jagar-boot.img
EOF

got=$(sums_digest "$TMP/SUMS" dc1-apk.rsa.pub) && [ "$got" = "$SHA_A" ] \
	&& ok "plain entry parsed" || bad "plain entry: got '$got'"
got=$(sums_digest "$TMP/SUMS" jagar-boot.img) && [ "$got" = "$SHA_B" ] \
	&& ok "binary-marker entry parsed" || bad "binary-marker entry: got '$got'"
sums_digest "$TMP/SUMS" not-there >/dev/null 2>&1 \
	&& bad "missing entry accepted" || ok "missing entry rejected"

cat > "$TMP/SUMS" <<EOF
$SHA_A  dup.pub
$SHA_B  dup.pub
EOF
sums_digest "$TMP/SUMS" dup.pub >/dev/null 2>&1 \
	&& bad "duplicate entry accepted" || ok "duplicate entry rejected"

cat > "$TMP/SUMS" <<EOF
deadbeef  short.pub
XYZ1111111111111111111111111111111111111111111111111111111111111111  bad.pub
EOF
sums_digest "$TMP/SUMS" short.pub >/dev/null 2>&1 \
	&& bad "short digest accepted" || ok "short digest rejected"
sums_digest "$TMP/SUMS" bad.pub >/dev/null 2>&1 \
	&& bad "non-hex digest accepted" || ok "non-hex digest rejected"

echo "== decide_key_action =="

# Paths follow DC1_ROOT at call time; point them at a scratch tree.
SCRATCH=$TMP/scratch
DC1_ROOT=$SCRATCH

# Absent key -> install.
rm -rf "$SCRATCH"
[ "$(decide_key_action "$SHA_A")" = "install" ] \
	&& ok "absent key -> install" || bad "absent key not 'install'"

# Identical key -> skip (decided by hash, so formatting noise is irrelevant).
mkdir -p "$SCRATCH/usr/share/apk/keys/aarch64"
printf '# comment noise\n-----BEGIN PUBLIC KEY-----\n' \
	>"$SCRATCH/usr/share/apk/keys/aarch64/dc1-apk.rsa.pub"
real_sha=$(sha256sum "$SCRATCH/usr/share/apk/keys/aarch64/dc1-apk.rsa.pub" | cut -d' ' -f1)
[ "$(decide_key_action "$real_sha")" = "skip" ] \
	&& ok "identical key -> skip" || bad "identical key not 'skip'"

# Differing key -> refuse. This is the load-bearing branch: a mismatched
# trust anchor must stop the repair, never be replaced silently.
[ "$(decide_key_action "$SHA_B")" = "refuse" ] \
	&& ok "differing key -> refuse" || bad "differing key not 'refuse'"

echo "== write_repo_list =="

rm -rf "$SCRATCH"
write_repo_list \
	&& grep -q '^https://github.com/denysvitali/dc-1-pmos/releases/download/latest/APKINDEX.tar.gz$' \
		"$SCRATCH/etc/apk/repositories.d/dc1-pmos.list" \
	&& ok "list written with the index URL" || bad "list missing or wrong URL"
printf '# operator-curated list\nhttp://example.invalid/APKINDEX.tar.gz\n' \
	>"$SCRATCH/etc/apk/repositories.d/dc1-pmos.list"
before=$(cat "$SCRATCH/etc/apk/repositories.d/dc1-pmos.list")
write_repo_list
after=$(cat "$SCRATCH/etc/apk/repositories.d/dc1-pmos.list")
[ "$before" = "$after" ] \
	&& ok "existing list never rewritten" || bad "existing list was rewritten"

echo "== key_link_pass =="

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/usr/share/apk/keys/aarch64" "$SCRATCH/etc/apk/keys"
touch "$SCRATCH/usr/share/apk/keys/alpine-a.pub" \
	"$SCRATCH/usr/share/apk/keys/aarch64/dc1-apk.rsa.pub"
key_link_pass aarch64
for k in alpine-a.pub dc1-apk.rsa.pub; do
	[ -L "$SCRATCH/etc/apk/keys/$k" ] \
		&& ok "linked $k" || bad "$k not linked"
done
printf 'operator key\n' >"$SCRATCH/etc/apk/keys/manual.pub"
touch "$SCRATCH/usr/share/apk/keys/manual.pub"
key_link_pass aarch64
[ ! -L "$SCRATCH/etc/apk/keys/manual.pub" ] \
	&& [ "$(cat "$SCRATCH/etc/apk/keys/manual.pub")" = "operator key" ] \
	&& ok "pass never overwrites an existing key" || bad "existing key clobbered"

# --------------------------------------------------------------- e2e helpers

FIXTURE=$TMP/release
mkdir -p "$FIXTURE"
PUB="-----BEGIN PUBLIC KEY-----
TESTKEYBODY
-----END PUBLIC KEY-----"
printf '%s\n' "$PUB" >"$FIXTURE/dc1-apk.rsa.pub"
PUB_SHA=$(sha256sum "$FIXTURE/dc1-apk.rsa.pub" | cut -d' ' -f1)

# make_curl_stub BODY -- install a stub curl whose response table is BODY
# (a case pattern over the fetched URL writing to $out).
make_curl_stub() {
	{
		echo '#!/bin/sh'
		echo 'out=""'
		echo 'for a in "$@"; do'
		echo '	case "$prev" in'
		echo '		-o) out=$a ;;'
		echo '	esac'
		echo '	case "$a" in'
		echo '		-o) prev=$a ;;'
		echo '		-*) prev="" ;;'
		echo '		*)  prev=""; url=$a ;;'
		echo '	esac'
		echo 'done'
		echo 'case "$url" in'
		cat
		echo '	*) exit 22 ;;'
		echo 'esac'
	} >"$STUB/curl"
	chmod +x "$STUB/curl"
}

make_apk_stub() {
	{
		echo '#!/bin/sh'
		printf 'echo "$*" >> %s\n' "'$TMP/apk-calls'"
		echo 'exit 0'
	} >"$STUB/apk"
	chmod +x "$STUB/apk"
}

STUB=$TMP/stub
mkdir -p "$STUB"

run_repair() {
	# run_repair ROOTTREE -> output on stdout, status in $repair_rc.
	PATH="$STUB:$PATH" DC1_ROOT="$1" \
		DC1_URL_BASE="https://release.invalid/download" \
		sh "$HERE/../host/dc1-repair-apk.sh" 2>&1
}

echo "== end-to-end: full repair on a scratch root =="

cat >"$FIXTURE/SHA256SUMS" <<EOF
$PUB_SHA  dc1-apk.rsa.pub
9999999999999999999999999999999999999999999999999999999999999999  jagar-rootfs.ext4.zst
EOF

ROOTTREE=$TMP/root-e2e
mkdir -p "$ROOTTREE/lib/apk/db"
cat >"$ROOTTREE/lib/apk/db/installed" <<EOF
P:mutter-mobile
V:48.0-r3

P:device-daylight-jagar
V:1-r44

EOF
: >"$TMP/apk-calls"
make_apk_stub
make_curl_stub <<'STUBBODY'
	*/SHA256SUMS) cp RELEASEDIR/SHA256SUMS "$out" ;;
	*/dc1-apk.rsa.pub) cp RELEASEDIR/dc1-apk.rsa.pub "$out" ;;
STUBBODY
sed -i "s|RELEASEDIR|$FIXTURE|g" "$STUB/curl"

out=$(run_repair "$ROOTTREE") && repair_rc=0 || repair_rc=$?
[ "$repair_rc" = 0 ] && ok "repair exited 0" || { bad "repair exited $repair_rc"; echo "$out"; }
cmp -s "$ROOTTREE/usr/share/apk/keys/aarch64/dc1-apk.rsa.pub" "$FIXTURE/dc1-apk.rsa.pub" \
	&& ok "verified key installed in /usr/share/apk/keys/aarch64" \
	|| bad "installed key differs"
[ -L "$ROOTTREE/etc/apk/keys/dc1-apk.rsa.pub" ] \
	&& ok "key linked into /etc/apk/keys" || bad "/etc/apk/keys link missing"
grep -q '^https://release.invalid/download/APKINDEX.tar.gz$' \
	"$ROOTTREE/etc/apk/repositories.d/dc1-pmos.list" \
	&& ok "repo list written with the configured base URL" || bad "repo list wrong"
grep -q -- '--root' "$TMP/apk-calls" \
	&& ok "apk ran against DC1_ROOT" || bad "apk did not use --root"
grep -qE '(^| )update$' "$TMP/apk-calls" && grep -qE '(^| )upgrade$' "$TMP/apk-calls" \
	&& ok "apk update + upgrade both ran" || bad "apk calls: $(cat "$TMP/apk-calls")"
printf '%s\n' "$out" | grep -q "48.0-r3" && printf '%s\n' "$out" | grep -q "1-r44" \
	&& ok "reported installed versions" || bad "version report missing: $out"

echo "== end-to-end: second run is idempotent =="

mv "$TMP/apk-calls" "$TMP/apk-calls.1"
cp "$ROOTTREE/etc/apk/repositories.d/dc1-pmos.list" "$TMP/list.before"
out=$(run_repair "$ROOTTREE") && repair_rc=0 || repair_rc=$?
[ "$repair_rc" = 0 ] && ok "second run exited 0" || { bad "second run exited $repair_rc"; echo "$out"; }
cmp -s "$ROOTTREE/etc/apk/repositories.d/dc1-pmos.list" "$TMP/list.before" \
	&& ok "repo list untouched on re-run" || bad "repo list rewritten on re-run"
grep -qE '(^| )upgrade$' "$TMP/apk-calls" \
	&& ok "upgrade re-attempted on re-run" || bad "re-run skipped apk: $(cat "$TMP/apk-calls")"
printf '%s\n' "$out" | grep -q "already present and identical" \
	&& ok "identical key kept on re-run" || bad "identical-key branch not taken: $out"

echo "== end-to-end: refusal paths =="

# A pre-existing DIFFERENT key must abort BEFORE apk ever runs.
DIFFKEY=$TMP/diffkey-root
mkdir -p "$DIFFKEY/usr/share/apk/keys/aarch64" "$DIFFKEY/lib/apk/db"
printf 'not-the-release-key\n' >"$DIFFKEY/usr/share/apk/keys/aarch64/dc1-apk.rsa.pub"
: >"$TMP/apk-calls"
out=$(run_repair "$DIFFKEY") && repair_rc=0 || repair_rc=$?
[ "$repair_rc" != 0 ] && ok "differing key refuses (rc $repair_rc)" \
	|| { bad "differing key accepted"; echo "$out"; }
printf '%s\n' "$out" | grep -q "trust anchor" \
	&& ok "refusal names the trust anchor" || bad "refusal message unclear: $out"
[ ! -s "$TMP/apk-calls" ] \
	&& ok "no apk invocation before refusal" || bad "apk ran despite refusal: $(cat "$TMP/apk-calls")"

# A SHA256SUMS without the key entry must fail closed.
NOSUMS=$TMP/nosums-root
mkdir -p "$NOSUMS"
make_curl_stub <<'STUBBODY'
	*/SHA256SUMS) printf 'deadbeef  something-else\n' >"$out" ;;
STUBBODY
out=$(run_repair "$NOSUMS") && repair_rc=0 || repair_rc=$?
[ "$repair_rc" != 0 ] && ok "missing sums entry fails closed (rc $repair_rc)" \
	|| { bad "missing sums entry tolerated"; echo "$out"; }
printf '%s\n' "$out" | grep -q "no usable SHA256SUMS entry" \
	&& ok "failure names the missing entry" || bad "wrong failure message: $out"

# A downloaded key that does not match SHA256SUMS must fail closed.
make_curl_stub <<STUBBODY
	*/SHA256SUMS) printf '$PUB_SHA  dc1-apk.rsa.pub\n' >"\$out" ;;
	*/dc1-apk.rsa.pub) printf 'TAMPERED\n' >"\$out" ;;
STUBBODY
out=$(run_repair "$NOSUMS") && repair_rc=0 || repair_rc=$?
[ "$repair_rc" != 0 ] && ok "hash-mismatched key refused (rc $repair_rc)" \
	|| { bad "tampered key accepted"; echo "$out"; }
printf '%s\n' "$out" | grep -q "does not match SHA256SUMS" \
	&& ok "mismatch message present" || bad "mismatch message missing: $out"

echo
echo "test-dc1-repair-apk: $pass ok, $failn failed"
[ "$failn" -eq 0 ]
