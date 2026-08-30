#!/usr/bin/env python3
"""Offline regression tests for verify-kernel-artifacts.py."""

import gzip
import io
import struct
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "verify-kernel-artifacts.py"


def make_apk(path: Path, vmlinuz: bytes) -> None:
    info = tarfile.TarInfo("boot/vmlinuz")
    info.size = len(vmlinuz)
    info.mtime = 0
    with tarfile.open(path, "w:gz") as archive:
        archive.addfile(info, io.BytesIO(vmlinuz))


def make_boot(path: Path, kernel: bytes) -> None:
    doff = 80
    dtb = b"\xd0\x0d\xfe\xed" + b"D" * 12
    koff = doff + len(dtb)
    blob = bytearray(koff + len(kernel))
    blob[56:60] = b"ARM\x64"
    struct.pack_into("<4I", blob, 0x40, doff, len(dtb), koff, len(kernel))
    blob[doff:koff] = dtb
    blob[koff:] = kernel
    packed = gzip.compress(bytes(blob), mtime=0)
    header = bytearray(4096)
    header[:8] = b"ANDROID!"
    struct.pack_into("<I", header, 8, len(packed))
    path.write_bytes(header + packed)


def run(*args: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *(str(arg) for arg in args)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    raw = b"kernel-image" * 1024
    image = root / "Image.gz"
    image.write_bytes(gzip.compress(raw, mtime=0))
    apk = root / "linux-test.apk"
    make_apk(apk, image.read_bytes())
    boot_a = root / "installer-boot.img"
    boot_b = root / "jagar-boot.img"
    make_boot(boot_a, raw)
    make_boot(boot_b, raw)

    good = run(apk, image, boot_a, boot_b)
    assert good.returncode == 0, good.stderr
    assert "parity passed" in good.stdout

    make_boot(boot_b, raw + b"drift")
    bad = run(apk, image, boot_a, boot_b)
    assert bad.returncode != 0
    assert "differs" in bad.stderr

print("verify-kernel-artifacts tests passed")
