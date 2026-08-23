#!/usr/bin/env python3
"""apk-tools version comparator -- stdlib-only, offline, fail-closed.

Implements the version ordering of the apk-tools this project actually ships
against (3.x, verified token-for-token against `apk version -t`/`-c` on the
DC-1, apk-tools 3.0.7). This is NOT the folklore version of the semantics:

  - The pre-suffixes are alpha, beta, PRE and RC ("preview" does not exist
    and is refused). Pre-suffixes sort below a bare version, post-suffixes
    (cvs svn git hg p) above it.
  - A MISSING trailing component sorts BELOW an explicit zero: 1 < 1-r0,
    1.0 < 1.0.0, 7.2_rc < 7.2_rc0. Nothing is padded to equal length.
  - Comparison walks a typed-token stream (initial number, later .numbers,
    one trailing letter, ~hash, _suffix[_number], -r revision). Tokens must
    match in TYPE step by step; the first divergence decides by fixed rules,
    and TOKEN_END outranks every data token except that a pre-release
    suffix facing an END still loses (the "non-ending version wins unless
    it ended on a pre-suffix" rule).
  - Later dotted numbers compare as raw byte strings when EITHER side has a
    leading zero (Gentoo-style sort: 1.02 < 1.2, 1.010 > 1.01). The initial
    number, suffix numbers and revisions always compare numerically.
  - Numbers wrap as uint64 (apk parses into uint64_t): 2**64+1 == 1.

Fail-closed posture: anything that is not an unambiguous apk version exits
2 rather than guessing. Only the requested package's versions are parsed in
index mode, so a strange-but-valid entry elsewhere in an upstream index can
never fail a gate it is not part of.

Subcommands:
  cmp V1 V2                    print -1 | 0 | 1 (V1<V2, ==, >); exit 2 on
                               any unparsable version
  index-max INDEX_FILE PKG     print the highest V: among the P: PKG blocks
                               of an APKINDEX text ("-": stdin);
                               exit 1 if absent, 2 if its versions misparse
"""

import sys

# Ordered suffix table, exactly apk-tools DECLARE_SUFFIXES: enum order IS
# precedence. Everything before NONE is a pre-release marker, everything
# after is a post-release marker.
SUFFIXES = [
    "alpha",
    "beta",
    "pre",
    "rc",
    None,  # SUFFIX_NONE: the implicit "bare" rank between rc and cvs
    "cvs",
    "svn",
    "git",
    "hg",
    "p",
]
SUFFIX_RANK = {name: i for i, name in enumerate(SUFFIXES) if name is not None}
RANK_NONE = SUFFIXES.index(None)

UINT64_MASK = (1 << 64) - 1

# Token type ranks, mirroring apk-tools' PARTS enum. The ORDER carries the
# semantics of the divergence rules; do not reorder it casually.
T_INITIAL_DIGIT = 0
T_DIGIT = 1
T_LETTER = 2
T_SUFFIX = 3
T_SUFFIX_NO = 4
T_COMMIT_HASH = 5
T_REVISION_NO = 6
T_END = 7

HEX_DIGITS = set("0123456789abcdef")
DIGITS = set("0123456789")


class Invalid(Exception):
    """The string is not a version apk would accept."""


def _parse(text):
    """Parse an apk version into a token stream [(type, payload)].

    Payload: digit-ish tokens keep their raw string (leading zeros are
    significant to the comparison), letters carry the character, suffix
    tokens carry their rank, hashes carry the hex string.
    """
    if not text:
        raise Invalid("empty version")

    tokens = []
    i, n = 0, len(text)

    def digits(start):
        j = start
        while j < n and text[j] in DIGITS:
            j += 1
        return j

    # Initial number: mandatory, no separator.
    j = digits(i)
    if j == i:
        raise Invalid("must start with a number")
    tokens.append((T_INITIAL_DIGIT, text[i:j]))
    i = j

    # Dotted numbers. ONE lowercase letter may terminate the numeric run,
    # but nothing numeric may follow it (apk refuses 1x2, 7a.2, 1.0a.1).
    while i < n and text[i] == ".":
        j = digits(i + 1)
        if j == i + 1:
            raise Invalid("dotted part without digits")
        tokens.append((T_DIGIT, text[i + 1 : j]))
        i = j
    if i < n and "a" <= text[i] <= "z":
        tokens.append((T_LETTER, text[i]))
        i += 1

    # Suffixes, then an optional ~commit-hash, then the optional -r
    # revision -- in that order (measured: 1.2_p~aa-r1 valid,
    # 1.2~deadbeef_p1 refused, only one hash).
    while i < n and text[i] == "_":
        j = i + 1
        while j < n and text[j].isalpha():
            j += 1
        name = text[i + 1 : j]
        if name not in SUFFIX_RANK:
            raise Invalid(f"unknown suffix {name!r}")
        tokens.append((T_SUFFIX, SUFFIX_RANK[name]))
        i = j
        j = digits(i)
        if j > i:
            tokens.append((T_SUFFIX_NO, text[i:j]))
            i = j

    if i < n and text[i] == "~":
        j = i + 1
        while j < n and text[j] in HEX_DIGITS:
            j += 1
        if j == i + 1:
            raise Invalid("~ commit hash without hex digits")
        tokens.append((T_COMMIT_HASH, text[i + 1 : j]))
        i = j

    if i < n and text[i] == "-":
        if not text.startswith("-r", i):
            raise Invalid(f"stray '-' at offset {i}")
        j = digits(i + 2)
        if j == i + 2:
            raise Invalid("-r without revision number")
        tokens.append((T_REVISION_NO, text[i + 2 : j]))
        i = j

    if i != n:
        raise Invalid(f"unexpected {text[i:]!r} at offset {i}")
    return tokens


def _digit_cmp(a, b, leading_zero_sensitive=True):
    """apk digit-token ordering: numeric uint64, unless either side has a
    leading zero and the token kind is the sensitive one -- then a raw byte
    sort (so padding orders like Gentoo: 02 < 2, 010 > 01)."""
    if leading_zero_sensitive and (a[:1] == "0" or b[:1] == "0"):
        ab, bb = a.encode(), b.encode()
        return (ab > bb) - (ab < bb)
    av, bv = int(a) & UINT64_MASK, int(b) & UINT64_MASK
    return (av > bv) - (av < bv)


def _token_cmp(ta, tb):
    kind_a, val_a = ta
    kind_b, val_b = tb
    if kind_a != kind_b:  # callers guarantee same-kind
        raise AssertionError("token kinds diverged inside token_cmp")
    if kind_a in (T_INITIAL_DIGIT, T_SUFFIX_NO, T_REVISION_NO):
        return _digit_cmp(val_a, val_b, leading_zero_sensitive=False)
    if kind_a == T_DIGIT:
        return _digit_cmp(val_a, val_b)
    if kind_a == T_LETTER:
        va, vb = ord(val_a), ord(val_b)
        return (va > vb) - (va < vb)
    if kind_a == T_SUFFIX:
        return (val_a > val_b) - (val_a < val_b)
    if kind_a == T_COMMIT_HASH:
        va, vb = val_a.encode(), val_b.encode()
        return (va > vb) - (va < vb)
    raise AssertionError(f"uncomparable token kind {kind_a}")


def compare(v1, v2):
    """Return -1, 0 or 1 for two already-valid version strings."""
    sa, sb = _parse(v1), _parse(v2)

    def tok(stream, idx):
        return stream[idx] if idx < len(stream) else (T_END, None)

    ia = ib = 0
    ta, tb = tok(sa, ia), tok(sb, ib)
    # Walk while both sides emit the SAME kind; the first value difference
    # inside a kind decides, exactly like apk's comparison loop.
    while ta[0] == tb[0] and ta[0] != T_END:
        r = _token_cmp(ta, tb)
        if r:
            return r
        ia += 1
        ib += 1
        ta, tb = tok(sa, ia), tok(sb, ib)

    # Streams diverged or one ended. Both ended simultaneously -> equal.
    if ta[0] == tb[0]:  # both T_END
        return 0
    # A version still holding a PRE-release suffix when the other has
    # finished is the older one, even though T_END outranks data tokens.
    if ta[0] == T_SUFFIX and ta[1] < RANK_NONE:
        return -1
    if tb[0] == T_SUFFIX and tb[1] < RANK_NONE:
        return 1
    # Higher-ranked token type means the OTHER side is newer: T_END beats
    # any data token, and among data tokens earlier kinds beat later ones
    # (a new dotted number outranks a revision, etc.).
    if ta[0] > tb[0]:
        return -1
    return 1


def validate(text):
    _parse(text)


def index_max(index_text, package):
    """Highest version recorded for PACKAGE in APKINDEX text, or None.

    Only the target package's V: values are parsed; anything else in the
    index is skipped untouched (see module docstring).
    """
    best = None
    current = None
    for line in index_text.splitlines():
        if line.startswith("P:"):
            current = line[2:]
        elif line.startswith("V:") and current == package:
            candidate = line[2:]
            validate(candidate)  # raises Invalid -> caller turns into exit 2
            if best is None or compare(candidate, best) > 0:
                best = candidate
    return best


def main(argv):
    usage = (
        "usage: apk_version_compare.py cmp V1 V2\n"
        "       apk_version_compare.py index-max INDEX_FILE|- PKGNAME\n"
    )
    if len(argv) >= 1 and argv[0] == "cmp" and len(argv) == 3:
        try:
            validate(argv[1])
            validate(argv[2])
        except Invalid as exc:
            print(f"invalid version: {exc}", file=sys.stderr)
            return 2
        print(compare(argv[1], argv[2]))
        return 0
    if len(argv) >= 1 and argv[0] == "index-max" and len(argv) == 3:
        path, package = argv[1], argv[2]
        if path == "-":
            text = sys.stdin.read()
        else:
            try:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
            except OSError as exc:
                print(f"cannot read index: {exc}", file=sys.stderr)
                return 2
        try:
            best = index_max(text, package)
        except Invalid as exc:
            print(f"invalid version in index for {package}: {exc}", file=sys.stderr)
            return 2
        if best is None:
            print(f"package {package!r} not found in index", file=sys.stderr)
            return 1
        print(best)
        return 0
    print(usage, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
