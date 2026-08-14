#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest


BUILDER = Path(__file__).resolve().parents[1] / "make-rootfs-archive.py"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RootfsArchiveTest(unittest.TestCase):
    def run_builder(self, source: Path, destination: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(BUILDER),
                "--source",
                str(source),
                "--archive",
                str(destination / "rootfs.tar.gz"),
                "--inventory",
                str(destination / "FILES.tsv"),
                "--epoch",
                "1786605622",
            ],
            check=False,
            text=True,
            capture_output=True,
        )

    def test_outputs_are_reproducible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "rootfs"
            (source / "etc").mkdir(parents=True)
            (source / "usr/bin").mkdir(parents=True)
            (source / "etc/os-release").write_text("NAME=postmarketOS\n")
            (source / "usr/bin/tool").write_bytes(b"tool\n")
            (source / "usr/bin/tool-link").symlink_to("tool")
            first, second = base / "first", base / "second"
            first.mkdir()
            second.mkdir()

            self.assertEqual(self.run_builder(source, first).returncode, 0)
            self.assertEqual(self.run_builder(source, second).returncode, 0)
            self.assertEqual(digest(first / "rootfs.tar.gz"), digest(second / "rootfs.tar.gz"))
            self.assertEqual((first / "FILES.tsv").read_bytes(), (second / "FILES.tsv").read_bytes())

    def test_credentials_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "rootfs"
            destination = base / "out"
            (source / "root/.ssh").mkdir(parents=True)
            (source / "root/.ssh/authorized_keys").write_text("ssh-ed25519 forbidden\n")
            destination.mkdir()

            result = self.run_builder(source, destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("credential-like path", result.stderr)

    def test_key_markers_rejected_in_text_but_not_elf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "rootfs"
            destination = base / "out"
            (source / "usr/bin").mkdir(parents=True)
            # ssh-keygen embeds the PEM banner as a format constant.
            (source / "usr/bin/ssh-keygen").write_bytes(
                b"\x7fELF-----BEGIN OPENSSH PRIVATE KEY-----")
            destination.mkdir()
            self.assertEqual(self.run_builder(source, destination).returncode, 0)

            (source / "etc/leaked").mkdir(parents=True)
            (source / "etc/leaked/key.pem").write_bytes(
                b"-----BEGIN OPENSSH PRIVATE KEY-----\n")
            second = base / "out2"
            second.mkdir()
            result = self.run_builder(source, second)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("private-key marker", result.stderr)


if __name__ == "__main__":
    unittest.main()
