"""Identity-safe profile reuse and merged navigation; synthetic fixtures only."""
import base64
from pathlib import Path
import subprocess
import tempfile
import unittest
import shlex
from unittest.mock import patch

from test_clients import clients, function
from test_awg_warp import safe

PRIVATE = base64.b64encode(bytes(range(32))).decode()
PUBLIC = base64.b64encode(bytes([1]) * 32).decode()
SERVER_PRIVATE = base64.b64encode(bytes([2]) * 32).decode()
SERVER_PUBLIC = base64.b64encode(bytes([3]) * 32).decode()
PSK = base64.b64encode(bytes([4]) * 32).decode()
ROW = {'ip': '10.8.1.2/32', 'key': PUBLIC}
PROFILE = f'[Interface]\nPrivateKey = {PRIVATE}\nAddress = 10.8.1.2/32\nDNS = 1.1.1.1\n[Peer]\nPublicKey = {SERVER_PUBLIC}\nPresharedKey = {PSK}\nAllowedIPs = 0.0.0.0/0\nEndpoint = 192.0.2.1:51820\n'
SERVER = f'[Interface]\nPrivateKey = {SERVER_PRIVATE}\nAddress = 10.8.1.254/24\n[Peer]\nPublicKey = {PUBLIC}\nAllowedIPs = 10.8.1.2/32\nPresharedKey = {PSK}\n'


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'export.conf'
        self.source.write_text(PROFILE)
        for p in (patch.object(clients, 'read_config', return_value=(SERVER, 'awg0')),
                  patch.object(clients, 'public_key', side_effect=lambda c, key: {PRIVATE: PUBLIC, SERVER_PRIVATE: SERVER_PUBLIC}[key])):
            p.start()
            self.addCleanup(p.stop)

    def test_import_export_matches_live_key_ip_server_and_psk(self):
        clients.import_profile(self.root, 'awg', ROW, self.source)
        path = clients.profile_path(self.root, 'awg', ROW)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(clients.saved_profile(self.root, 'awg', ROW), PROFILE)

    def test_wrong_key_ip_server_and_psk_refused_without_replacing_saved_profile(self):
        clients.import_profile(self.root, 'awg', ROW, self.source)
        for wrong in (PROFILE.replace('10.8.1.2/32', '10.8.1.20/32'),
                      PROFILE.replace(SERVER_PUBLIC, PUBLIC), PROFILE.replace(PSK, PRIVATE)):
            self.source.write_text(wrong)
            with self.assertRaises(clients.ClientError):
                clients.import_profile(self.root, 'awg', ROW, self.source)
        self.assertEqual(clients.saved_profile(self.root, 'awg', ROW), PROFILE)

    def test_ip_reuse_does_not_export_another_clients_key(self):
        legacy = self.root / 'awg_clients/10.8.1.2.conf'
        legacy.parent.mkdir()
        legacy.write_text(PROFILE)
        with self.assertRaises(clients.ClientError):
            clients.saved_profile(self.root, 'awg', dict(ROW, key=SERVER_PUBLIC))

    def test_server_config_hooks_and_control_chars_never_saved(self):
        for bad in (SERVER, PROFILE.replace('[Peer]', 'PostUp = touch /tmp/unsafe\n[Peer]'),
                    PROFILE + '\x1b[31m'):
            self.source.write_text(bad)
            with self.assertRaises(clients.ClientError):
                clients.import_profile(self.root, 'awg', ROW, self.source)
        self.assertFalse(clients.profile_path(self.root, 'awg', ROW).exists())

    def test_missing_copy_reports_recovery_without_creating_new_keys(self):
        with self.assertRaisesRegex(clients.ClientError, 'Экспортируйте'):
            clients.saved_profile(self.root, 'awg', ROW)

    def test_pubkey_uses_stdin_and_never_key_in_argv(self):
        with patch.object(clients.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, PUBLIC + '\n')) as run:
            # Use the real derivation function, not the validation mock.
            original = clients.public_key
            from test_clients import spec
            import importlib.util
            real = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(real)
            self.assertEqual(real.public_key('awg', PRIVATE), PUBLIC)
        argv = run.call_args.args[0]
        self.assertNotIn(PRIVATE, argv)
        self.assertEqual(run.call_args.kwargs['input'], PRIVATE + '\n')


class NavigationTests(unittest.TestCase):
    def test_card_and_bulk_routes_share_same_backend_and_preserve_other_clients(self):
        body = function('_awg_change_client_route') + '''
_awg_refresh_policy() { AWG_POLICY_ACTIVE=on; AWG_POLICY_IPS=(10.8.1.2/32 10.9.1.2/32); }
read_yn() { echo y; }
_awg_apply_rules() { printf 'APPLY:%s\\n' "$*"; }
_awg_change_client_route 10.8.1.2/32 direct
'''
        result = subprocess.run(['bash', '-c', body], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('APPLY:10.9.1.2/32', result.stdout)

    def test_direct_when_warp_removed_does_not_reenable_it(self):
        body = function('_awg_change_client_route') + '''
_awg_refresh_policy() { AWG_POLICY_ACTIVE=off; AWG_POLICY_IPS=(10.8.1.2/32); }
_awg_apply_rules() { echo UNSAFE; }
_awg_change_client_route 10.8.1.2/32 direct
'''
        result = subprocess.run(['bash', '-c', body], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNSAFE', result.stdout)

    def test_policy_failure_does_not_apply_invented_empty_selection(self):
        body = function('_awg_change_client_route') + '''
_awg_refresh_policy() { return 1; }
_awg_apply_rules() { echo UNSAFE; }
_awg_change_client_route 10.8.1.2/32 warp
'''
        result = subprocess.run(['bash', '-c', body], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('UNSAFE', result.stdout)

    def test_unified_entry_routes_amnezia_and_combo(self):
        for combo, answer, expected in ((False, '', 'AWG'), (True, '1\n', 'AWG'), (True, '2\n', 'XUI')):
            body = function('_clients_hub') + '''
is_amnezia() { return 0; }
is_3xui() { return COMBO; }
read_choice() { local c; read -r c; echo "$c"; }
awg_peers_menu() { echo AWG; }; _3xui_clients_menu() { echo XUI; }
_clients_hub
'''.replace('COMBO', '0' if combo else '1')
            result = subprocess.run(['bash', '-c', body], input=answer, text=True, capture_output=True)
            self.assertEqual(result.stdout.splitlines()[-1], expected)


class NativeToolTests(unittest.TestCase):
    def test_paths_allow_only_fixed_or_owned_private_payload(self):
        self.assertEqual(safe.validate_tools({'wg': 'private', 'wg_quick': 'private'})['wg'], 'private')
        with self.assertRaises(safe.SafeError):
            safe.validate_tools({'wg': '/tmp/attacker', 'wg_quick': '/usr/bin/wg-quick'})

    def test_all_awg_commands_fall_back_to_isolated_payload(self):
        with tempfile.TemporaryDirectory() as root:
            ctl = safe.Controller('awg', Path(root))
            def docker(*args, **kwargs):
                return subprocess.CompletedProcess([], int('public-key' in args))
            with patch.object(ctl, 'inspect', return_value=True), patch.object(ctl, 'docker', side_effect=docker), patch.object(ctl, 'private_wireguard', return_value={'wg':'private','wg_quick':'private'}) as private:
                self.assertEqual(ctl.prepare_dependencies(install=True)['wg'], 'private')
            private.assert_called_once()
            self.assertTrue(private.call_args.args[1])


class SSHPlanTests(unittest.TestCase):
    def plan(self, host='192.0.2.10', user='admin', jump='192.0.2.20'):
        args = [host, '22', user, jump, '22', 'jumpuser']
        body = function('_ssh_access_plan') + '\n_ssh_access_plan ' + ' '.join(shlex.quote(v) for v in args)
        return subprocess.run(['bash', '-c', body], text=True, capture_output=True)

    def test_reserve_plan_preserves_host_key_checks_and_does_not_forward_agent(self):
        result = self.plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ProxyJump govpn-jump', result.stdout)
        self.assertIn('StrictHostKeyChecking yes', result.stdout)
        self.assertIn('ForwardAgent no', result.stdout)
        self.assertIn('Host govpn-direct', result.stdout)
        self.assertIn('не подтверждение доступа', result.stdout)

    def test_no_jump_is_not_described_as_independent_reserve(self):
        result = self.plan(jump='')
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('ProxyJump', result.stdout)
        self.assertIn('только прямой вход', result.stdout)

    def test_ssh_config_injection_is_refused(self):
        for bad in ('host\n    ProxyCommand touch /tmp/injected', '-oProxyCommand=bad', 'host;bad'):
            result = self.plan(host=bad)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Host govpn', result.stdout)


if __name__ == '__main__':
    unittest.main()
