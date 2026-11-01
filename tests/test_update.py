"""Updater tests use temporary paths and a fake download, never the VPS/network."""
import fcntl
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'govpn.sh').read_text()
UPDATER = SCRIPT[SCRIPT.index('UPDATE_CACHE_FILE='):SCRIPT.index('_full_uninstall() {')]
REF = 'fix/awg-warp-safe-persistence'
CURRENT = re.search(r'^VERSION="([^"]+)"', SCRIPT, re.M)[1]
NEXT = '999.0'


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / 'govpn'
        self.original = b'#!/bin/bash\necho previous-version\n'
        self.install.write_bytes(self.original)
        self.install.chmod(0o755)
        self.conf = self.root / 'conf'
        self.conf.mkdir()
        self.backups = self.conf / 'backups'
        self.candidate = self.root / 'candidate'
        self.good = SCRIPT.replace(f'VERSION="{CURRENT}"', f'VERSION="{NEXT}"', 1)
        self.candidate.write_text(self.good)
        self.download_log = self.root / 'download-log'

    def run_update(self, command='cmd_update --yes', simulate_tty=False, **flags):
        values = {'CONF_DIR': self.conf, 'BACKUP_DIR': self.backups, 'INSTALL_PATH': self.install,
                  'FIXTURE': self.candidate, 'DOWNLOAD_LOG': self.download_log,
                  'VERSION': CURRENT, 'UPDATE_REF': REF,
                  'REPO_URL': f'https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/{REF}/govpn.sh'}
        values.update(flags)
        harness = '\n'.join(k + '=' + shlex.quote(str(v)) for k, v in values.items())
        harness += r'''
curl() {
    printf '%s\n' "$*" >> "$DOWNLOAD_LOG"
    [ "${FAIL_DOWNLOAD:-0}" = 0 ] || return 22
    local dest=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; dest=$1; fi
        shift
    done
    command cp "$FIXTURE" "$dest"
}
cp() {
    if [ "${FAIL_BACKUP:-0}" = 1 ] && [ "$1" = -p ]; then return 1; fi
    command cp "$@"
}
mv() {
    if [ "${FAIL_INSTALL:-0}" = 1 ] && [ "${@: -1}" = "$INSTALL_PATH" ]; then return 1; fi
    command mv "$@"
}
log_action() { :; }
'''
        if not shutil.which('flock'):
            # macOS host: actual Linux flock is covered by the Docker run.
            harness += '\nflock() { return 0; }\n'
        updater = UPDATER.replace('< /dev/tty', '< /dev/null') if simulate_tty else UPDATER
        harness += updater + '\n' + command + '\n'
        return subprocess.run(['bash'], input=harness, text=True, capture_output=True,
                              env=dict(os.environ, LC_ALL='C'), timeout=20)

    def assert_untouched(self):
        self.assertEqual(self.install.read_bytes(), self.original)
        self.assertEqual(list(self.root.glob('govpn.update.*')), [])

    def test_success_preserves_original_and_installs_executable(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.install.read_text(), self.good)
        self.assertEqual(self.install.stat().st_mode & 0o777, 0o755)
        backups = list(self.backups.glob('govpn-update.*/govpn.sh'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        self.assertIn('refs/heads/' + REF + '/govpn.sh', self.download_log.read_text())
        self.assertNotIn('refs/heads/main/', self.download_log.read_text())
        self.assertIn('Установлена', result.stdout)

    def test_menu_entry_calls_the_same_updater(self):
        result = self.run_update('_self_update --yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.install.read_text(), self.good)
        self.assertTrue('update) _self_update ;;' in SCRIPT, 'System menu must use the same updater')

    def test_interactive_menu_replaces_the_parent_process(self):
        # A harmless executable fixture with the expected embedded-code format.
        self.candidate.write_text('''#!/bin/bash
VERSION="999.0"
# BEGIN GENERATED SAFE WARP
_awg_safe() {
    python3 - "$AWG_CONTAINER" "$@" <<'GOVPN_SAFE_PY'
pass

GOVPN_SAFE_PY
}
# END GENERATED SAFE WARP
echo new-manager
exit 0
''')
        result = self.run_update('read() { return 0; }; _self_update; echo resumed-old-menu', simulate_tty=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('new-manager', result.stdout)
        self.assertNotIn('resumed-old-menu', result.stdout)

    def test_download_failure_keeps_current_script(self):
        result = self.run_update(FAIL_DOWNLOAD=1)
        self.assertNotEqual(result.returncode, 0)
        self.assert_untouched()

    def test_reject_html_broken_shell_and_broken_python(self):
        candidates = ['<html>404</html>', self.good + '\nif\n',
                      self.good.replace('import argparse', 'import !invalid', 1)]
        for text in candidates:
            with self.subTest(text=text[:20]):
                self.candidate.write_text(text)
                self.assertNotEqual(self.run_update().returncode, 0)
                self.assert_untouched()

    def test_reject_old_backend_even_with_force(self):
        self.candidate.write_text('#!/bin/bash\nVERSION="999.0"\necho old-manager\n')
        self.assertNotEqual(self.run_update('cmd_update --force --yes').returncode, 0)
        self.assert_untouched()

    def test_reject_broken_names_module_without_running_it(self):
        for text in (self.good.replace('import contextlib', 'import !broken', 1),
                     self.good.replace('# END GENERATED AWG CLIENTS', '# MISSING CLIENTS END', 1)):
            with self.subTest():
                self.candidate.write_text(text)
                self.assertNotEqual(self.run_update().returncode, 0)
                self.assert_untouched()

    def test_backup_failure_aborts_install(self):
        self.assertNotEqual(self.run_update(FAIL_BACKUP=1).returncode, 0)
        self.assert_untouched()

    def test_atomic_replace_failure_keeps_current_script(self):
        self.assertNotEqual(self.run_update(FAIL_INSTALL=1).returncode, 0)
        self.assert_untouched()

    def test_broken_access_module_is_rejected_before_install(self):
        bad = self.good.replace('"""Optional OpenFlux L4 reserve', 'def !invalid():\n"""Optional OpenFlux L4 reserve', 1)
        self.candidate.write_text(bad)
        self.assertNotEqual(self.run_update().returncode,0)
        self.assert_untouched()

    def test_broken_report_module_is_rejected_before_install(self):
        bad = self.good.replace('"""Bounded, read-only connection report.', 'def !invalid():\n"""Bounded, read-only connection report.', 1)
        self.candidate.write_text(bad)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_untouched()

    def test_same_version_is_noop_without_force(self):
        self.candidate.write_text(SCRIPT)
        self.assertEqual(self.run_update().returncode, 0)
        self.assert_untouched()
        self.assertEqual(self.run_update('cmd_update --force --yes').returncode, 0)
        self.assertEqual(self.install.read_text(), SCRIPT)

    def test_downgrade_requires_force_and_still_validates(self):
        self.candidate.write_text(SCRIPT.replace(f'VERSION="{CURRENT}"', 'VERSION="1.0"', 1))
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assert_untouched()
        self.assertEqual(self.run_update('cmd_update --force --yes').returncode, 0)

    def test_cache_never_advertises_older_release(self):
        cache = self.conf / 'update.cache'
        for version in ('6.65', '1.0', CURRENT):
            cache.write_text(f'{version}|{int(time.time())}|{REF}\n')
            result = self.run_update('_update_cached_ver; exit 0')
            self.assertEqual(result.stdout.strip(), CURRENT if version == CURRENT else '')

    def test_version_compare_is_numeric_and_normalizes_missing_patch(self):
        for older, newer in (('6.9', '6.10'), ('6.67.1', '6.67.2'), ('9.99', '10.0')):
            self.assertEqual(self.run_update(f'_ver_lt {older} {newer}').returncode, 0)
            self.assertNotEqual(self.run_update(f'_ver_lt {newer} {older}').returncode, 0)
        self.assertNotEqual(self.run_update('_ver_lt 6.67 6.67.0').returncode, 0)
        self.assertNotEqual(self.run_update('_ver_lt 6.67.0 6.67').returncode, 0)

    def test_background_check_of_stale_remote_cannot_reintroduce_old_banner(self):
        self.candidate.write_text(SCRIPT.replace(f'VERSION="{CURRENT}"', 'VERSION="6.65"', 1))
        result = self.run_update('_update_fetch_bg; _update_cached_ver')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), CURRENT)

    def test_cache_is_bound_to_update_branch(self):
        result = self.run_update('_update_fetch_bg && _update_cached_ver')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), NEXT)
        cache = self.conf / 'update.cache'
        cache.write_text(cache.read_text().replace(REF, 'main'))
        self.assertNotEqual(self.run_update('_update_cached_ver').returncode, 0)

    @unittest.skipUnless(shutil.which('flock'), 'real flock is tested on Linux')
    def test_concurrent_update_does_not_write_or_download(self):
        with (self.conf / 'update.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_untouched()
        self.assertFalse(self.download_log.exists())


if __name__ == '__main__':
    unittest.main()
