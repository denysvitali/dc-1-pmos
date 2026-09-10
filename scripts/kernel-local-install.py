#!/usr/bin/env python3
"""Guarded local kernel update, using the installed A/B deployment tools."""
from __future__ import annotations

import fcntl
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zlib

BASE = Path('/var/lib/dc1/local-kernel')
STATE = BASE / 'pending.json'
FLAVOR = 'postmarketos-mediatek-mt6789'
PACKAGE = 'linux-' + FLAVOR


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def banner(kernel):
    # linux_banner can occur twice (including IKHEAD); ignore the printk
    # format string and require one distinct numeric build identity.
    found = set(re.findall(rb'Linux version [0-9][^\x00\n]+', kernel))
    require(len(found) == 1, 'kernel has no unique build banner')
    return found.pop().decode()


def unpack(data):
    require(len(data) >= 4096 and data[:8] == b'ANDROID!', 'not an Android boot image')
    k, r, osv, hs = struct.unpack_from('<4I', data, 8)
    require(struct.unpack_from('<I', data, 40)[0] == 4 and hs == 1584,
            'boot header must be v4')
    require(osv == 0x1800017B and struct.unpack_from('<I', data, 1580)[0] == 4096,
            'unexpected OS version/signature size')
    align = lambda n: (n + 4095) & ~4095
    roff = 4096 + align(k)
    soff = roff + align(r)
    end = soff + 4096
    require(0 < k < 64*1024*1024 and r > 0 and end <= len(data), 'invalid boot lengths')
    payload = gzip.decompress(data[4096:4096+k])
    require(len(payload) >= 80 and payload[56:60] == b'ARM\x64', 'invalid arm64 payload')
    doff, dlen, koff, klen = struct.unpack_from('<4I', payload, 64)
    require(80 <= doff < doff+dlen <= koff and koff+klen == len(payload) and klen > 0,
            'invalid dtbswap table')
    require(payload[doff:doff+4] == b'\xd0\x0d\xfe\xed', 'missing dtbswap FDT')
    ramdisk, signature = data[roff:roff+r], data[soff:end]
    require(ramdisk[:4] == b'\x02\x21\x4c\x18' and signature[:4] == b'AVB0',
            'invalid ramdisk/signature')
    return payload, koff, ramdisk, signature, end


def member(apk, name):
    with tarfile.open(apk, 'r:*') as archive:
        stream = archive.extractfile(name)
        require(stream is not None, 'missing package member: ' + name)
        return stream.read()


def check_config(config, requirements):
    enabled = set(config.decode().splitlines())
    wanted = {s for s in requirements.splitlines() if s.startswith('CONFIG_')}
    require(wanted and wanted <= enabled, 'missing built-in storage settings: ' + str(wanted-enabled))


def devices():
    result = {}
    for uevent in Path('/sys/class/block').glob('*/uevent'):
        info = dict(line.split('=', 1) for line in uevent.read_text().splitlines() if '=' in line)
        name = info.get('PARTNAME', '')
        if name not in ('boot_a', 'boot_b'):
            continue
        require(name not in result, 'ambiguous GPT name ' + name)
        sectors = int((uevent.parent/'size').read_text())
        require(16384 <= sectors <= 2097152, 'unexpected boot partition size')
        result[name] = Path('/dev')/info['DEVNAME']
    require(len(result) == 2, 'both boot partitions must resolve by GPT name')
    return result


def boot_read(device):
    with device.open('rb') as stream:
        header = stream.read(4096)
        require(header[:8] == b'ANDROID!', 'boot target magic mismatch')
        k, r = struct.unpack_from('<II', header, 8)
        size = 8192 + ((k+4095)&~4095) + ((r+4095)&~4095)
        require(8192 < size <= 64*1024*1024, 'implausible boot size')
        data = header + stream.read(size-4096)
    unpack(data)
    return data


def slot_status():
    text = subprocess.check_output(['dc1-slotctl', 'status'], text=True)
    selected = re.search(r'active=([ab])', text)
    slots = re.findall(r'slot ([ab]): pri=(\d+) tries=(\d+) ok=(\d+)', text)
    require(selected and len(slots) == 2, 'unreadable A/B state')
    return selected[1], {s: tuple(map(int, (p, t, o))) for s, p, t, o in slots}, text


def installed_package_checksum():
    for entry in Path('/lib/apk/db/installed').read_text().split('\n\n'):
        fields = dict(line.split(':', 1) for line in entry.splitlines() if ':' in line)
        if fields.get('P') == PACKAGE:
            return fields['C']
    raise RuntimeError('kernel package not installed')


def control_checksum(apk):
    data = apk.read_bytes()
    # Signed APK v2: signature gzip member, then control gzip member.
    first = zlib.decompressobj(31)
    first.decompress(data)
    control = first.unused_data
    require(control, 'missing APK control stream')
    second = zlib.decompressobj(31)
    second.decompress(control)
    compressed = control[:len(control)-len(second.unused_data)]
    return 'Q1'+base64.b64encode(hashlib.sha1(compressed).digest()).decode()


def install_apk(apk, keys, rollback=False):
    # Suppress the release-download trigger; deploy the local image explicitly.
    args = ['apk', '--keys-dir', str(keys), '--scripts=no']
    if rollback:
        # This cached package was authenticated against the installed APK
        # database before staging; CI's ephemeral package key is not retained.
        args.append('--allow-untrusted')
    run(*args, 'add', '--allow-downgrades', str(apk))
    release = member(apk, 'usr/share/kernel/'+FLAVOR+'/kernel.release').decode().strip()
    require(re.fullmatch(r'[A-Za-z0-9._+-]+', release), 'invalid kernel release')
    run('depmod', '-a', release)


def save_state(state):
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2)+'\n')
    tmp.replace(STATE)
    os.sync()


def card_identity():
    for device in sorted(Path('/dev').glob('mmcblk*')):
        if not re.fullmatch(r'mmcblk\d+(p\d+)?', device.name):
            continue
        result = subprocess.run(['blkid', '-o', 'export', str(device)], capture_output=True, text=True)
        fields = dict(s.split('=', 1) for s in result.stdout.splitlines() if '=' in s)
        if result.returncode == 0 and fields.get('TYPE') in ('vfat', 'exfat', 'ext4') and fields.get('UUID'):
            return dict(uuid=fields['UUID'], filesystem=fields['TYPE'])
    return None


def check_card(card):
    if not card:
        return 'no card filesystem recorded at installation'
    resolved = subprocess.run(['blkid', '-U', card['uuid']], capture_output=True, text=True)
    device = resolved.stdout.strip()
    if resolved.returncode or not re.fullmatch(r'/dev/mmcblk\d+(p\d+)?', device):
        return 'recorded card absent; mount check skipped'
    mounted = subprocess.run(['findmnt', '-rn', '-S', device, '-o', 'FSTYPE'], capture_output=True, text=True)
    if card['filesystem'] in mounted.stdout.split():
        return 'SD card already mounted with '+card['filesystem']
    directory = tempfile.mkdtemp(prefix='dc1-sd-check-', dir='/run')
    options = 'ro,noload' if card['filesystem'] == 'ext4' else 'ro'
    try:
        run('mount', '-t', card['filesystem'], '-o', options, device, directory)
        run('umount', directory)
    finally:
        os.rmdir(directory)
    return 'SD-card read-only '+card['filesystem']+' mount passed'


def confirm():
    if not STATE.exists():
        return
    state = json.loads(STATE.read_text())
    require(state['boot_id'] != Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'confirmation requires a new boot')
    current = Path('/proc/version').read_text().strip()
    directory = Path(state['directory'])
    if current == state['old_banner']:
        require(sha((directory/'previous.apk').read_bytes()) == state['previous_sha256'],
                'rollback package changed')
        install_apk(directory/'previous.apk', directory/'keys', rollback=True)
        no_update = Path('/var/lib/dc1/no-auto-update')
        if not no_update.exists():
            no_update.write_text('Local kernel fallback: review '+str(directory)+' before re-enabling updates.\n')
        result = 'FALLBACK: restored previous kernel package; automatic updates paused'
    else:
        require(current == state['new_banner'], 'running build is neither candidate nor fallback')
        selected, slots, _ = slot_status()
        require(selected == state['target'], 'selected slot disagrees with running candidate')
        data = boot_read(devices()['boot_'+selected])
        payload, offset, *_ = unpack(data)
        require(sha(payload[offset:]) == state['kernel_sha256'], 'boot kernel hash mismatch')
        require(sha(gzip.decompress(Path('/boot/vmlinuz').read_bytes())) == state['kernel_sha256'],
                'installed kernel differs from running candidate')
        filesystems = Path('/proc/filesystems').read_text().split()
        require(all(fs in filesystems for fs in ('vfat', 'exfat', 'ext4')), 'storage filesystem missing')
        for _ in range(30):
            if Path('/sys/class/mmc_host/mmc0').exists():
                break
            time.sleep(1)
        require(Path('/sys/class/mmc_host/mmc0').exists(), 'SD-card host did not probe')
        card_result = check_card(state.get('card'))
        run('dc1-slotctl', 'mark-successful', selected)
        result = 'CONFIRMED: candidate kernel, installed package, boot slot and SD filesystems match; '+card_result
    (directory/'RESULT').write_text(result+'\n')
    (BASE/'last-result').write_text(result+'\n'+str(directory)+'\n')
    STATE.unlink()
    os.sync()
    print(result)


def install(repo, apk, keydir):
    require(not STATE.exists(), 'an earlier local kernel update is still pending')
    require(os.uname().machine == 'aarch64', 'local install requires the DC-1')
    devs = devices()
    boots = {slot: boot_read(devs['boot_'+slot]) for slot in 'ab'}
    current = Path('/proc/version').read_text().strip()
    matching = [slot for slot, data in boots.items() if banner(unpack(data)[0][unpack(data)[1]:]) == current]
    require(len(matching) == 1, 'running build does not uniquely identify a boot slot')
    active = matching[0]
    target = 'b' if active == 'a' else 'a'
    selected, slots, bcb = slot_status()
    require(selected == active and slots[active][0] > 0 and slots[active][2] == 1,
            'running slot must be selected and proven')
    old_payload, offset, ramdisk, signature, _ = unpack(boots[active])
    require(gzip.decompress(Path('/boot/vmlinuz').read_bytes()) == old_payload[offset:],
            'installed kernel does not match running slot; reconcile before updating')
    require(signature == (repo/'boot/boot-signature.bin').read_bytes(), 'boot signature provenance mismatch')
    # Require the audited deploy implementation; do not silently use a drifted tool.
    require(Path('/usr/libexec/dc1-boot-sync').read_bytes() ==
            (repo/'pmaports/device/testing/device-daylight-jagar/dc1-boot-sync').read_bytes(),
            'installed boot deployment helper differs from repository')
    directory = BASE / time.strftime('%Y%m%d-%H%M%S')
    directory.mkdir(mode=0o700)
    apk_copy = directory/apk.name
    shutil.copyfile(apk, apk_copy)
    keys = directory/'keys'
    shutil.copytree('/etc/apk/keys', keys, symlinks=False)
    for key in keydir.glob('*.pub'):
        dest = keys/key.name
        require(not dest.exists() or dest.read_bytes() == key.read_bytes(), 'APK key name collision')
        shutil.copyfile(key, dest)
    run('apk', '--keys-dir', str(keys), 'verify', str(apk_copy))
    info = member(apk_copy, '.PKGINFO').decode()
    require('pkgname = '+PACKAGE+'\n' in info and 'arch = aarch64\n' in info, 'wrong package identity')
    kernel_gz = member(apk_copy, 'boot/vmlinuz')
    kernel = gzip.decompress(kernel_gz)
    require(kernel[56:60] == b'ARM\x64', 'new kernel is not an arm64 Image')
    new_banner = banner(kernel)
    require(new_banner != current, 'increment pkgrel: build identity must differ from running kernel')
    check_config(member(apk_copy, 'usr/share/kernel/'+FLAVOR+'/config'),
                 (repo/'pmaports/device/testing'/PACKAGE/'sdcard.config').read_text())
    # Preserve the boot-proven stub, DTB, ramdisk and signature. Only replace
    # the kernel and the two payload size fields. This is a kernel-only updater.
    payload = bytearray(old_payload[:offset] + kernel)
    struct.pack_into('<I', payload, 76, len(kernel))
    struct.pack_into('<Q', payload, 16, len(payload))
    (directory/'payload.gz').write_bytes(gzip.compress(payload, mtime=0))
    (directory/'ramdisk.lz4').write_bytes(ramdisk)
    (directory/'Image.gz').write_bytes(kernel_gz)
    image = directory/'jagar-boot.img'
    run('sh', str(repo/'boot/repack-boot.sh'), str(directory/'payload.gz'),
        str(directory/'ramdisk.lz4'), str(image))
    produced = image.read_bytes()
    p, o, r, s, _ = unpack(produced)
    require(p[o:] == kernel and r == ramdisk and s == signature, 'repacked image parity failed')
    run(str(repo/'boot/mkboot/mkboot'), 'verify', str(image))
    run('python3', str(repo/'scripts/verify-kernel-artifacts.py'), str(apk_copy),
        str(directory/'Image.gz'), str(image))
    # Match the old control archive to APK's installed database checksum. The
    # signed release index authenticated it at installation; its ephemeral
    # package-signing public key is generally not installed on the device.
    previous = None
    installed_checksum = installed_package_checksum()
    for candidate in Path('/var/cache/apk').glob(PACKAGE+'-*.apk'):
        if control_checksum(candidate) == installed_checksum and \
                member(candidate, 'boot/vmlinuz') == Path('/boot/vmlinuz').read_bytes():
            previous = candidate
            break
    require(previous is not None, 'no cached rollback APK matching installed metadata and running kernel')
    shutil.copyfile(previous, directory/'previous.apk')
    require(control_checksum(directory/'previous.apk') == installed_checksum,
            'rollback package changed while staging')
    run('apk', '--allow-untrusted', 'verify', str(directory/'previous.apk'))
    for slot, data in boots.items():
        (directory/('boot_'+slot+'.img')).write_bytes(data)
    (directory/'bcb-before.txt').write_text(bcb)
    (directory/'SHA256SUMS').write_text(sha(produced)+'  jagar-boot.img\n')
    state = dict(directory=str(directory), target=target, old_banner=current,
                 new_banner=new_banner, kernel_sha256=sha(kernel),
                 previous_sha256=sha((directory/'previous.apk').read_bytes()),
                 card=card_identity(),
                 boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
    # Install a boot-time verifier before the package or any slot is changed.
    helper = BASE/'confirm.py'
    shutil.copyfile(__file__, helper)
    unit = Path('/etc/systemd/system/dc1-local-kernel-confirm.service')
    unit.write_text('[Unit]\nDescription=Confirm local DC-1 kernel or restore fallback package\n'
                    'After=local-fs.target\nBefore=dc1-boot-sync.service dc1-update.service\n'
                    'ConditionPathExists='+str(STATE)+'\n[Service]\nType=oneshot\n'
                    'ExecStart=/usr/bin/python3 '+str(helper)+' confirm\n'
                    '[Install]\nWantedBy=multi-user.target\n')
    # A failed confirmation must not be bypassed by the normal boot-sync
    # service marking the merely selected slot successful.
    for service in ('dc1-boot-sync.service', 'dc1-update.service'):
        dropin = Path('/etc/systemd/system')/(service+'.d')
        dropin.mkdir(exist_ok=True)
        (dropin/'local-kernel-confirm.conf').write_text(
            '[Unit]\nRequires=dc1-local-kernel-confirm.service\n'
            'After=dc1-local-kernel-confirm.service\n')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', unit.name)
    for service in ('dc1-boot-sync.service', 'dc1-update.service'):
        status = subprocess.run(['systemctl', 'is-active', service], capture_output=True, text=True)
        require(status.stdout.strip() in ('inactive', 'failed'), service+' is busy')
    # Runtime masks end on reboot; prevent scheduled updates racing this transaction.
    run('systemctl', 'mask', '--runtime', 'dc1-boot-sync.service', 'dc1-update.service')
    require(slot_status()[2] == bcb and all(boot_read(devs['boot_'+s]) == boots[s] for s in 'ab'),
            'boot state changed during preparation')
    require(installed_package_checksum() == installed_checksum,
            'installed package changed during preparation')
    save_state(state)
    install_apk(apk_copy, keys)
    require(Path('/boot/vmlinuz').read_bytes() == kernel_gz, 'APK installation mismatch')
    # Existing guarded deployer verifies hash, kernel parity, readback and arms
    # exactly one try. Its best-effort exit is NOT accepted as proof below.
    env = dict(os.environ, DC1_URL_BASE=directory.as_uri())
    run('/usr/libexec/dc1-boot-sync', '--deploy', env=env)
    after, states, text = slot_status()
    require(after == target and states[target] == (15, 1, 0) and states[active][2] == 1,
            'candidate was not armed with a proven fallback')
    require(boot_read(devs['boot_'+target]) == produced, 'candidate partition readback mismatch')
    require(boot_read(devs['boot_'+active]) == boots[active], 'fallback image changed')
    (directory/'bcb-after.txt').write_text(text)
    (directory/'RESULT').write_text('STAGED: verified package/image; target '+target+' armed for one try\n')
    os.sync()
    print('Verified installation; fallback '+active+' preserved. Records: '+str(directory))


def main():
    require(os.geteuid() == 0, 'run installer through sudo')
    os.umask(0o077)
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (BASE/'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if sys.argv[1:] == ['confirm']:
            confirm()
        elif len(sys.argv) == 5 and sys.argv[1] == 'install':
            install(*(Path(p).resolve() for p in sys.argv[2:]))
        else:
            raise RuntimeError('usage: kernel-local-install.py install REPO APK KEYDIR | confirm')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit('local kernel update stopped: '+str(exc))
