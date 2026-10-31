"""First-server setup regressions. Registration and downloads are synthetic."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_awg_warp import PROFILE, START, safe, ROOT
from test_clients import function


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ctl = safe.Controller('amnezia-awg2', self.root)
        safe.private_dir(self.ctl.directory)
        self.commands = []
        self.fail = None
        self.uncertain = False
        self.binary = self.root / 'fake-wgcf'
        self.patches = [patch.object(self.ctl, 'inspect', return_value=True),
                        patch.object(self.ctl, 'read_container', side_effect=self.read),
                        patch.object(self.ctl, 'prepare_dependencies'),
                        patch.object(self.ctl, 'wgcf_binary', return_value=self.binary),
                        patch.object(self.ctl, 'deploy', return_value=True),
                        patch.object(safe.subprocess, 'run', side_effect=self.run_wgcf)]
        self.mocks = [p.start() for p in self.patches]
        for p in self.patches:
            self.addCleanup(p.stop)

    def read(self, path, optional=False):
        return {safe.START: START, '/opt/amnezia/awg/awg0.conf': '[Interface]\nAddress=10.8.1.1/24\n'}.get(path)

    def run_wgcf(self, argv, **kwargs):
        self.commands.append(argv)
        directory = Path(kwargs['cwd'])
        self.assertNotIn('WGCF_PRIVATE_KEY', kwargs['env'])
        if 'register' in argv and not self.uncertain:
            (directory / 'wgcf-account.toml').write_text('synthetic-account')
        if 'generate' in argv and self.fail != 'generate':
            (directory / 'wgcf-profile.conf').write_text(PROFILE)
        return subprocess.CompletedProcess(argv, 1 if self.fail in argv else 0,
                                           stdout='SECRET ACCOUNT', stderr='SECRET KEY')

    def bootstrap(self, **kwargs):
        return self.ctl.bootstrap(['10.8.1.2/32'], accept_tos=True, **kwargs)

    def test_new_server_registers_once_then_persists_explicit_selection(self):
        with patch.dict('os.environ', {'WGCF_PRIVATE_KEY': 'UNTRUSTED'}):
            self.bootstrap(install_deps=True)
        state = self.ctl.state()
        self.assertEqual(state['clients'], ['10.8.1.2/32'])
        self.assertEqual(state['profile'], safe.profile(PROFILE))
        self.assertEqual(len([c for c in self.commands if 'register' in c]), 1)
        self.assertTrue(list((self.ctl.directory / 'backups').glob('*.json')))
        self.mocks[2].assert_called_once_with(True)
        self.mocks[4].assert_called_once()
        self.assertEqual((self.ctl.directory / 'registration/wgcf-account.toml').stat().st_mode & 0o777, 0o600)

    def test_repeat_cannot_reregister_existing_state(self):
        self.bootstrap()
        with self.assertRaisesRegex(safe.SafeError, 'Профиль уже существует'):
            self.bootstrap()
        self.assertEqual(len(self.commands), 2)

    def test_legacy_profile_refuses_new_registration(self):
        (self.root / 'warp.conf').write_text(PROFILE)
        with self.assertRaisesRegex(safe.SafeError, 'Профиль уже существует'):
            self.bootstrap()
        self.assertFalse(self.commands)

    def test_invalid_existing_profile_cannot_trigger_registration(self):
        (self.root / 'warp.conf').write_text('invalid')
        with self.assertRaises(safe.SafeError):
            self.bootstrap()
        self.assertFalse(self.commands)

    def test_missing_tos_or_selection_cannot_create_account(self):
        for selection, accepted in ((None, True), (['10.8.1.2'], False)):
            with self.subTest(), self.assertRaises(safe.SafeError):
                self.ctl.bootstrap(selection, accept_tos=accepted)
        self.assertFalse(self.commands)
        self.mocks[4].assert_not_called()

    def test_generate_retry_reuses_account(self):
        self.fail = 'generate'
        with self.assertRaises(safe.SafeError):
            self.bootstrap()
        self.fail = None
        self.bootstrap()
        self.assertEqual(len([c for c in self.commands if 'register' in c]), 1)
        self.assertEqual(len([c for c in self.commands if 'generate' in c]), 2)

    def test_uncertain_registration_is_not_repeated_or_applied(self):
        self.uncertain, self.fail = True, 'register'
        with self.assertRaises(safe.SafeError) as error:
            self.bootstrap()
        self.assertNotIn('SECRET', str(error.exception))
        with self.assertRaisesRegex(safe.SafeError, 'Предыдущая регистрация'):
            self.bootstrap()
        self.assertEqual(len(self.commands), 1)
        self.mocks[4].assert_not_called()
        self.assertFalse((self.ctl.directory / 'state.json').exists())

    def test_invalid_startup_and_missing_dependencies_fail_before_registration(self):
        with patch.object(self.ctl, 'read_container', return_value='#!/bin/sh\nexec unknown\n'):
            with self.assertRaises(safe.SafeError):
                self.bootstrap()
        self.mocks[2].side_effect = safe.SafeError('no dependencies')
        with self.assertRaises(safe.SafeError):
            self.bootstrap()
        self.assertFalse(self.commands)
        self.mocks[4].assert_not_called()

    def test_explicit_ready_profile_does_not_download_or_register(self):
        source = self.root / 'ready.conf'
        source.write_text(PROFILE)
        self.ctl.bootstrap([], source=source)
        self.assertEqual(self.ctl.state()['clients'], [])
        self.assertFalse(self.commands)
        self.mocks[3].assert_not_called()


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ctl = safe.Controller('amnezia-awg2', Path(self.temp.name))

    def test_download_hash_checked_before_execute_and_cache_reused(self):
        payload = b'synthetic binary; do not execute'
        calls = []
        def download(argv, **kwargs):
            calls.append(argv)
            Path(argv[-1]).write_bytes(payload)
            return subprocess.CompletedProcess(argv, 0)
        uname = type('Uname', (), {'machine': 'x86_64', 'sysname': 'Linux'})()
        assets = {'x86_64': ('amd64', hashlib.sha256(payload).hexdigest())}
        with patch.object(safe.os, 'uname', return_value=uname), patch.dict(safe.WGCF_ASSETS, assets), patch.object(safe.subprocess, 'run', side_effect=download):
            binary = self.ctl.wgcf_binary()
            self.assertEqual(binary, self.ctl.wgcf_binary())
            self.assertEqual(binary.stat().st_mode & 0o777, 0o700)
            self.assertEqual(len(calls), 1)
            self.assertIn('=https', calls[0])
            binary.write_bytes(b'tampered')
            self.assertEqual(self.ctl.wgcf_binary().read_bytes(), payload)
            self.assertEqual(len(calls), 2)

    def test_wrong_digest_cannot_install_binary(self):
        uname = type('Uname', (), {'machine': 'x86_64', 'sysname': 'Linux'})()
        def download(argv, **kwargs):
            Path(argv[-1]).write_bytes(b'wrong')
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(safe.os, 'uname', return_value=uname), patch.object(safe.subprocess, 'run', side_effect=download):
            with self.assertRaisesRegex(safe.SafeError, 'SHA256'):
                self.ctl.wgcf_binary()
        self.assertFalse(list((self.ctl.root / 'tools').glob('wgcf-*')))

    def test_missing_tools_without_flag_does_not_install_or_apply(self):
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'docker', return_value=subprocess.CompletedProcess([], 1)) as docker:
            with self.assertRaisesRegex(safe.SafeError, 'install-deps'):
                self.ctl.prepare_dependencies()
        self.assertEqual(docker.call_count, 1)

    def test_kernel_failure_never_touches_startup_or_firewall_rules(self):
        calls = []
        def docker(*argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess([], int('wireguard' in argv))
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'docker', side_effect=docker):
            with self.assertRaisesRegex(safe.SafeError, 'WireGuard интерфейс'):
                self.ctl.prepare_dependencies()
        self.assertFalse(any('cp' in c or 'restart' in c or 'stop' in c or 'apply' in c for c in calls))

    def test_incompatible_wg_always_removes_probe_link(self):
        calls = []
        def docker(*argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess([], int('public-key' in argv))
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'docker', side_effect=docker):
            with self.assertRaisesRegex(safe.SafeError, 'несовместима'):
                self.ctl.prepare_dependencies()
        self.assertIn('delete', calls[-1])


class FirstMenuTests(unittest.TestCase):
    def menu(self, source, answer, accepted='y'):
        with tempfile.TemporaryDirectory() as root:
            calls = Path(root) / 'calls'
            harness = function('_awg_install_warp').replace('< /dev/tty', '') + '''
AWG_CONTAINER=amnezia-awg2
_awg_safe() {
    if [ "$1" = profile-source ]; then echo SOURCE; else printf '%s\\n' "$*" >> CALLS; fi
}
_awg_choose_initial_clients() { AWG_INITIAL_CLIENTS=(10.8.1.2/32 10.9.1.2/32); }
read_yn() { echo ACCEPT; }
_awg_create_warp_conf() { echo IMPORT >> CALLS; }
_awg_install_warp
'''.replace('SOURCE', source).replace('CALLS', shlex.quote(str(calls))).replace('ACCEPT', accepted)
            result = subprocess.run(['bash', '-c', harness], input=answer + '\n', text=True, capture_output=True)
            return result, calls.read_text() if calls.exists() else ''

    def test_first_install_has_explicit_account_creation_and_selection(self):
        result, calls = self.menu('missing', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('bootstrap --accept-tos --install-deps --clients 10.8.1.2/32 10.9.1.2/32', calls)
        self.assertNotIn('setup', calls)

    def test_existing_profile_uses_setup_without_registration(self):
        result, calls = self.menu('saved', '')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.strip(), 'setup --install-deps')

    def test_cancel_or_refuse_terms_has_no_mutation(self):
        for answer, accepted in (('0', 'y'), ('1', 'n')):
            result, calls = self.menu('missing', answer, accepted)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, '')

    def test_initial_selection_by_row_handles_same_octets_and_explicit_empty(self):
        harness = function('_awg_choose_initial_clients').replace('< /dev/tty', '') + '''
_awg_refresh_clients() { AWG_CLIENT_IPS=(10.8.1.2/32 10.9.1.2/32); AWG_CLIENT_NAMES=(Phone Laptop); }
read_yn() { echo y; }
_awg_choose_initial_clients || exit $?
printf 'SELECTED:%s\\n' "${AWG_INITIAL_CLIENTS[*]}"
'''
        for answer, expected in (('2', '10.9.1.2/32'), ('n', ''), ('a', '10.8.1.2/32 10.9.1.2/32')):
            result = subprocess.run(['bash', '-c', harness], input=answer + '\n', text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('SELECTED:' + expected + '\n', result.stdout)
        result = subprocess.run(['bash', '-c', harness], input='999\n', text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SELECTED:', result.stdout)

    def test_first_file_import_uses_explicit_selection_without_legacy_list(self):
        with tempfile.TemporaryDirectory() as root:
            calls = Path(root) / 'calls'
            harness = function('_awg_create_warp_conf').replace('< /dev/tty', '') + '''
_awg_safe() {
    if [ "$1" = profile-source ]; then echo missing; else printf '%s\\n' "$*" >> CALLS; fi
}
_awg_choose_initial_clients() { AWG_INITIAL_CLIENTS=(10.8.1.2/32); }
_awg_create_warp_conf
'''.replace('CALLS', shlex.quote(str(calls)))
            result = subprocess.run(['bash', '-c', harness], input='/secure/profile.conf\n', text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls.read_text().strip(), 'bootstrap --config /secure/profile.conf --install-deps --clients 10.8.1.2/32')

    def test_combo_partial_failure_cannot_claim_full_success(self):
        harness = function('warp_setup_wizard').replace('< /dev/tty', '') + '''
MODE=combo
is_amnezia() { return 0; }; is_3xui() { return 0; }; clear() { :; }
_awg_warp_running() { return 1; }; _awg_safe() { return 0; }
_3xui_warp_installed() { return 1; }; _3xui_warp_running() { return 1; }
_3xui_install_warp() { return 0; }; _awg_install_warp() { return 1; }
warp_setup_wizard
'''
        result = subprocess.run(['bash', '-c', harness], input='3\n3\n\n', text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('WARP успешно настроен', result.stdout)
        self.assertIn('успешно 1, ошибок 1', result.stdout)


if __name__ == '__main__':
    unittest.main()
