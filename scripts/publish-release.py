#!/usr/bin/env python3
"""Publish a retained build first, then advance the serialized rolling alias."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fields(text):
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


class Publisher:
    def __init__(self, directory, notes, tag, sha, number):
        self.directory, self.notes = Path(directory), Path(notes)
        self.tag, self.sha, self.number = tag, sha, number
        require(re.fullmatch(r'(build-[1-9][0-9]*|pmos-v[A-Za-z0-9][A-Za-z0-9._-]*)', tag), 'invalid release tag')
        require(re.fullmatch(r'[0-9a-f]{40}', sha), 'invalid commit')
        require(number > 0, 'invalid build number')
        require(not tag.startswith('build-') or tag == f'build-{number}', 'build tag/number mismatch')
        self.assets = sorted(p for p in self.directory.iterdir() if p.is_file())
        self.names = {p.name for p in self.assets}
        require({'SHA256SUMS', 'PROVENANCE', 'APKINDEX.tar.gz', 'installer-boot.img', 'jagar-boot.img'} <= self.names,
                'incomplete signed release')
        self.manifest = (self.directory/'SHA256SUMS').read_text()
        sums = {}
        for line in self.manifest.splitlines():
            digest, name = line.split()
            require(re.fullmatch(r'[0-9a-f]{64}', digest) and name in self.names and name not in sums,
                    'invalid manifest entry')
            sums[name] = digest
        require(set(sums) == self.names - {'SHA256SUMS'}, 'manifest coverage mismatch')
        for p in self.assets:
            if p.name in sums:
                with p.open('rb') as stream:
                    require(hashlib.file_digest(stream, 'sha256').hexdigest() == sums[p.name],
                            'asset checksum mismatch: '+p.name)
        provenance = fields((self.directory/'PROVENANCE').read_text())
        require(provenance.get('release_commit') == sha and provenance.get('release_tag') == tag and
                provenance.get('build_number') == str(number), 'release identity mismatch')

    def gh(self, *args, missing=False):
        result = subprocess.run(['gh', *map(str, args)], capture_output=True, text=True)
        if missing and result.returncode and 'HTTP 404' in result.stderr:
            return None
        require(result.returncode == 0, result.stderr.strip() or 'gh failed')
        return result.stdout

    def api(self, endpoint):
        result = self.gh('api', 'repos/{owner}/{repo}/'+endpoint, missing=True)
        if result is not None:
            return json.loads(result)
        # GitHub's by-tag endpoint may omit unpublished drafts. Resume a
        # partially uploaded draft through the authenticated release listing.
        if endpoint.startswith('releases/tags/'):
            tag = endpoint.removeprefix('releases/tags/')
            pages = json.loads(self.gh('api', '--paginate', '--slurp',
                                      'repos/{owner}/{repo}/releases?per_page=100'))
            matches = [r for page in pages for r in page if r['tag_name'] == tag]
            require(len(matches) <= 1, 'ambiguous release tag')
            return matches[0] if matches else None
        return None

    def download(self, tag, name):
        return self.gh('release', 'download', tag, '--pattern', name, '--output', '-')

    def upload(self, tag, replace):
        # Manifest is the commit point for the rolling asset set.
        for p in sorted(self.assets, key=lambda p: p.name == 'SHA256SUMS'):
            self.gh('release', 'upload', tag, p, *(['--clobber'] if replace else []))

    def prune(self, tag):
        for asset in self.api('releases/tags/'+tag)['assets']:
            if asset['name'] not in self.names:
                self.gh('release', 'delete-asset', tag, asset['name'], '--yes')

    def retained(self):
        release = self.api('releases/tags/'+self.tag)
        ref = self.api('git/ref/tags/'+self.tag)
        if ref is not None:
            require(ref['object']['type'] == 'commit' and ref['object']['sha'] == self.sha,
                    'existing tag does not point directly to this commit')
        if release and not release['draft']:
            require(self.download(self.tag, 'SHA256SUMS') == self.manifest,
                    'published release differs; refusing to replace it (start a new workflow run)')
            require({a['name'] for a in release['assets']} == self.names, 'published asset set differs')
            require(ref is not None, 'published release tag missing')
            return
        if release:
            require(release['target_commitish'] == self.sha, 'draft belongs to another commit')
        else:
            self.gh('release', 'create', self.tag, '--draft', '--prerelease', '--latest=false',
                    '--target', self.sha, '--title', f'DC-1 {self.tag}', '--notes-file', self.notes)
        self.upload(self.tag, replace=True)  # Only unpublished drafts are replaceable.
        self.prune(self.tag)
        require({a['name'] for a in self.api('releases/tags/'+self.tag)['assets']} == self.names,
                'uploaded asset set differs')
        require(self.download(self.tag, 'SHA256SUMS') == self.manifest, 'uploaded manifest differs')
        self.gh('release', 'edit', self.tag, '--draft=false', '--prerelease', '--latest=false',
                '--notes-file', self.notes)

    def rolling(self):
        release = self.api('releases/tags/latest')
        if release:
            old = fields(self.download('latest', 'PROVENANCE'))
            previous = old.get('build_number', '0')  # Migration from unnumbered releases.
            require(previous.isdigit(), 'invalid latest build number')
            if int(previous) > self.number:
                print('Newer build already published; preserving latest.')
                return
        else:
            self.gh('release', 'create', 'latest', '--draft', '--prerelease', '--latest=false',
                    '--target', self.sha, '--title', 'Latest DC-1 build', '--notes-file', self.notes)
        # Check once more under the workflow's publishing serialization.
        with tempfile.TemporaryDirectory() as td:
            if release:
                old_sums = Path(td)/'SHA256SUMS'
                old_sums.write_text(self.download('latest', 'SHA256SUMS'))
                subprocess.run(['sh', str(Path(__file__).with_name('check-release-version-identity.sh')),
                                str(self.directory), str(old_sums)], check=True)
        # Prune after replacement assets exist, but before the final manifest.
        for p in self.assets:
            if p.name != 'SHA256SUMS':
                self.gh('release', 'upload', 'latest', p, '--clobber')
        self.prune('latest')
        self.gh('release', 'upload', 'latest', self.directory/'SHA256SUMS', '--clobber')
        if self.api('git/ref/tags/latest') is not None:
            self.gh('api', '--method', 'PATCH', 'repos/{owner}/{repo}/git/refs/tags/latest',
                    '-f', 'sha='+self.sha, '-F', 'force=true')
        self.gh('release', 'edit', 'latest', '--draft=false', '--prerelease', '--latest=false',
                '--target', self.sha, '--title', f'Latest DC-1 build ({self.tag})', '--notes-file', self.notes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    parser.add_argument('notes')
    parser.add_argument('--latest', action='store_true')
    args = parser.parse_args()
    publisher = Publisher(args.directory, args.notes, os.environ['RELEASE_TAG'],
                          os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_NUMBER']))
    publisher.retained()
    if args.latest:
        publisher.rolling()


if __name__ == '__main__':
    main()
