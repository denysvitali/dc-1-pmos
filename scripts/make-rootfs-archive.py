#!/usr/bin/env python3
"""Create a normalized, credential-free rootfs archive without mounting it."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
from pathlib import Path
import stat
import tarfile


FORBIDDEN_NAMES = {
    "authorized_keys",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "id_rsa",
    "wifi.conf",
    "wifi.txt",
    "wpa_supplicant.conf",
}
PRIVATE_MARKERS = (
    b"BEGIN OPENSSH PRIVATE KEY",
    b"BEGIN PRIVATE KEY",
    b"BEGIN RSA PRIVATE KEY",
    b"BEGIN EC PRIVATE KEY",
)
# Packaged files whose name collides with a forbidden credential name but
# whose content is fixed upstream policy, not configuration. Exact paths only.
ALLOWED_PACKAGED_PATHS = {
    "usr/share/dbus-1/system.d/wpa_supplicant.conf",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def paths_below(root: Path) -> list[Path]:
    paths: list[Path] = []
    for directory, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        dirnames.sort()
        filenames.sort()
        base = Path(directory)
        paths.extend(base / name for name in dirnames)
        paths.extend(base / name for name in filenames)
    return sorted(paths, key=lambda path: os.fsencode(path.relative_to(root)))


def verify_safe(root: Path, paths: list[Path]) -> None:
    for path in paths:
        relative = path.relative_to(root)
        if relative.as_posix() in ALLOWED_PACKAGED_PATHS:
            continue
        if path.name in FORBIDDEN_NAMES or ".ssh" in relative.parts:
            raise SystemExit(f"credential-like path in rootfs: {relative}")
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode) and path.stat().st_size <= 16 * 1024 * 1024:
            data = path.read_bytes()
            # Packaged binaries legitimately embed PEM banners: ELF
            # format-string constants (ssh-keygen, libcrypto), file(1)'s
            # magic database, and the like. A leaked key is a text file,
            # so binary content is out of scope; names are checked above.
            if data[:4] == b"\x7fELF" or b"\x00" in data[:8192]:
                continue
            if any(marker in data for marker in PRIVATE_MARKERS):
                raise SystemExit(f"private-key marker in rootfs: {relative}")


def tar_info(path: Path, root: Path, epoch: int) -> tarfile.TarInfo:
    relative = path.relative_to(root)
    info = tarfile.TarInfo(relative.as_posix())
    status = path.lstat()
    info.mode = stat.S_IMODE(status.st_mode)
    info.uid = status.st_uid
    info.gid = status.st_gid
    info.uname = ""
    info.gname = ""
    info.mtime = epoch
    if stat.S_ISDIR(status.st_mode):
        info.type = tarfile.DIRTYPE
    elif stat.S_ISLNK(status.st_mode):
        info.type = tarfile.SYMTYPE
        info.linkname = os.readlink(path)
    elif stat.S_ISREG(status.st_mode):
        info.type = tarfile.REGTYPE
        info.size = status.st_size
    elif stat.S_ISCHR(status.st_mode):
        info.type = tarfile.CHRTYPE
        info.devmajor = os.major(status.st_rdev)
        info.devminor = os.minor(status.st_rdev)
    elif stat.S_ISBLK(status.st_mode):
        info.type = tarfile.BLKTYPE
        info.devmajor = os.major(status.st_rdev)
        info.devminor = os.minor(status.st_rdev)
    elif stat.S_ISFIFO(status.st_mode):
        info.type = tarfile.FIFOTYPE
    else:
        raise SystemExit(f"unsupported rootfs file type: {relative}")
    return info


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--epoch", required=True, type=int)
    args = parser.parse_args()

    root = args.source.resolve(strict=True)
    if root == Path("/") or str(root).startswith("/dev/"):
        raise SystemExit(f"refusing unsafe source: {root}")
    if args.archive.exists() or args.inventory.exists():
        raise SystemExit("refusing to overwrite rootfs outputs")

    paths = paths_below(root)
    verify_safe(root, paths)

    with args.inventory.open("x", encoding="utf-8", newline="\n") as inventory:
        inventory.write("type\tmode\tuid\tgid\tsize\tsha256-or-target\tpath\n")
        for path in paths:
            status = path.lstat()
            relative = path.relative_to(root).as_posix()
            if stat.S_ISREG(status.st_mode):
                kind, identity = "file", sha256(path)
            elif stat.S_ISDIR(status.st_mode):
                kind, identity = "dir", "-"
            elif stat.S_ISLNK(status.st_mode):
                kind, identity = "symlink", os.readlink(path)
            else:
                kind, identity = "special", "-"
            inventory.write(
                f"{kind}\t{stat.S_IMODE(status.st_mode):04o}\t{status.st_uid}\t"
                f"{status.st_gid}\t{status.st_size}\t{identity}\t{relative}\n"
            )

    with args.archive.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                for path in paths:
                    info = tar_info(path, root, args.epoch)
                    if info.isreg():
                        with path.open("rb") as stream:
                            archive.addfile(info, stream)
                    else:
                        archive.addfile(info)


if __name__ == "__main__":
    main()
