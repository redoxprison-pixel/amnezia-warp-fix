import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('awg_warp', ROOT / 'lib/awg_warp.py')
safe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safe)

# Deliberately synthetic test material, never a real WARP account.
KEY = base64.b64encode(bytes(range(32))).decode()
PROFILE = f'''[Interface]
PrivateKey = {KEY}
Address = 172.16.0.2/32, 2606:4700:110::2/128
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = {KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
'''
START = '#!/bin/sh\n# vendor startup\n/usr/local/bin/vendor-init\ntail -f /dev/null\n'


class DataTests(unittest.TestCase):
    def test_profile_is_data_only_and_idempotent(self):
        result = safe.profile(PROFILE)
        self.assertEqual(result, safe.profile(result))
        self.assertNotIn('DNS', result)
        self.assertNotIn('::', result)
        self.assertIn('Table = off', result)
        self.assertIn('AllowedIPs = 0.0.0.0/0', result)

    def test_reject_shell_hooks_and_duplicates(self):
        for bad in ('PostUp = touch /tmp/pwn', 'SaveConfig = true', f'PrivateKey = {KEY}'):
            with self.subTest(bad=bad), self.assertRaises(safe.SafeError):
                safe.profile(PROFILE.replace('[Peer]', bad + '\n[Peer]'))

    def test_profile_requires_endpoint_keys_and_default(self):
        for original, replacement in ((KEY, 'invalid'), ('0.0.0.0/0', '10.0.0.0/8'),
                                      ('engage.cloudflareclient.com:2408', 'host;false:2408')):
            with self.assertRaises(safe.SafeError):
                safe.profile(PROFILE.replace(original, replacement))

    def test_exact_unique_clients_and_empty_selection(self):
        self.assertEqual(safe.clients(['10.8.1.3', '10.8.1.2/32', '10.8.1.3/32']),
                         ['10.8.1.2/32', '10.8.1.3/32'])
        self.assertEqual(safe.clients([]), [])
        for value in ('10.8.1.0/24', '10.999.1.2/32', '::1/128', "10.8.1.2';id", '0.0.0.0/32'):
            with self.subTest(value=value), self.assertRaises(safe.SafeError):
                safe.clients([value])

    def test_preserve_vendor_script_and_insert_guard_before_init(self):
        result = safe.patch_start(START, 'awg0')
        self.assertIn('/usr/local/bin/vendor-init', result)
        self.assertLess(result.index('runtime.sh guard'), result.index('vendor-init'))
        self.assertLess(result.index('runtime.sh apply'), result.index('tail -f'))
        self.assertEqual(result, safe.patch_start(result, 'awg0'))

    def test_migrate_only_balanced_known_markers(self):
        legacy = START.replace('tail -f', '# --- GOVPN WARP BEGIN ---\nwg-quick up warp\n# --- GOVPN WARP END ---\ntail -f')
        self.assertEqual(safe.patch_start(START, 'awg0'), safe.patch_start(legacy, 'awg0'))
        for bad in ('', '#!/bin/sh\nexec vendor-init\n',
                    START.replace('tail -f', '# --- GOVPN WARP BEGIN ---\ntail -f'),
                    START.replace('tail -f', 'wg-quick up warp\ntail -f')):
            with self.assertRaises(safe.SafeError):
                safe.patch_start(bad, 'awg0')

    def test_shell_and_bundle_syntax(self):
        subprocess.run(['bash', '-n', str(ROOT / 'govpn.sh')], check=True)
        subprocess.run(['python3', str(ROOT / 'tools/bundle.py'), '--check'], check=True)
        subprocess.run(['sh', '-n'], input=safe.RUNTIME, text=True, check=True)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.ctl = safe.Controller('amnezia-awg2', self.root)
        safe.private_dir(self.ctl.directory)
        self.state = {'version': 1, 'profile': safe.profile(PROFILE), 'clients': ['10.8.1.2/32'], 'iface': 'awg0'}
        safe.write_private(self.ctl.directory / 'state.json', json.dumps(self.state))

    def test_private_atomic_state(self):
        self.assertEqual(self.ctl.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.ctl.directory / 'state.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.ctl.state(), self.state)
        (self.ctl.directory / 'state.json').chmod(0o644)
        with self.assertRaises(safe.SafeError):
            self.ctl.state()

    def test_original_backup_before_any_mutation(self):
        def install(*args, **kwargs):
            backups = list((self.ctl.directory / 'backups').glob('*.json'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(json.loads(backups[0].read_text())['start.sh'], START)
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', return_value=START), patch.object(self.ctl, 'install', side_effect=install):
            self.ctl.deploy(self.state)

    def test_backup_failure_prevents_docker_mutation(self):
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', return_value=START), patch.object(self.ctl, 'backup', side_effect=OSError()), patch.object(self.ctl, 'install') as install:
            with self.assertRaises(OSError):
                self.ctl.deploy(self.state)
            install.assert_not_called()

    def test_mutation_failure_stops_pinned_container(self):
        self.ctl.target = 'pinned-id'
        calls = []
        def docker(*args, **kwargs):
            calls.append(args)
            if args[0] == 'exec' and 'apply' in args:
                raise safe.SafeError('failed')
        with patch.object(self.ctl, 'docker', side_effect=docker):
            with self.assertRaises(safe.SafeError):
                self.ctl.install(self.state, safe.patch_start(START, 'awg0'), True)
        self.assertEqual(calls[-1], ('stop', '--time', '0', 'pinned-id'))
        self.assertTrue(all('amnezia-awg2' not in call for call in calls))

    def test_empty_selection_committed_as_empty(self):
        state = dict(self.state, clients=[])
        with patch.object(self.ctl, 'docker'):
            self.ctl.install(state, safe.patch_start(START, 'awg0'), True)
        self.assertEqual(self.ctl.state()['clients'], [])

    def test_import_does_not_overwrite_existing_state(self):
        with self.assertRaises(safe.SafeError):
            self.ctl.import_state('unused', 'unused', 'awg0')

    def test_refuse_shared_network_and_mounts(self):
        for mode, mounts in (('host', []), ('container:other', []), ('bridge', [{'Destination': '/opt'}])):
            data = [{'Id': 'pinned', 'HostConfig': {'NetworkMode': mode}, 'Mounts': mounts, 'State': {'Running': True}}]
            with patch.object(self.ctl, 'docker', return_value=subprocess.CompletedProcess([], 0, json.dumps(data), '')):
                with self.assertRaises(safe.SafeError):
                    self.ctl.inspect()

    def test_invalid_container_name(self):
        for value in ('../other', '-flag', "name;id", ''):
            with self.assertRaises(safe.SafeError):
                safe.Controller(value, self.root)

    def test_error_output_cannot_expose_keys(self):
        with patch.object(safe, 'main', side_effect=ValueError(KEY)), patch('sys.stderr') as stderr:
            self.assertEqual(safe.entry(), 1)
        self.assertNotIn(KEY, ''.join(str(call) for call in stderr.write.call_args_list))


if __name__ == '__main__':
    unittest.main()
