#!/usr/bin/env python3
"""Check the split modules APK against the installed rootfs without extraction."""
from pathlib import Path, PurePosixPath
import sys
import tarfile

# Files that make up the module tree itself. These carry the driver code and
# must match byte for byte: a same-version APK that relinked a module, or whose
# firmware/overlay payload drifted, is exactly what this gate exists to catch.
DRIVER_SUFFIXES = ('.ko', '.ko.gz', '.ko.xz', '.ko.zst')

# depmod's binary indices are a derived, lossy view of the same data as the
# text files beside them, encoded in a layout specific to the kmod build that
# produced it. They must be present on both sides, but their bytes record which
# depmod ran, not which modules are installed.
BINARY_INDEX_SUFFIX = '.bin'


def index_records(data):
    """Semantic records of a kmod text index, independent of depmod's format.

    depmod output is not stable across kmod versions: comment headers appear and
    disappear, records are reordered, and alias patterns get normalized between
    the '-' and '_' spellings of the same wildcard. kmod matches aliases with
    '-' and '_' treated as equivalent, so those spellings are one alias; only a
    genuinely different pattern, or a different module, is real drift.
    """
    records = set()
    for raw in data.splitlines():
        line = raw.decode('utf-8', 'replace').strip()
        if not line or line.startswith('#'):
            continue
        fields = line.split()
        if fields[0] == 'alias' and len(fields) >= 3:
            # Normalize the wildcard pattern only. The target is a module path
            # where '-' and '_' are distinct characters.
            records.add('alias ' + ' '.join([fields[1].replace('_', '-')] + fields[2:]))
        else:
            records.add(' '.join(fields))
    return records


def compare(apk_data, installed, name):
    """Raise ValueError unless the two copies of `name` hold the same content."""
    rootfs_data = installed.read_bytes()
    if apk_data == rootfs_data:
        return
    base = PurePosixPath(name).name
    if not base.startswith('modules.'):
        raise ValueError(f'module package/rootfs mismatch: {name}')
    if base.endswith(BINARY_INDEX_SUFFIX):
        return
    apk_records = index_records(apk_data)
    rootfs_records = index_records(rootfs_data)
    if apk_records != rootfs_records:
        sample = sorted(apk_records ^ rootfs_records)[:3]
        raise ValueError(f'module index content mismatch: {name}: {sample}')


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
            compare(stream.read(), installed, name)
            if name.endswith(DRIVER_SUFFIXES):
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
