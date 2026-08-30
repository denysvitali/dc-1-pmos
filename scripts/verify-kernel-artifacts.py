#!/usr/bin/env python3
"""Require one exact kernel across the shipped APK, rootfs export and boots."""

from __future__ import annotations

import gzip
import hashlib
import struct
import sys
import tarfile
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(f"kernel artifact parity failed: {message}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def apk_vmlinuz(path: Path) -> bytes:
    try:
        with tarfile.open(path, "r:*") as apk:
            member = apk.extractfile("boot/vmlinuz")
            if member is None:
                fail(f"{path}: boot/vmlinuz is not a regular file")
            return member.read()
    except (OSError, tarfile.TarError, KeyError) as exc:
        fail(f"{path}: cannot extract boot/vmlinuz: {exc}")


def gunzip(label: str, data: bytes) -> bytes:
    try:
        return gzip.decompress(data)
    except (OSError, EOFError) as exc:
        fail(f"{label}: invalid gzip stream: {exc}")


def boot_inner_kernel(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 4096 or data[:8] != b"ANDROID!":
        fail(f"{path}: not an Android boot image")
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    if kernel_size <= 0 or 4096 + kernel_size > len(data):
        fail(f"{path}: invalid kernel size {kernel_size}")
    blob = gunzip(str(path), data[4096 : 4096 + kernel_size])
    if len(blob) < 80 or blob[56:60] != b"ARM\x64":
        fail(f"{path}: kernel slot is not a dtbswap arm64 payload")
    doff, dlen, koff, klen = struct.unpack_from("<4I", blob, 0x40)
    if doff <= 0 or dlen <= 0 or koff <= doff or klen <= 0:
        fail(f"{path}: invalid dtbswap payload table")
    if doff + dlen > len(blob) or blob[doff : doff + 4] != b"\xd0\x0d\xfe\xed":
        fail(f"{path}: no FDT at the dtbswap DTB offset")
    if koff + klen != len(blob):
        fail(f"{path}: dtbswap kernel does not end at payload boundary")
    return blob[koff : koff + klen]


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(
            "usage: verify-kernel-artifacts.py KERNEL.apk Image.gz BOOT.img [BOOT.img ...]",
            file=sys.stderr,
        )
        return 2

    apk_path, image_path, *boot_paths = map(Path, argv[1:])
    apk_gzip = apk_vmlinuz(apk_path)
    exported_gzip = image_path.read_bytes()
    if apk_gzip != exported_gzip:
        fail(
            f"{apk_path.name} boot/vmlinuz differs byte-for-byte from "
            f"{image_path} (apk={sha256(apk_gzip)}, export={sha256(exported_gzip)})"
        )

    expected = gunzip(str(image_path), exported_gzip)
    expected_sha = sha256(expected)
    for boot_path in boot_paths:
        actual = boot_inner_kernel(boot_path)
        if actual != expected:
            fail(
                f"{boot_path}: inner kernel {sha256(actual)} differs from "
                f"APK/rootfs kernel {expected_sha}"
            )
    print(
        f"kernel artifact parity passed: Image sha256={expected_sha}; "
        f"APK/rootfs + {len(boot_paths)} boot images"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
