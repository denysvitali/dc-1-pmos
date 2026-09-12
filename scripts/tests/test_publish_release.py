#!/usr/bin/env python3
"""Offline release transactions: retention, retries, failure and alias ordering."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('publish', Path(__file__).parents[1]/'publish-release.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
SHA = 'a'*40


class FakePublisher(m.Publisher):
    def __init__(self, directory, number=10):
        super().__init__(directory, Path(directory)/'../notes.md', f'build-{number}', SHA, number)
        self.releases, self.refs, self.calls = {}, {}, []
        self.fail_asset = None

    def api(self, path):
        if path.startswith('releases/tags/'):
            r = self.releases.get(path.split('/')[-1])
            return None if r is None else dict(r, assets=[{'name': n} for n in r['files']])
        sha = self.refs.get(path.split('/')[-1])
        return None if sha is None else {'object': {'type': 'commit', 'sha': sha}}

    def gh(self, *args, missing=False):
        args = tuple(map(str, args))
        self.calls.append(args)
        if args[0] == 'api':
            self.refs['latest'] = self.sha
            return ''
        _, op, tag, *rest = args
        if op == 'create':
            self.releases[tag] = {'draft': True, 'target_commitish': self.sha, 'files': {}}
        elif op == 'upload':
            p = Path(rest[0])
            if p.name == self.fail_asset:
                raise RuntimeError('upload interrupted')
            self.releases[tag]['files'][p.name] = p.read_bytes()
        elif op == 'download':
            return self.releases[tag]['files'][rest[1]].decode()
        elif op == 'delete-asset':
            del self.releases[tag]['files'][rest[0]]
        elif op == 'edit':
            self.releases[tag]['draft'] = False
            self.refs.setdefault(tag, self.sha)
        else:
            raise AssertionError(args)
        return ''


class Releases(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root/'release'
        self.directory.mkdir()
        (self.root/'notes.md').write_text('notes')
        for n in ['APKINDEX.tar.gz','installer-boot.img','jagar-boot.img','kernel.apk']:
            (self.directory/n).write_text(n)
        (self.directory/'PROVENANCE').write_text(f'release_commit={SHA}\nrelease_tag=build-10\nbuild_number=10\n')
        self.sums()
        self.p = FakePublisher(self.directory)

    def sums(self):
        (self.directory/'SHA256SUMS').write_text(''.join(
            hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n'
            for p in sorted(self.directory.iterdir()) if p.name != 'SHA256SUMS'))

    def test_retained_then_latest_and_manifest_last(self):
        self.p.retained()
        self.assertFalse(self.p.releases['build-10']['draft'])
        self.assertNotIn('latest', self.p.releases)
        self.p.rolling()
        self.assertEqual(self.p.releases['latest']['files'], self.p.releases['build-10']['files'])
        uploads = [c for c in self.p.calls if c[:3] == ('release','upload','latest')]
        self.assertEqual(Path(uploads[-1][3]).name, 'SHA256SUMS')
        self.assertFalse(self.p.releases['latest']['draft'])

    def test_interrupted_draft_resumes_without_publication(self):
        self.p.fail_asset = 'installer-boot.img'
        with self.assertRaisesRegex(RuntimeError, 'interrupted'):
            self.p.retained()
        self.assertTrue(self.p.releases['build-10']['draft'])
        self.assertNotIn('latest', self.p.releases)
        self.p.fail_asset = None
        self.p.releases['build-10']['files']['stale.apk'] = b'old'
        self.p.retained()
        self.assertNotIn('stale.apk', self.p.releases['build-10']['files'])

    def test_published_rerun_does_no_writes(self):
        self.p.retained()
        self.p.calls.clear()
        self.p.retained()
        self.assertTrue(all(c[:2] == ('release','download') for c in self.p.calls))

    def test_published_version_never_replaced(self):
        self.p.retained()
        original = dict(self.p.releases['build-10']['files'])
        (self.directory/'jagar-boot.img').write_text('different')
        self.sums()
        other = FakePublisher(self.directory)
        other.releases, other.refs = self.p.releases, self.p.refs
        with self.assertRaisesRegex(RuntimeError, 'refusing to replace'):
            other.retained()
        self.assertEqual(original, other.releases['build-10']['files'])

    def test_existing_wrong_tag_commit_refused(self):
        self.p.refs['build-10'] = 'b'*40
        with self.assertRaisesRegex(RuntimeError, 'existing tag'):
            self.p.retained()
        self.assertFalse(self.p.calls)

    def test_older_run_cannot_roll_latest_back(self):
        self.p.releases['latest'] = {'draft': False, 'target_commitish': SHA,
                                    'files': {'PROVENANCE': b'build_number=11\n'}}
        self.p.rolling()
        self.assertTrue(all(c[:2] == ('release','download') for c in self.p.calls))

    def test_upgrade_latest_moves_tag_and_removes_obsolete_assets(self):
        self.p.retained()
        self.p.rolling()
        self.p.refs['latest'] = 'b'*40
        self.p.releases['latest']['files']['obsolete.apk'] = b'old'
        self.p.rolling()
        self.assertEqual(self.p.refs['latest'], SHA)
        self.assertNotIn('obsolete.apk', self.p.releases['latest']['files'])
        self.assertIn('build-10', self.p.releases)

    def test_manifest_tampering_fails_before_network(self):
        (self.directory/'installer-boot.img').write_text('tampered')
        with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
            FakePublisher(self.directory)

    def test_draft_lookup_falls_back_to_authenticated_listing(self):
        draft = {'tag_name': 'build-10', 'draft': True}
        with patch.object(self.p, 'gh', side_effect=[None, m.json.dumps([[draft]])]):
            self.assertEqual(m.Publisher.api(self.p, 'releases/tags/build-10'), draft)

    def test_network_error_is_not_treated_as_missing(self):
        failed = m.subprocess.CompletedProcess([], 1, '', 'HTTP 403 forbidden')
        with patch.object(m.subprocess, 'run', return_value=failed):
            with self.assertRaisesRegex(RuntimeError, '403'):
                m.Publisher.gh(self.p, 'api', 'anything', missing=True)
        failed.stderr = 'HTTP 404 not found'
        with patch.object(m.subprocess, 'run', return_value=failed):
            self.assertIsNone(m.Publisher.gh(self.p, 'api', 'anything', missing=True))


if __name__ == '__main__':
    unittest.main()
