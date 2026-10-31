"""Synthetic identity metadata and shell menu regression tests; no VPS/network."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'govpn.sh').read_text()
spec = importlib.util.spec_from_file_location('awg_clients', ROOT / 'lib/awg_clients.py')
clients = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clients)


def function(name):
    start = SCRIPT.index(name + '() {')
    return SCRIPT[start:SCRIPT.index('\n}\n', start) + 3]


class IdentityTests(unittest.TestCase):
    def test_join_by_public_key_without_cached_ip(self):
        table = json.dumps([{'clientId': 'keyA', 'userData': {'clientName': 'Мой iPhone'}}])
        rows = clients.records(table, [('keyA', '10.8.1.2/32'), ('keyB', '10.8.1.3/32')])
        self.assertEqual([(r['ip'], r['name']) for r in rows],
                         [('10.8.1.2/32', 'Мой iPhone'), ('10.8.1.3/32', '')])

    def test_stale_metadata_ip_cannot_rename_different_key(self):
        table = json.dumps([{'clientId': 'old', 'userData': {'clientName': 'Old', 'allowedIps': '10.8.1.2/32'}}])
        self.assertEqual(clients.records(table, [('new', '10.8.1.2/32')])[0]['name'], '')

    def test_legacy_map_and_keyless_exact_ip(self):
        table = json.dumps({'keyA': {'clientName': 'Laptop'}})
        self.assertEqual(clients.records(table, [('keyA', '10.8.1.2/32')])[0]['name'], 'Laptop')
        table = json.dumps([{'userData': {'clientName': 'Phone', 'allowedIps': ['10.8.1.2/32', 'fd00::2/128']}}])
        self.assertEqual(clients.records(table, [('keyA', '10.8.1.2/32')])[0]['name'], 'Phone')

    def test_partial_or_corrupt_metadata_does_not_hide_configured_peers(self):
        for table in ('bad JSON', 'null', '[4, {"userData": "bad"}]', '{}'):
            self.assertEqual(len(clients.records(table, [('a', '10.8.1.2/32'), ('b', '10.9.1.2/32')])), 2)

    def test_only_ipv4_hosts_are_route_choices(self):
        self.assertEqual(clients.addresses('10.8.1.2, 10.8.1.3/32, fd00::2/128, 0.0.0.0/0, 10.0.0.0/24, junk'),
                         ['10.8.1.2/32', '10.8.1.3/32'])

    def test_config_peer_boundary_and_no_secret_output(self):
        config = '[Interface]\nPrivateKey = SECRET\nAddress = 10.8.1.1/24\n[Peer]\nPublicKey = A\nAllowedIPs = 10.8.1.2/32, fd00::2/128\n[Peer]\nPublicKey = B\nAllowedIPs = 10.9.1.2/32\n'
        self.assertEqual(clients.config_peers(config), [('A', '10.8.1.2/32'), ('B', '10.9.1.2/32')])
        self.assertNotIn('SECRET', str(clients.records('{}', clients.config_peers(config))))

    def test_duplicate_ip_refuses_ambiguous_identity(self):
        with self.assertRaises(clients.ClientError):
            clients.records('{}', [('A', '10.8.1.2/32'), ('B', '10.8.1.2/32')])

    def test_names_cannot_break_row_or_terminal(self):
        cleaned = clients.label('Мой\nPhone|\\e[31m\x1b\u202e')
        self.assertNotIn('|', cleaned)
        self.assertNotIn('\\', cleaned)
        self.assertNotIn('\x1b', cleaned)
        self.assertNotIn('\n', cleaned)
        self.assertNotIn('\u202e', cleaned)

    def test_handshake_is_assigned_to_its_key(self):
        rows = clients.records('{}', [('A', '10.8.1.2/32'), ('B', '10.8.1.3/32')], 'B\t120\nA\t0\n')
        self.assertEqual([r['handshake'] for r in rows], [0, 120])

    def test_private_alias_survives_ip_change_but_not_key_change(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'names' / 'awg.json'
            clients.rename(path, 'A', "Папин iPhone '2'")
            clients.rename(path, 'B', 'Laptop')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            aliases = clients.load_aliases(path)
            self.assertEqual(aliases['B'], 'Laptop')
            self.assertEqual(clients.records('{}', [('A', '10.8.1.99/32')], aliases=aliases)[0]['name'], "Папин iPhone '2'")
            self.assertEqual(clients.records('{}', [('C', '10.8.1.99/32')], aliases=aliases)[0]['name'], '')
            previous = path.read_bytes()
            with self.assertRaises(clients.ClientError):
                clients.rename(path, 'A', 'bad\nname')
            self.assertEqual(path.read_bytes(), previous)

    def test_alias_symlinks_refused(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'target'
            target.write_text('{}')
            path = Path(root) / 'link'
            path.symlink_to(target)
            with self.assertRaises(clients.ClientError):
                clients.rename(path, 'A', 'Phone')
            self.assertEqual(target.read_text(), '{}')

    def test_snapshot_uses_nonsecret_wg_fields_and_keeps_missing_metadata_clients(self):
        def docker(container, *args, **kwargs):
            if args[0] == 'cat' and args[1].endswith('awg0.conf'):
                return '[Peer]\nPublicKey=A\nAllowedIPs=10.8.1.2/32\n'
            if args[-1] == 'allowed-ips':
                return 'B\t10.9.1.2/32\n'
            return ''
        with patch.object(clients, 'docker', side_effect=docker) as mock:
            rows = clients.snapshot('amnezia-awg2')
        self.assertEqual(len(rows), 2)
        self.assertFalse(any('dump' in c.args for c in mock.call_args_list))

    def test_embedded_module_matches_source(self):
        embedded = SCRIPT.split("<<'GOVPN_CLIENTS_PY'\n", 1)[1].split('\nGOVPN_CLIENTS_PY', 1)[0]
        self.assertEqual(embedded, (ROOT / 'lib/awg_clients.py').read_text())

    def test_modern_awg_uses_awg_for_live_peer_and_handshake(self):
        def docker(container, *args, **kwargs):
            if args == ('cat', '/opt/amnezia/awg/awg0.conf'):
                return '[Interface]\nAddress=10.8.1.1/24\n'
            if args == ('awg', 'show', 'awg0', 'allowed-ips'):
                return 'A\t10.8.1.2/32\n'
            if args == ('awg', 'show', 'awg0', 'latest-handshakes'):
                return 'A\t123\n'
            if args == ('cat', '/opt/amnezia/awg/clientsTable'):
                return json.dumps([{'clientId': 'A', 'userData': {'clientName': 'Phone'}}])
            raise AssertionError('Unexpected wg call: ' + repr(args))
        with patch.object(clients, 'docker', side_effect=docker):
            rows = clients.snapshot('amnezia-awg2')
        self.assertEqual(rows[0]['name'], 'Phone')
        self.assertEqual(rows[0]['handshake'], 123)


class MenuTests(unittest.TestCase):
    def run_bash(self, body, data=''):
        return subprocess.run(['bash', '-c', body], input=data, text=True, capture_output=True)

    def test_index_selects_exact_ip_with_duplicate_last_octets(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'selected'
            body = function('awg_clients_menu') + '''
AWG_CONTAINER=amnezia-awg2
is_amnezia() { return 0; }; docker() { :; }; clear() { :; }
_awg_iface() { echo awg0; }; _awg_warp_running() { return 1; }
_awg_refresh_clients() { AWG_CLIENT_IPS=(10.8.1.2/32 10.9.1.2/32); }
_awg_client_name() { echo Phone; }; _awg_selected_clients() { :; }
read_choice() { local choice; read -r choice; printf '%s' "$choice"; }
log_action() { :; }
''' + '_awg_apply_rules() { printf \'%s\\n\' "$@" > ' + shlex.quote(str(output)) + '; }\nawg_clients_menu'
            result = self.run_bash(body, '2\ns\n\n0\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), '10.9.1.2/32\n')

    def test_snapshot_failure_cannot_apply_empty_selection(self):
        body = function('awg_clients_menu') + '''
AWG_CONTAINER=amnezia-awg2
is_amnezia() { return 0; }; docker() { :; }; clear() { :; }
_awg_iface() { echo awg0; }; _awg_warp_running() { return 1; }
_awg_refresh_clients() { return 1; }
_awg_apply_rules() { echo UNSAFE; }
awg_clients_menu
'''
        result = self.run_bash(body, '\n')
        self.assertNotIn('UNSAFE', result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_config_export_refuses_server_config_substring_and_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / 'awg_clients'
            directory.mkdir()
            path = directory / '10.8.1.2.conf'
            body = function('_awg_get_client_config') + '\nCONF_DIR=' + shlex.quote(root) + '\n_awg_get_client_config 10.8.1.2/32'
            for bad in ('[Interface]\nAddress=10.8.1.1/24\nPrivateKey=SERVER\n[Peer]\nAllowedIPs=10.8.1.2/32',
                        '[Interface]\nAddress=10.8.1.20/32\n[Peer]\nAllowedIPs=0.0.0.0/0'):
                path.write_text(bad)
                result = self.run_bash(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
            path.write_text('[Interface]\nAddress=10.8.1.2/32\n[Peer]\nAllowedIPs=0.0.0.0/0\n')
            self.assertEqual(self.run_bash(body).returncode, 0)
            path.unlink()
            path.symlink_to(directory / 'missing')
            self.assertNotEqual(self.run_bash(body).returncode, 0)

    def test_site_check_treats_python_fragment_as_data(self):
        with tempfile.TemporaryDirectory() as root:
            marker = Path(root) / 'executed'
            attack = "x')); open(" + repr(str(marker)) + ", 'w').write('oops'); #"
            body = function('_site_check') + '\nclear() { :; }; _site_check'
            result = self.run_bash(body, attack + '\n\n')
            self.assertFalse(marker.exists(), result.stderr)


if __name__ == '__main__':
    unittest.main()
