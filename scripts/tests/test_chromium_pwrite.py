#!/usr/bin/env python3
"""Run actual positional writes with the rejected syscall trapped by seccomp."""
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'pmaports/device/testing/device-daylight-jagar/dc1-chromium-pwrite.c'


def no_core():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


with tempfile.TemporaryDirectory(prefix='dc1-pwrite-') as directory:
    directory = Path(directory)
    library = directory / 'compat.so'
    probe = directory / 'probe'
    compiler = os.environ.get('CC', 'cc')
    common = [compiler, '-O2', '-Wall', '-Wextra', '-Werror', '-pthread']
    subprocess.run(common + ['-shared', '-fPIC', str(SOURCE), '-o', str(library)], check=True)
    subprocess.run(common + [str(Path(__file__).with_name('chromium-pwrite-probe.c')),
                             '-o', str(probe)], check=True)
    control = subprocess.run([str(probe), 'negative-control'], preexec_fn=no_core)
    assert control.returncode == -signal.SIGSYS, control.returncode
    subprocess.run([str(probe)], env=dict(os.environ, LD_PRELOAD=str(library)),
                   preexec_fn=no_core, check=True)
