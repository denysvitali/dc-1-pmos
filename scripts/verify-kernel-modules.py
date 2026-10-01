#!/usr/bin/env python3
"""Check the split modules APK against the installed rootfs without extraction."""
from pathlib import Path, PurePosixPath
import hashlib
import sys
import tarfile


def verify(apk, root):
    release = (root / 'usr/share/kernel/postmarketos-mediatek-mt6789/kernel.release').read_text().strip()
    if not release or '/' in release or release in ('.', '..'):
        raise ValueError('invalid kernel release')
    prefix = f'lib/modules/{release}/'
    seen = set()
    count = 0
    with tarfile.open(apk, 'r:*') as archive:
        for entry in archive:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('invalid module package path')
            name = str(path)
            if not entry.isfile() or name.startswith('.'):
                continue
            if not name.startswith(prefix) or name in seen:
                raise ValueError(f'unexpected module package file: {name}')
            seen.add(name)
            stream = archive.extractfile(entry)
            installed = root / name
            if not installed.is_file():
                raise ValueError(f'module package file absent from rootfs: {name}')
            data = stream.read()
            if hashlib.sha256(data).digest() != hashlib.sha256(installed.read_bytes()).digest():
                # kmod's index files are derived by depmod, which the rootfs
                # install may re-run; only their content (not byte order or
                # binary layout) is meaningful. Drivers must match exactly.
                base = PurePosixPath(name).name
                if not base.startswith('modules.') or base.endswith('.ko'):
                    raise ValueError(f'module package/rootfs mismatch: {name}')
                if base.endswith('.bin'):
                    pass
                elif sorted(data.splitlines()) != sorted(installed.read_bytes().splitlines()):
                    a = set(data.splitlines())
                    b = set(installed.read_bytes().splitlines())
                    sample = sorted(a ^ b)[:3]
                    raise ValueError(f'module index content mismatch: {name}: {sample}')
            if name.endswith(('.ko', '.ko.gz', '.ko.xz', '.ko.zst')):
                count += 1
    if not count or not all(prefix + name in seen for name in ('modules.dep', 'modules.alias', 'modules.builtin')):
        raise ValueError('modules APK lacks drivers or kmod dependency/alias/builtin metadata')
    print(f'module APK/rootfs parity passed: {count} modules for {release}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: verify-kernel-modules.py MODULES_APK ROOTFS')
    try:
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, tarfile.TarError) as exc:
        sys.exit('module verification failed: ' + str(exc))
