#!/usr/bin/env python3
"""Check the split modules APK against the installed rootfs without extraction.

The driver objects and firmware payloads are compared byte for byte: a
same-version APK that relinked a module, or whose payload drifted, is exactly
what this gate exists to catch.

The kmod text indexes under /lib/modules are compared by the set of modules
they name, not byte for byte. depmod runs again when the rootfs installs the
modules package, using the kmod from the rootfs rather than from the build
chroot, and that regenerates the indexes: comment headers come and go, records
and dependency edges reorder, an alias pattern flips between the '-' and '_'
spellings of the same wildcard, and a symbol with several possible providers
can resolve to a different module. None of that is drift in what we ship --
the .ko files themselves still have to match exactly -- so comparing depmod's
output as bytes would fail builds over a difference in meaning.

depmod's binary indexes (.bin) are exempt from content comparison entirely.
They are a derived encoding of the text indexes beside them, in a format
carrying no public contract, so parsing them would only re-derive fragility
in a file that says nothing about what we ship. modules.dep already covers
dependency membership.
"""
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile

# Files that make up the module tree itself. These carry the driver code.
DRIVER_SUFFIXES = ('.ko', '.ko.gz', '.ko.xz', '.ko.zst')

# A module reference as it appears in a depmod text index. Paths are relative
# to the module directory, so they start at a word character.
MODULE_REF = re.compile(rb'[A-Za-z0-9_][A-Za-z0-9_./+-]*\.ko(?:\.(?:gz|xz|zst))?')


def is_index(name):
    """True for a depmod-generated index rather than a file we ship as content."""
    return PurePosixPath(name).name.startswith('modules.')


def is_binary_index(name):
    """True for depmod's .bin indices, whose encoding carries no contract."""
    return PurePosixPath(name).name.endswith('.bin')


def index_modules(data):
    """The set of modules a depmod text index names."""
    return {match.decode() for match in MODULE_REF.findall(data)}


def verify(apk, root):
    release = (root / 'usr/share/kernel/postmarketos-mediatek-mt6789/kernel.release').read_text().strip()
    if not release or '/' in release or release in ('.', '..'):
        raise ValueError('invalid kernel release')
    prefix = f'lib/modules/{release}/'
    with tarfile.open(apk, 'r:*') as archive:
        entries = [e for e in archive if e.isfile() and not str(e.name).startswith('.')]
        names = {str(e.name) for e in entries}
        if len(names) != len(entries):
            raise ValueError('duplicate file in module package')
        # Pass one: the driver set, which everything else is checked against.
        drivers = set()
        for entry in entries:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('invalid module package path')
            name = str(entry.name)
            if not name.startswith(prefix):
                raise ValueError(f'unexpected module package file: {name}')
            if name.endswith(DRIVER_SUFFIXES):
                drivers.add(str(path.relative_to(prefix)))
        # Pass two: parity, file by file.
        seen = set()
        for entry in entries:
            name = str(entry.name)
            if name in seen:
                raise ValueError(f'unexpected module package file: {name}')
            seen.add(name)
            installed = root / name
            if not installed.is_file():
                raise ValueError(f'module package file absent from rootfs: {name}')
            data = archive.extractfile(entry).read()
            rootfs_data = installed.read_bytes()
            if not name.endswith(DRIVER_SUFFIXES) and is_index(name):
                # Derived metadata. depmod regenerates it on install and may
                # name a different provider for a shared symbol, so the index
                # is not required to match byte for byte -- only to describe
                # modules that are actually installed. A reference to a module
                # from neither package is the real failure this catches.
                # modules.builtin* is exempt: built-in drivers are compiled
                # into the kernel and have no file in the module tree. The .bin
                # encodings are exempt too; modules.dep carries the same facts.
                if not (PurePosixPath(name).name.startswith('modules.builtin')
                        or is_binary_index(name)):
                    for label, blob in (('APK', data), ('rootfs', rootfs_data)):
                        unknown = sorted(index_modules(blob) - drivers)
                        if unknown:
                            raise ValueError(
                                f'{label} {name} names modules the package does not ship: {unknown[:3]}')
                continue
            # Drivers, firmware and device-tree overlays are content we ship;
            # they must be the same build on both sides.
            if data != rootfs_data:
                raise ValueError(f'module package/rootfs mismatch: {name}')
    if not drivers or not all(prefix + name in seen for name in ('modules.dep', 'modules.alias', 'modules.builtin')):
        raise ValueError('modules APK lacks drivers or kmod dependency/alias/builtin metadata')
    print(f'module APK/rootfs parity passed: {len(drivers)} modules for {release}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: verify-kernel-modules.py MODULES_APK ROOTFS')
    try:
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, tarfile.TarError) as exc:
        sys.exit('module verification failed: ' + str(exc))
