"""Offline release-integrity regressions, using disposable package fixtures."""
import argparse
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import release_artifacts as release


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.inputs = self.root / 'artifacts'
        self.inputs.mkdir()
        for artifact, filename in release.PACKAGES.items():
            folder = self.inputs / artifact
            folder.mkdir()
            data = ('synthetic offline package ' + artifact).encode()
            (folder / filename).write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            (folder / (filename + '.sha256')).write_text(f'{digest}  {filename}\n')
        self.args = argparse.Namespace(
            tag='v1.0.0', source_sha='a' * 40, artifacts=self.inputs,
            output=self.root / 'upload', notes=self.root / 'notes.md',
        )

    def test_complete_run_produces_only_expected_upload_files(self):
        release.assemble(self.args)
        names = {p.name for p in self.args.output.iterdir()}
        expected = {'SHA256SUMS.txt'} | {
            f'Sim-Bridge-1.0.0-{suffix}' for suffix in release.PUBLISHED.values()
        }
        self.assertEqual(names, expected)
        sums = (self.args.output / 'SHA256SUMS.txt').read_text().splitlines()
        self.assertEqual(sorted(line.split('  ')[1] for line in sums), sorted(expected - {'SHA256SUMS.txt'}))
        self.assertIn('draft', self.args.notes.read_text())
        self.assertIn('notarized', self.args.notes.read_text())

    def test_tampered_package_never_creates_upload_set(self):
        artifact, filename = next(iter(release.PACKAGES.items()))
        (self.inputs / artifact / filename).write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
            release.assemble(self.args)
        self.assertFalse(self.args.output.exists())

    def test_other_run_or_stale_package_is_rejected(self):
        (self.inputs / 'another-run').mkdir()
        with self.assertRaisesRegex(ValueError, 'exactly the four'):
            release.assemble(self.args)
        self.assertFalse(self.args.output.exists())

    def test_existing_output_is_not_reused(self):
        self.args.output.mkdir()
        with self.assertRaises(FileExistsError):
            release.assemble(self.args)

    def test_tag_must_match_actual_source_version(self):
        pubspec = self.root / 'pubspec.yaml'
        pubspec.write_text('name: synthetic\nversion: 1.0.0+5\n')
        args = argparse.Namespace(tag='v1.0.1', source_sha='a' * 40,
                                  pubspec=pubspec, github_output=None)
        with self.assertRaisesRegex(ValueError, 'does not match'):
            release.validate_version(args)

    def test_malformed_semver_is_rejected(self):
        for tag in ['main', 'v01.0.0', 'v1.0.0-01', 'v1.0.0/other']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag)

    def test_moved_remote_tag_is_rejected(self):
        args = argparse.Namespace(repository='synthetic/repo', tag='v1.0.0',
                                  source_sha='a' * 40)
        with patch.object(release, 'api_json', return_value={
            'object': {'type': 'commit', 'sha': 'b' * 40},
        }), self.assertRaisesRegex(ValueError, 'moved'):
            release.verify_remote_tag(args)

    def test_annotated_tag_is_peeled_to_the_built_commit(self):
        args = argparse.Namespace(repository='synthetic/repo', tag='v1.0.0',
                                  source_sha='a' * 40)
        replies = [
            {'object': {'type': 'tag', 'sha': 'b' * 40}},
            {'object': {'type': 'commit', 'sha': 'a' * 40}},
        ]
        with patch.object(release, 'api_json', side_effect=replies) as api:
            release.verify_remote_tag(args)
        self.assertEqual(api.call_count, 2)


if __name__ == '__main__':
    unittest.main()
