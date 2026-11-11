#!/usr/bin/env python3
"""Offline integrity tests for the Alpine apk bootstrap."""
import base64
import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bootstrap-alpine-apk.py'
spec = importlib.util.spec_from_file_location('bootstrap', SCRIPT)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def tar(entries):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w') as archive:
        for name, data in entries:
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    return out.getvalue()


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.keys = self.work / 'keys'
        self.keys.mkdir()
        self.private = self.work / 'key'
        self.public = self.keys / 'test.rsa.pub'
        subprocess.run(['openssl', 'genrsa', '-out', str(self.private), '2048'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        subprocess.run(['openssl', 'rsa', '-in', str(self.private), '-pubout',
                        '-out', str(self.public)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
        self.old_keys = bootstrap.KEYS
        bootstrap.KEYS = self.keys
        self.addCleanup(setattr, bootstrap, 'KEYS', self.old_keys)

    def signed_index(self, text):
        body = gzip.compress(tar([('APKINDEX', text.encode())]))
        sig = subprocess.run(['openssl', 'dgst', '-sha1', '-sign', str(self.private)],
                             input=body, stdout=subprocess.PIPE, check=True).stdout
        return gzip.compress(tar([('.SIGN.RSA.test.rsa.pub', sig)])) + body

    def package(self):
        data = gzip.compress(tar([('sbin/apk.static', b'authenticated executable')]))
        info = ('datahash = ' + hashlib.sha256(data).hexdigest() + '\n').encode()
        control = gzip.compress(tar([('.PKGINFO', info)]))
        signature = gzip.compress(tar([('.SIGN.RSA.test.rsa.pub', b'signature')]))
        return signature + control + data, hashlib.sha1(control).digest()

    def test_verified_index_and_package(self):
        package, identity = self.package()
        checksum = 'Q1' + base64.b64encode(identity).decode()
        raw = self.signed_index(f'C:{checksum}\nP:apk-tools-static\nV:3.9-r4\nA:x86_64\n\n')
        index = bootstrap.verify_index(raw, self.work)
        version, digest = bootstrap.select(index, 'x86_64')
        self.assertEqual(version, '3.9-r4')
        self.assertEqual(bootstrap.extract_binary(package, digest), b'authenticated executable')

    def test_bad_index_signature_and_unknown_key_fail(self):
        raw = self.signed_index('P:apk-tools-static\n')
        with self.assertRaises(ValueError):
            bootstrap.verify_index(raw[:-1] + bytes([raw[-1] ^ 1]), self.work)
        self.public.unlink()
        with self.assertRaisesRegex(ValueError, 'untrusted'):
            bootstrap.verify_index(raw, self.work)

    def test_control_and_data_corruption_fail(self):
        package, identity = self.package()
        with self.assertRaisesRegex(ValueError, 'identity'):
            bootstrap.extract_binary(package, b'\0' * 20)
        with self.assertRaisesRegex(ValueError, 'data hash'):
            bootstrap.extract_binary(package[:-1] + bytes([package[-1] ^ 1]), identity)

    def test_reject_unsafe_or_duplicate_versions(self):
        checksum = 'Q1' + base64.b64encode(b'x' * 20).decode()
        entry = f'C:{checksum}\nP:apk-tools-static\nV:3-r0\nA:x86_64\n\n'
        with self.assertRaises(ValueError):
            bootstrap.select(entry + entry, 'x86_64')
        with self.assertRaises(ValueError):
            bootstrap.select(entry.replace('3-r0', '../bad'), 'x86_64')
        with self.assertRaises(ValueError):
            bootstrap.select(entry, 'aarch64')

    def test_truncated_gzip_rejected(self):
        package, identity = self.package()
        with self.assertRaises(ValueError):
            bootstrap.extract_binary(package[:20], identity)


class ApkInvocationTest(unittest.TestCase):
    """Execute each builder's actual apk command with fake uid/apk inputs."""

    def run_command(self, builder, uid, exit_code=0):
        source = (SCRIPT.parent.parent / builder).read_text()
        start = source.index('set --\nif [ "$(id -u)" -ne 0 ]; then')
        end_marker = ('rm -rf "$bootstrap"' if builder == 'installer/build.sh'
                      else "printf 'file://")
        command = source[start:source.index(end_marker, start)]
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            apk = work / 'apk'
            log = work / 'arguments'
            apk.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$APK_LOG"\n'
                           'exit "$APK_EXIT"\n')
            apk.chmod(0o755)
            env = dict(os.environ, APK=str(apk), APK_LOG=str(log),
                       APK_EXIT=str(exit_code), TEST_UID=str(uid),
                       DL=tmp, HERE=tmp, bootstrap=tmp, verify_root=tmp)
            result = subprocess.run(
                ['sh', '-eu', '-c',
                 'id() { printf "%s\\n" "$TEST_UID"; }\n'
                 'fatal() { printf "%s\\n" "$*" >&2; exit 1; }\n' + command],
                env=env, text=True, capture_output=True)
            return result, log.read_text().splitlines()

    def test_root_and_unprivileged_invocations(self):
        for builder in ('installer/build.sh', 'scripts/build-apkindex.sh'):
            for uid in (0, 1000):
                with self.subTest(builder=builder, uid=uid):
                    result, args = self.run_command(builder, uid)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual('--usermode' in args, uid != 0)
                    for required in ('--root', '--keys-dir', '--repositories-file',
                                     '--no-cache', 'add', '--initdb'):
                        self.assertIn(required, args)
                    self.assertNotIn('--allow-untrusted', args)
                    if builder == 'installer/build.sh':
                        self.assertIn('--no-scripts', args)
                        self.assertEqual(args[args.index('--arch') + 1], 'aarch64')
                        for package in ('busybox-static', 'musl', 'curl', 'zstd',
                                        'wpa_supplicant', 'dropbear', 'e2fsprogs',
                                        'e2fsprogs-extra', 'ca-certificates-bundle'):
                            self.assertIn(package, args)

    def test_apk_failure_is_fatal(self):
        for builder in ('installer/build.sh', 'scripts/build-apkindex.sh'):
            for uid in (0, 1000):
                with self.subTest(builder=builder, uid=uid):
                    result, _ = self.run_command(builder, uid, exit_code=42)
                    self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
