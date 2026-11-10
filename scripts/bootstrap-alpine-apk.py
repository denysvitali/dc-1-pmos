#!/usr/bin/env python3
"""Bootstrap apk.static from a freshly signed Alpine edge index.

Only the verified binary is extracted. The APK v2 index authenticates the
SHA-1 identity of its compressed control member, which authenticates the
SHA-256 of the compressed data member. No downloaded code runs before both
checks succeed. Trust anchors are Alpine's public package-signing keys.
"""
import base64
import hashlib
import io
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile
import urllib.request
import zlib

MIRROR = 'https://dl-cdn.alpinelinux.org/alpine/edge/main'
KEYS = Path(__file__).resolve().parent / 'alpine-keys'


def fail(message):
    raise ValueError(message)


def download(url, limit):
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        fail('download exceeds size limit: ' + url)
    return data


def member(data, max_output):
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    plain = decoder.decompress(data, max_output + 1)
    if len(plain) > max_output or not decoder.eof:
        fail('invalid or oversized gzip member')
    used = len(data) - len(decoder.unused_data)
    return data[:used], plain, decoder.unused_data


def tar_files(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        result = {}
        for item in archive:
            if not item.isfile() or item.name in result:
                fail('unexpected or duplicate archive entry: ' + item.name)
            f = archive.extractfile(item)
            result[item.name] = f.read()
        return result


def verify_index(raw, work):
    _, sig_tar, rest = member(raw, 128 * 1024)
    signatures = tar_files(sig_tar)
    if len(signatures) != 1:
        fail('index must have exactly one signature')
    name, signature = next(iter(signatures.items()))
    prefix = '.SIGN.RSA.'
    if not name.startswith(prefix) or '/' in name or '\\' in name:
        fail('unsupported index signature')
    key = KEYS / name[len(prefix):]
    if not key.is_file():
        fail('untrusted Alpine signing key: ' + name)
    sigfile = work / 'signature'
    sigfile.write_bytes(signature)
    result = subprocess.run(['openssl', 'dgst', '-sha1', '-verify', str(key),
                             '-signature', str(sigfile)], input=rest,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        fail('Alpine index signature verification failed')
    _, plain, trailing = member(rest, 32 * 1024 * 1024)
    if trailing:
        fail('unexpected index gzip members')
    files = tar_files(plain)
    if 'APKINDEX' not in files:
        fail('missing APKINDEX')
    return files['APKINDEX'].decode('utf-8')


def select(index, arch):
    matches = []
    for block in index.split('\n\n'):
        fields = {}
        for line in block.splitlines():
            if len(line) >= 2 and line[1] == ':':
                fields.setdefault(line[:1], []).append(line[2:])
        if fields.get('P') != ['apk-tools-static']:
            continue
        if any(len(fields.get(k, [])) != 1 for k in ('V', 'A', 'C')):
            fail('malformed apk-tools-static index entry')
        version, architecture, checksum = (fields[k][0] for k in ('V', 'A', 'C'))
        if architecture != arch or not re.fullmatch(r'[A-Za-z0-9._+~-]+', version):
            fail('invalid apk-tools-static version or architecture')
        if not checksum.startswith('Q1'):
            fail('unsupported apk-tools-static checksum')
        digest = base64.b64decode(checksum[2:], validate=True)
        if len(digest) != 20:
            fail('invalid apk-tools-static checksum')
        matches.append((version, digest))
    if len(matches) != 1:
        fail('expected exactly one apk-tools-static index entry')
    return matches[0]


def extract_binary(raw, expected):
    _, _, rest = member(raw, 128 * 1024)  # package signature; index supplies identity
    control, plain, data = member(rest, 2 * 1024 * 1024)
    if hashlib.sha1(control).digest() != expected:
        fail('apk-tools-static control identity mismatch')
    info = tar_files(plain).get('.PKGINFO', b'').decode('utf-8')
    hashes = re.findall(r'^datahash = ([0-9a-f]{64})$', info, re.M)
    if len(hashes) != 1 or hashlib.sha256(data).hexdigest() != hashes[0]:
        fail('apk-tools-static data hash mismatch')
    _, payload, trailing = member(data, 32 * 1024 * 1024)
    if trailing:
        fail('unexpected APK gzip members')
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:') as archive:
        matches = [item for item in archive if item.name == 'sbin/apk.static']
        if len(matches) != 1 or not matches[0].isfile():
            fail('APK does not contain a unique regular apk.static')
        return archive.extractfile(matches[0]).read()


def main():
    if len(sys.argv) != 2:
        fail('usage: bootstrap-alpine-apk.py EMPTY_WORK_DIRECTORY')
    work = Path(sys.argv[1]).resolve()
    if not work.is_dir() or any(work.iterdir()):
        fail('bootstrap directory must exist and be empty')
    arch = platform.machine()
    if arch not in ('x86_64', 'aarch64'):
        fail('unsupported host architecture: ' + arch)
    base = f'{MIRROR}/{arch}'
    index = verify_index(download(base + '/APKINDEX.tar.gz', 8 * 1024 * 1024), work)
    version, identity = select(index, arch)
    raw = download(f'{base}/apk-tools-static-{version}.apk', 16 * 1024 * 1024)
    binary = extract_binary(raw, identity)
    output = work / 'apk.static'
    output.write_bytes(binary)
    output.chmod(0o755)
    print(output)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeError, zlib.error, tarfile.TarError) as exc:
        print('Alpine apk bootstrap failed:', exc, file=sys.stderr)
        sys.exit(1)
