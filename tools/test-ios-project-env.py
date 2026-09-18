#!/usr/bin/env python3
"""Exercise the guard against a temporary Git index, never the user's index."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PROJECT = 'app/ios/Runner.xcodeproj/project.pbxproj'
LOCAL = 'app/ios/Flutter/LocalSigning.xcconfig'


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        for name in [PROJECT, 'tools/verify-ios-project-env',
                     'tools/ios-project-env.json', 'app/ios/.gitignore',
                     *[f'app/ios/Flutter/{n}.xcconfig' for n in
                       ['Debug', 'Release', 'Signing']]]:
            dest = self.repo / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dest)
        self.git('init', '-q')
        self.git('add', '.')

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.repo, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def check(self, *args):
        return subprocess.run(['python3', 'tools/verify-ios-project-env', *args],
                              cwd=self.repo, capture_output=True).returncode

    def test_defaults_and_ignored_local_values(self):
        (self.repo / LOCAL).write_text('LEXE_IOS_TEAM = PERSONAL\n')
        self.assertEqual(self.check(), 0)
        self.assertEqual(self.check('--staged'), 0)

    def test_single_configuration_and_partially_staged_change(self):
        p = self.repo / PROJECT
        original = p.read_text()
        p.write_text(original.replace('$(LEXE_IOS_TEAM)', 'PERSONAL', 1))
        self.assertNotEqual(self.check(), 0)
        self.assertEqual(self.check('--staged'), 0)
        self.git('add', PROJECT)
        p.write_text(original)
        self.assertEqual(self.check(), 0)
        self.assertNotEqual(self.check('--staged'), 0)

    def test_non_signing_change_is_allowed(self):
        p = self.repo / PROJECT
        p.write_text(p.read_text().replace('SWIFT_VERSION = 5.0;',
                                          'SWIFT_VERSION = 5.1;', 1))
        self.assertEqual(self.check(), 0)

    def test_shared_xcconfig_override_is_rejected(self):
        p = self.repo / 'app/ios/Flutter/Debug.xcconfig'
        p.write_text(p.read_text() + 'DEVELOPMENT_TEAM = PERSONAL\n')
        self.assertNotEqual(self.check(), 0)

    def test_force_added_local_file_is_rejected(self):
        (self.repo / LOCAL).write_text('LEXE_IOS_TEAM = PERSONAL\n')
        self.git('add', '-f', LOCAL)
        self.assertNotEqual(self.check('--staged'), 0)


if __name__ == '__main__':
    unittest.main()
