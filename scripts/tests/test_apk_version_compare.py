#!/usr/bin/env python3
"""Offline tests for scripts/apk_version_compare.py.

The expectations here were transcribed from the authoritative oracle -- the
apk-tools 3.0.7 that actually runs on the DC-1, via `apk version -t` and
`apk version -c` -- not from documentation. The folklore semantics differ
from the real ones in several places (see the module docstring of the tool);
every case below encodes a measured behavior, and the trickier ones are
commented with the oracle output they pin.

These tests run the CLI, so they cover the exit-code contract too. No apk,
no network, no root.
"""
from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "apk_version_compare.py"


def cmp_versions(a: str, b: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(TOOL), "cmp", a, b],
        check=False,
        text=True,
        capture_output=True,
    )


class CmpValidTest(unittest.TestCase):
    def assert_rel(self, a: str, rel: str, b: str) -> None:
        result = cmp_versions(a, b)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), rel)

    def test_release_collision_cases(self) -> None:
        # The cases that motivated the tool: upstream pmOS mutter forks and
        # our overlay must never compare the wrong way.
        self.assert_rel("999948.0-r2", "-1", "999948.0-r4")
        self.assert_rel("999948.0-r4", "1", "999948.0-r2")
        self.assert_rel("48.0-r3", "-1", "999948.0-r4")
        self.assert_rel("999948.0-r4", "1", "48.0-r3")

    def test_pre_suffixes_sort_below_bare(self) -> None:
        # apk-tools 3.x suffix table: alpha beta PRE rc < (bare).
        # "preview" is NOT a suffix in this apk-tools and must be refused.
        order = ["7.2_alpha", "7.2_beta", "7.2_pre", "7.2_rc", "7.2"]
        for a, b in zip(order, order[1:]):
            self.assert_rel(a, "-1", b)
            self.assert_rel(b, "1", a)

    def test_post_suffixes_sort_above_bare(self) -> None:
        order = ["7.2", "7.2_cvs", "7.2_svn", "7.2_git", "7.2_hg", "7.2_p"]
        for a, b in zip(order, order[1:]):
            self.assert_rel(a, "-1", b)
            self.assert_rel(b, "1", a)

    def test_suffix_numbers(self) -> None:
        # Numeric suffix tails, including multi-digit ordering.
        self.assert_rel("7.2_rc1", "-1", "7.2_rc2")
        self.assert_rel("7.2_rc2", "-1", "7.2_rc10")
        self.assert_rel("7.2_git20260819", "-1", "7.2_git20260820")
        self.assert_rel("7.2_git20260819", "1", "7.2")

    def test_missing_tail_sorts_below_explicit_zero(self) -> None:
        # Measured on-device: nothing is zero-padded. An absent component
        # LOSES to an explicit zero of the same kind.
        self.assert_rel("1", "-1", "1-r0")
        self.assert_rel("1.0", "-1", "1.0.0")
        self.assert_rel("7.2_rc", "-1", "7.2_rc0")
        self.assert_rel("7.2_cvs", "-1", "7.2_cvs0")
        self.assert_rel("7.2_p0", "1", "7.2_p")

    def test_letters(self) -> None:
        # One trailing lowercase letter (after the initial number too --
        # "1a" is valid) outranks the bare number and every suffix, but
        # loses to a further dotted number.
        self.assert_rel("7.2a", "1", "7.2")
        self.assert_rel("7.2b", "1", "7.2a")
        self.assert_rel("7.2a", "1", "7.2_rc1")
        self.assert_rel("7.2a", "1", "7.2_p")
        self.assert_rel("1a", "1", "1")
        self.assert_rel("1a", "-1", "1.1")
        self.assert_rel("1.2a-r1", "-1", "1.2b-r1")

    def test_letter_and_suffix_compose(self) -> None:
        # Measured: a letter may be followed by a known suffix ("1.2a_p"
        # valid; "1.2a_b" fails only because b is no suffix name).
        self.assert_rel("1.2a_p", "0", "1.2a_p")

    def test_commit_hash_ordering(self) -> None:
        # Measured: ~hash sits AFTER suffixes and BEFORE -r, at most once;
        # anything after the hash except -r is refused.
        self.assert_rel("1.2~deadbeef", "1", "1.2")
        self.assert_rel("1.2_p~aa-r1", "0", "1.2_p~aa-r1")
        self.assert_rel("1.2~aa-r1", "0", "1.2~aa-r1")
        for bad in ["1.2~deadbeef_p1", "1.2~aa~bb"]:
            result = cmp_versions(bad, "1")
            self.assertEqual(result.returncode, 2, f"{bad!r}: {result.stdout}")

    def test_leading_zeros_byte_sort(self) -> None:
        # Later dotted parts: a leading zero on EITHER side switches to a
        # raw byte sort (Gentoo-like). Initial number and revisions stay
        # purely numeric.
        self.assert_rel("1.02", "-1", "1.2")
        self.assert_rel("1.002", "-1", "1.2")
        self.assert_rel("1.02", "-1", "1.10")
        self.assert_rel("1.010", "1", "1.01")
        self.assert_rel("1.00", "1", "1.0")
        self.assert_rel("1.07", "-1", "1.7")
        self.assert_rel("07", "0", "7")
        self.assert_rel("01.2", "0", "1.2")
        self.assert_rel("1-r07", "0", "1-r7")

    def test_revisions_numeric(self) -> None:
        self.assert_rel("999948.0-r2", "-1", "999948.0-r4")
        self.assert_rel("1-r2", "-1", "1-r10")
        self.assert_rel("1-r2", "1", "1-r1")

    def test_type_divergence_rules(self) -> None:
        # A further dotted number outranks a revision or a suffix; a letter
        # outranks any suffix; ~commit-hash outranks the bare version.
        self.assert_rel("1-r1", "-1", "1.1")
        self.assert_rel("1.0-r1", "-1", "1.0.1")
        self.assert_rel("1.2.1", "1", "1.2_rc")
        self.assert_rel("1.2_rc1", "-1", "1.2.1")
        self.assert_rel("1.2.1", "1", "1.2_p")
        self.assert_rel("1.2~deadbeef", "1", "1.2")

    def test_uint64_wrap(self) -> None:
        # apk parses numbers into uint64_t; 2**64+1 wraps to 1.
        self.assert_rel("18446744073709551617", "0", "1")

    def test_equal_forms(self) -> None:
        self.assert_rel("7.2", "0", "7.2")
        self.assert_rel("1", "0", "1")
        self.assert_rel("1_alpha_beta", "0", "1_alpha_beta")


class CmpInvalidTest(unittest.TestCase):
    def check_rejected(self, version: str) -> None:
        result = cmp_versions(version, "1")
        self.assertEqual(result.returncode, 2, f"{version!r}: {result.stdout}")
        self.assertTrue(
            result.stderr.startswith("invalid version:"),
            f"{version!r}: unexpected stderr {result.stderr!r}",
        )

    def test_malformed_refused(self) -> None:
        for bad in [
            "",  # empty
            "abc",  # no leading number
            ".5",
            "1.",
            "1..2",
            "1x2",  # digit letter digit
            "1.a",  # letter must follow a number
            "a1",
            "7a.2",  # letter only at the end of the numeric run
            "1.ab",  # single letter only
            "1_A",  # uppercase letter
            "1.0A",
            "1_x",  # unknown suffix
            "7.2_preview",  # apk-tools 3.x has "pre", not "preview"
            "7.2_1",  # bare number is not a suffix
            "1_r1",  # suffix separator without a suffix name
            "1.0.rc1",  # dots do not carry suffixes
            "1.0-R1",  # revision marker is lowercase -r
            "1-",  # bare '-'
            "1-r",  # revision without a number
            "1.2-a",
            "1.2a_b",  # b is not a suffix name (1.2a_p would be fine)
            "1.2a.",
            "1.0~",  # ~ without a hash
            "1.2~zz",  # non-hex hash
            "1.2a.1b",
        ]:
            with self.subTest(version=bad):
                self.check_rejected(bad)

    def test_valid_shapes_accepted(self) -> None:
        for good in [
            "1",
            "12",
            "7.2",
            "7.2_rc5",
            "999948.0",
            "7.2a",
            "1.02",
            "007",
            "01.2",
            "1_p1",
            "1_alpha_beta",
            "1_rc-r1",
            "1.2a-r1",
            "1.2~deadbeef",
            "1.00002",
        ]:
            with self.subTest(version=good):
                result = cmp_versions(good, good)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "0")

    def test_usage_refused(self) -> None:
        for argv in ([], ["cmp"], ["cmp", "1"], ["nonsense", "1", "2"]):
            with self.subTest(argv=argv):
                result = subprocess.run(
                    ["python3", str(TOOL), *argv],
                    check=False,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 2)


class IndexMaxTest(unittest.TestCase):
    def run_index_max(self, index_text: str, package: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            index = Path(temporary) / "APKINDEX"
            index.write_text(index_text)
            return subprocess.run(
                ["python3", str(TOOL), "index-max", str(index), package],
                check=False,
                text=True,
                capture_output=True,
            )

    def synthetic_index(self) -> str:
        # Minimal P:/V: block shape, several packages, several versions of
        # the interesting one -- the shape the Gate B fetch produces.
        return (
            "C:Q1abcdef=\n"
            "P:mutter-mobile\n"
            "V:48.0-r3\n"
            "A:aarch64\n"
            "\n"
            "C:Q2abcdef=\n"
            "P:mutter-mobile\n"
            "V:999948.0-r2\n"
            "A:aarch64\n"
            "\n"
            "C:Q3abcdef=\n"
            "P:mutter-mobile\n"
            "V:999948.0-r4\n"
            "A:aarch64\n"
            "\n"
            "C:Q4abcdef=\n"
            "P:linux-postmarketos-mediatek-mt6789\n"
            "V:7.2_rc5-r0\n"
            "A:aarch64\n"
            "\n"
        )

    def test_picks_highest_version(self) -> None:
        result = self.run_index_max(self.synthetic_index(), "mutter-mobile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "999948.0-r4")

    def test_single_entry(self) -> None:
        result = self.run_index_max(
            self.synthetic_index(), "linux-postmarketos-mediatek-mt6789"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "7.2_rc5-r0")

    def test_absent_package_exit_1(self) -> None:
        result = self.run_index_max(self.synthetic_index(), "device-daylight-jagar")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_unparsable_target_version_exit_2(self) -> None:
        index = self.synthetic_index() + "P:broken\nV:7.2_preview\nA:aarch64\n\n"
        result = self.run_index_max(index, "broken")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_unparsable_other_package_ignored(self) -> None:
        # Only the target package's versions may fail a query: an entry we
        # do not compare can never fail a gate it is not part of.
        index = (
            "C:Q1=\nP:other\nV:not-a-version\nA:aarch64\n\n"
            "C:Q2=\nP:mutter-mobile\nV:48.0-r3\nA:aarch64\n\n"
        )
        result = self.run_index_max(index, "mutter-mobile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "48.0-r3")

    def test_stdin_input(self) -> None:
        result = subprocess.run(
            ["python3", str(TOOL), "index-max", "-", "mutter-mobile"],
            input=self.synthetic_index(),
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "999948.0-r4")

    def test_missing_file_exit_2(self) -> None:
        result = subprocess.run(
            ["python3", str(TOOL), "index-max", "/nonexistent/APKINDEX", "p"],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
