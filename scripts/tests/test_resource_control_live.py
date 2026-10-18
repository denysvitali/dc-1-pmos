#!/usr/bin/env python3
"""Optional bounded live check in a disposable systemd service."""
import argparse
import errno
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time


def inside():
    group = next(line[3:] for line in Path('/proc/self/cgroup').read_text().splitlines()
                 if line.startswith('0::'))
    assert '/dc1-resource-check-' in group, 'refusing to test outside the disposable unit'
    root = Path('/sys/fs/cgroup') / group.lstrip('/')
    values = {name: (root / name).read_text().strip() for name in
              ('cpu.weight', 'cpu.max', 'pids.max', 'memory.max', 'io.max')}
    assert values['cpu.weight'] == '20', values
    assert values['cpu.max'] == '20000 100000', values
    assert values['pids.max'] == '8', values
    assert values['memory.max'] == str(64 * 1024 * 1024), values
    assert 'rbps=10485760' in values['io.max'], values
    children = []
    refused = False
    try:
        for _ in range(12):
            try:
                child = os.fork()
            except OSError as error:
                assert error.errno == errno.EAGAIN, error
                refused = True
                break
            if child == 0:
                time.sleep(5)
                os._exit(0)
            children.append(child)
        assert refused, 'kernel did not enforce the task limit'
        assert int(dict(line.split() for line in (root / 'pids.events').read_text().splitlines())['max']) > 0
    finally:
        for child in children:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(child, 0)
    print(json.dumps({'passed': True, 'settings': values,
                      'forks_before_limit': len(children), 'task_limit_enforced': refused}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--device', type=Path)
    args = parser.parse_args()
    if args.inside:
        inside()
        return
    available = set(Path('/sys/fs/cgroup/cgroup.controllers').read_text().split())
    missing = {'cpu', 'io', 'memory', 'pids'} - available
    if missing:
        print('Unavailable controllers; boot the candidate kernel first: ' + ', '.join(sorted(missing)))
        sys.exit(77)
    if not args.execute:
        print('Controllers available; pass --execute --device ROOT_BLOCK_DEVICE for the isolated enforcement check')
        return
    if os.geteuid() != 0 or not args.device or not stat.S_ISBLK(args.device.stat().st_mode):
        parser.error('--execute requires root and an explicit block device')
    command = ['systemd-run', '--quiet', '--wait', '--pipe', '--collect',
               '--unit=dc1-resource-check-' + str(os.getpid()),
               '-p', 'CPUWeight=20', '-p', 'CPUQuota=20%', '-p', 'CPUQuotaPeriodSec=100ms',
               '-p', 'TasksMax=8', '-p', 'MemoryMax=64M', '-p', 'RuntimeMaxSec=20',
               '-p', f'IOReadBandwidthMax={args.device.resolve()} 10M',
               sys.executable, str(Path(__file__).resolve()), '--inside']
    subprocess.run(command, check=True, timeout=30)


if __name__ == '__main__':
    main()
