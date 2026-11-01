"""Synthetic private state, lifecycle failures and country export; no live nodes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_clients import ROOT, SCRIPT

spec = importlib.util.spec_from_file_location('access', ROOT / 'lib/access_tools.py')
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)
URL = 'https://docs.yandex.ru/docs/view?url=fixture-document'
LINK = 'openflux://v1/fixture_only_not_a_real_secret'


class ReserveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve()
        self.ctl = access.Reserve(self.path / 'private', self.path / 'bin/openflux', self.path / 'unit.service')
        self.calls = []

    def command(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if '--make-link' in args:
            return json.dumps({'link':LINK}).encode()
        return b''

    def configure(self):
        with patch.object(self.ctl, 'preflight'), patch.object(access, 'command', side_effect=self.command):
            self.assertTrue(self.ctl.configure(URL))

    def test_configure_is_idempotent_and_preserves_key_link_and_no_network_mutations(self):
        self.configure()
        first = self.ctl.read('state.json')
        self.configure()
        self.assertEqual(self.ctl.read('state.json'), first)
        self.assertEqual(sum('--make-link' in args for args, _ in self.calls), 1)
        self.assertEqual((self.ctl.root / 'state.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.ctl.root.stat().st_mode & 0o777, 0o700)
        secret = self.ctl.state()['secret']
        for args, kwargs in self.calls:
            self.assertNotIn(secret, ' '.join(args))
            self.assertNotIn(URL, ' '.join(args))
            self.assertFalse(set(args).intersection(('docker','iptables','ip6tables','ssh','register')))
        unit = self.ctl.unit.read_text()
        self.assertIn('DynamicUser=yes', unit)
        self.assertIn('LoadCredential=secret:', unit)
        self.assertIn('CapabilityBoundingSet=\n', unit)
        self.assertIn('StandardOutput=null', unit)
        self.assertNotIn('--url', unit)
        self.assertNotIn('direct-listen', self.ctl.read('exit.conf'))

    def test_missing_credential_after_crash_is_rebuilt_with_same_secret(self):
        self.configure()
        secret = self.ctl.state()['secret']
        (self.ctl.root / 'secret.key').unlink()
        (self.ctl.root / 'exit.conf').unlink()
        self.configure()
        self.assertEqual(self.ctl.read('secret.key').strip(), secret)
        self.assertEqual(sum('--make-link' in args for args, _ in self.calls), 1)

    def test_partial_unrecognized_state_never_generates_another_key(self):
        access.directory(self.ctl.root)
        access.atomic(self.ctl.root / 'secret.key', 'fixture')
        with patch.object(self.ctl, 'preflight') as preflight:
            with self.assertRaises(access.AccessError):
                self.ctl.configure(URL)
        preflight.assert_not_called()
        self.assertEqual(self.ctl.read('secret.key'), 'fixture')

    def test_failed_service_start_stops_only_owned_reserve_and_keeps_state(self):
        def command(args, **kwargs):
            if args[:2] == ['systemctl','enable']:
                raise access.AccessError('fixture')
            return self.command(args, **kwargs)
        with patch.object(self.ctl, 'preflight'), patch.object(access, 'command', side_effect=command):
            with self.assertRaisesRegex(access.AccessError, 'Данные сохранены'):
                self.ctl.configure(URL)
        self.assertTrue(self.ctl.existing())
        self.assertIn((['systemctl','stop',access.SERVICE], {}), self.calls)

    def test_foreign_unit_is_never_replaced_or_stopped(self):
        self.ctl.unit.write_text('foreign service')
        with patch.object(self.ctl, 'preflight'), patch.object(access, 'command', side_effect=self.command):
            with self.assertRaises(access.AccessError):
                self.ctl.configure(URL)
            with self.assertRaises(access.AccessError):
                self.ctl.stop()
        self.assertEqual(self.ctl.unit.read_text(), 'foreign service')
        self.assertFalse(any(args[:2] == ['systemctl','enable'] for args, _ in self.calls))
        self.assertFalse((self.ctl.root / 'state.json').exists())

    def test_stop_and_detach_preserve_private_state(self):
        self.configure()
        original = self.ctl.read('state.json')
        with patch.object(access, 'command', side_effect=self.command):
            self.ctl.stop()
            self.ctl.detach()
        self.assertEqual(self.ctl.read('state.json'), original)
        self.assertFalse(self.ctl.unit.exists())

    def test_secret_link_is_never_printed_to_redirected_output(self):
        self.configure()
        with patch.object(access.sys.stdout, 'isatty', return_value=False):
            with self.assertRaisesRegex(access.AccessError, 'терминал'):
                self.ctl.show_link()

    def test_document_url_rejects_shell_config_and_unrelated_hosts(self):
        self.assertEqual(access.document_url(URL), URL)
        for bad in (URL+'\nRole=client', URL+'#fragment', URL+';Role=client', 'https://evil.example/docs/test',
                    'https://docs.yandex.ru@evil.example/docs/test', 'file:///etc/passwd', 'https://docs.yandex.ru:99/docs/test'):
            with self.assertRaises((access.AccessError, ValueError)):
                access.document_url(bad)

    def test_invalid_binary_hash_never_executes_download(self):
        def download(url, path, limit):
            path.write_bytes(b'not-a-binary')
        uname = type('U', (), {'sysname':'Linux','machine':'x86_64'})()
        with patch.object(access.os, 'uname', return_value=uname), patch.object(access, 'download', side_effect=download), patch.object(access, 'command') as command:
            with self.assertRaisesRegex(access.AccessError, 'SHA256'):
                self.ctl.ensure_binary()
        command.assert_not_called()
        self.assertFalse(self.ctl.binary.exists())

    def test_state_and_parent_symlinks_are_refused(self):
        target = self.path / 'target'
        target.mkdir()
        self.ctl.root.symlink_to(target)
        with self.assertRaises(access.AccessError):
            with self.ctl.lock():
                pass

    def test_embedded_module_matches_source(self):
        text = SCRIPT.split("<<'GOVPN_ACCESS_PY'\n",1)[1].split('\nGOVPN_ACCESS_PY',1)[0]
        self.assertEqual(text, (ROOT / 'lib/access_tools.py').read_text())


class CountryTests(unittest.TestCase):
    def payload(self, networks):
        return {'status':'ok', 'data':{'resource':'RU','resources':{'ipv4':networks}}}

    def test_prefix_normalization_removes_vpn_server_and_shared_overlaps(self):
        nets = access.country_networks(self.payload(['8.8.8.0/24','8.8.8.0/25']), 'RU', '8.8.8.8')
        server = access.ipaddress.IPv4Address('8.8.8.8')
        self.assertFalse(any(server in net for net in nets))
        self.assertEqual(sum(net.num_addresses for net in nets), 255)

    def test_current_ripe_response_may_omit_resource_echo(self):
        data = self.payload(['8.8.8.0/24'])
        del data['data']['resource']
        self.assertTrue(access.country_networks(data,'RU','1.1.1.1'))

    def test_rejects_other_country_private_default_ipv6_and_malformed_ranges(self):
        for value in ('0.0.0.0/0','10.0.0.0/8','8.0.0.0/7','fd00::/8','8.8.8.1/24','8.8.8.0-8.8.8.255'):
            with self.assertRaises((access.AccessError,ValueError)):
                access.country_networks(self.payload([value]),'RU','1.1.1.1')
        with self.assertRaises(access.AccessError):
            access.country_networks(self.payload(['8.8.8.0/24']),'US','1.1.1.1')

    def test_failed_fetch_preserves_previous_export_and_valid_output_uses_amnezia_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            path = root / 'RU-direct.json'
            path.write_text('previous')
            with patch.object(access, 'download', side_effect=access.AccessError('fixture')):
                with self.assertRaises(access.AccessError):
                    access.country_export('RU','8.8.8.8',root)
            self.assertEqual(path.read_text(),'previous')
            def download(url, path, limit):
                path.write_text(json.dumps(self.payload(['8.8.8.0/24'])))
            with patch.object(access,'download',side_effect=download):
                self.assertEqual(access.country_export('RU','8.8.8.8',root),path)
            rows = json.loads(path.read_text())
            self.assertTrue(all(set(row) == {'hostname','ip','ips'} and row['ip'] == row['hostname'] == row['ips'][0] for row in rows))
            self.assertEqual(path.stat().st_mode & 0o777,0o600)


if __name__ == '__main__':
    unittest.main()
