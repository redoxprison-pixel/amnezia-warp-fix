"""Installer tests run as root ONLY inside the disposable offline Linux test box."""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.geteuid() == 0 and shutil.which('flock'), 'root Linux installer tests run in disposable Docker')
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / 'govpn'
        self.install.write_text('previous')
        self.conf = self.root / 'config'
        self.fixture = self.root / 'candidate'
        self.fixture.write_text((ROOT / 'govpn.sh').read_text())
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        curl = self.bin / 'curl'
        curl.write_text('''#!/bin/bash
[ "${FAIL_DOWNLOAD:-0}" != 1 ] || exit 22
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then cp "$FIXTURE" "$2"; exit; fi
    shift
done
exit 1
''')
        curl.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], FIXTURE=str(self.fixture),
                        GOVPN_INSTALL_PATH=str(self.install), GOVPN_CONF_DIR=str(self.conf))

    def run_install(self):
        return subprocess.run(['bash', str(ROOT / 'install.sh'), '--no-run'], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_installs_validated_bundle_with_private_backup(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.install.read_bytes(), self.fixture.read_bytes())
        backup = list((self.conf / 'backups').glob('govpn-install.*/govpn.sh'))
        self.assertEqual(len(backup), 1)
        self.assertEqual(backup[0].read_text(), 'previous')
        self.assertEqual(backup[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.install.stat().st_mode & 0o777, 0o755)

    def test_bad_backend_or_download_never_overwrites_current_script(self):
        self.fixture.write_text(self.fixture.read_text().replace('import argparse', 'import !invalid', 1))
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual(self.install.read_text(), 'previous')
        self.env['FAIL_DOWNLOAD'] = '1'
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual(self.install.read_text(), 'previous')

    def test_lock_and_symlink_are_refused(self):
        self.conf.mkdir()
        with (self.conf / 'update.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual(self.install.read_text(), 'previous')
        self.install.unlink()
        self.install.symlink_to(self.fixture)
        self.assertNotEqual(self.run_install().returncode, 0)


if __name__ == '__main__':
    unittest.main()
