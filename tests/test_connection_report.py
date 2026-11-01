"""Read-only report, safe output, failed probes and managed policy fixtures."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_clients import ROOT, SCRIPT

spec = importlib.util.spec_from_file_location('diagnostics', ROOT / 'lib/diagnostics.py')
diag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diag)
FLAGS = '\n'.join(k + '=yes' for k in ('awg', 'forward', 'warp', 'policy', 'route', 'fallback',
                                      'guard', 'selection', 'ipv6forward', 'ipv6input', 'curl', 'handshake')) + '\npeers=2\nactive=1\n'
TRACE = 'ip=192.0.2.2\nloc=DE\nwarp=on\n'


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = io.StringIO()
        self.report = diag.Report('amnezia', 'amnezia-awg2', self.root, self.output)
        self.calls = []

    def state(self, enabled=True):
        directory = self.root / 'amnezia-awg2'
        directory.mkdir(exist_ok=True)
        path = directory / 'state.json'
        path.write_text(json.dumps({'enabled': enabled, 'clients': ['10.8.1.2/32'], 'profile': 'TEST-SECRET'}))
        path.chmod(0o600)
        return path

    def fake(self, args, timeout=7):
        self.calls.append((args, timeout))
        if args[:5] == ['ip', '-j', '-4', 'route', 'get']:
            return True, json.dumps([{'dev': 'net0', 'prefsrc': '8.8.8.8'}])
        if args[:5] == ['ip', '-j', '-4', 'address', 'show']:
            return True, json.dumps([{'ifname': 'net0', 'addr_info': [{'family': 'inet', 'local': '8.8.8.8'}]}])
        if args[:2] == ['docker', 'inspect']:
            return True, 'true\n'
        if args[:2] == ['docker', 'exec'] and 'sh' in args:
            return True, FLAGS
        if diag.TRACE in args:
            return True, TRACE
        if diag.GEMINI in args:
            return True, '302'
        return True, ''

    def test_full_report_has_stages_counts_and_client_limit_without_mutations(self):
        path = self.state()
        before = path.read_bytes()
        with patch.object(diag, 'run', side_effect=self.fake), patch.object(diag.shutil, 'which', return_value='/fixture'):
            self.assertEqual(self.report.execute(), 0)
        output = self.output.getvalue()
        for stage in range(1, 6):
            self.assertIn(f'[{stage}/5]', output)
        for text in ('Успешно:', 'Замечания:', 'Ошибки:', 'Время:', 'регион', 'IPv6', '192.0.2.2'):
            self.assertIn(text, output)
        self.assertNotIn('TEST-SECRET', output)
        self.assertNotIn('\x1b', output)
        self.assertEqual(path.read_bytes(), before)
        self.assertTrue(all(timeout <= 10 for _, timeout in self.calls))
        for args, _ in self.calls:
            self.assertFalse(set(args).intersection(('restart', 'stop', 'start', 'register', 'apt-get', 'apk', 'wg-quick')))
        self.assertNotIn('PrivateKey', diag.NETWORK)
        self.assertNotIn(' dump', diag.NETWORK)
        self.assertNotIn('cat /opt', diag.NETWORK)

    def test_no_warp_is_optional_not_failure(self):
        with patch.object(diag, 'run', side_effect=self.fake), patch.object(diag.shutil, 'which', return_value='/fixture'):
            # No state + no interface is a normal direct VPS deployment.
            self.report.warp({})
            self.assertEqual(self.report.summary(), 0)
        self.assertIn('не обязателен', self.output.getvalue())
        self.assertFalse(self.calls)

    def test_missing_ipv6_guard_is_error_and_does_not_repair(self):
        self.state()
        flags = dict(line.split('=', 1) for line in FLAGS.splitlines())
        del flags['ipv6input']
        with patch.object(diag, 'run', side_effect=self.fake):
            self.report.warp(flags)
        self.assertIn(('error', 'Запрет IPv6 INPUT', 'не найден или не удалось проверить'), self.report.rows)
        self.assertEqual(len(self.calls), 1)  # fixed HTTPS probe only

    def test_bad_secret_state_and_symlink_never_print_contents(self):
        path = self.state()
        for data in ('TEST-SECRET', '{"enabled":true,"clients":["0.0.0.0/0"],"profile":"TEST-SECRET"}'):
            path.write_text(data)
            self.report.warp({})
        path.unlink()
        target = self.root / 'target'
        target.write_text('TEST-SECRET')
        path.symlink_to(target)
        self.report.warp({})
        self.assertNotIn('TEST-SECRET', self.output.getvalue())
        self.assertTrue(all(status == 'error' for status, _, _ in self.report.rows))

    def test_docker_timeout_and_missing_handshakes_are_not_zero_clients(self):
        with patch.object(diag, 'run', return_value=(False, 'DO NOT PRINT SECRET')):
            self.assertIsNone(self.report.awg())
        self.assertNotIn('SECRET', self.output.getvalue())
        with patch.object(diag, 'run', side_effect=[(True, 'true'), (True, 'awg=yes\nforward=yes')]):
            self.report.awg()
        self.assertIn('данные handshake недоступны', self.output.getvalue())
        self.assertNotIn('настроено в live AWG: 0', self.output.getvalue())

    def test_remote_control_characters_and_false_warp_confirmation_are_rejected(self):
        self.assertEqual(diag.trace_fields('ip=not-ip\nloc=DE\n'), {})
        data = diag.trace_fields('ip=192.0.2.1\nloc=DE\x1b[31m\nwarp=on\x1b[31m')
        self.assertEqual(data, {'ip': '192.0.2.1'})
        self.state()
        flags = dict(line.split('=', 1) for line in FLAGS.splitlines())
        with patch.object(diag, 'trace', return_value={'ip': '192.0.2.1', 'warp': 'off'}):
            self.report.warp(flags)
        self.assertTrue(any(status == 'error' and title == 'HTTPS через WARP' for status, title, _ in self.report.rows))

    def test_selected_rules_are_verified_with_validated_addresses_as_argv(self):
        self.state()
        with patch.object(diag, 'run', side_effect=self.fake):
            self.report.awg()
        command = self.calls[-1][0]
        self.assertEqual(command[-2:], ['govpn-report', '10.8.1.2/32'])
        self.assertNotIn('10.8.1.2/32', command[5])
        flags = dict(line.split('=', 1) for line in FLAGS.splitlines())
        del flags['selection']
        with patch.object(diag, 'trace', return_value={}):
            self.report.warp(flags)
        self.assertTrue(any(status == 'error' and title == 'Правила выбранных клиентов' for status, title, _ in self.report.rows))

    def test_probe_uses_hard_timeout_and_hides_exception_payload(self):
        with patch.object(diag.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['secret'], 0.1)) as call:
            self.assertEqual(diag.run(['fixture'], timeout=0.1), (False, ''))
        self.assertEqual(call.call_args.kwargs['timeout'], 0.1)

    def test_all_modes_skip_unavailable_checks(self):
        for mode in ('3xui', 'bridge', 'combo'):
            report = diag.Report(mode, 'amnezia-awg2', self.root, io.StringIO())
            with patch.object(diag, 'run', side_effect=self.fake), patch.object(diag.shutil, 'which', return_value='/fixture'):
                self.assertEqual(report.execute(), 0)

    def test_embedded_report_matches_source(self):
        embedded = SCRIPT.split("<<'GOVPN_DIAGNOSTICS_PY'\n", 1)[1].split('\nGOVPN_DIAGNOSTICS_PY', 1)[0]
        self.assertEqual(embedded, (ROOT / 'lib/diagnostics.py').read_text())


class EgressTests(unittest.TestCase):
    """A successful HTTPS response must not conceal a stale egress choice."""
    def report(self, source='8.8.8.8', addresses=('8.8.8.8',)):
        output = io.StringIO()
        report = diag.Report('amnezia', 'amnezia-awg2', output=output)
        report.host_route = {'dev': 'net0', 'source': source}
        report.addresses = list(addresses) if addresses is not None else None
        return report, output

    def check(self, report, external='8.8.8.8', ssh=''):
        with patch.dict(os.environ, {'SSH_CONNECTION': ssh}):
            report.egress({'ip': external} if external else {})
        return report.rows[-1][0]

    def test_old_egress_new_ssh_and_two_addresses_warn_without_repair(self):
        report, output = self.report(addresses=('8.8.8.8', '9.9.9.9'))
        with patch.object(diag, 'run') as command:
            self.assertEqual(self.check(report, ssh='192.0.2.1 12345 9.9.9.9 22'), 'warn')
        command.assert_not_called()
        for text in ('SSH и внешний выход различаются', 'несколько публичных IPv4', 'MASQUERADE',
                     'сохранение сетевой настройки', 'https://api.ipify.org', 'автоматически не определяется'):
            self.assertIn(text, output.getvalue())
        self.assertNotIn('192.0.2.1', output.getvalue())  # client identity is not displayed
        self.assertNotIn('error', [row[0] for row in report.rows])

    def test_multiple_addresses_without_ssh_still_reveal_ambiguous_choice(self):
        report, output = self.report(addresses=('8.8.8.8', '9.9.9.9'))
        self.assertEqual(self.check(report), 'warn')
        self.assertIn('это может быть намеренно', output.getvalue())
        self.assertNotIn('адрес текущего SSH:', output.getvalue())

    def test_multiple_addresses_do_not_pretend_to_identify_old_or_new(self):
        report, output = self.report('9.9.9.9', ('8.8.8.8', '9.9.9.9'))
        self.assertEqual(self.check(report, '9.9.9.9', '192.0.2.1 12345 9.9.9.9 22'), 'warn')
        self.assertNotIn('SSH и внешний выход различаются', output.getvalue())
        self.assertNotIn('неправильный', output.getvalue())

    def test_single_matching_address_is_observation_not_client_internet_claim(self):
        report, output = self.report()
        self.assertEqual(self.check(report, ssh='192.0.2.1 12345 8.8.8.8 22'), 'ok')
        self.assertIn('не проверка пути клиента', output.getvalue())

    def test_private_local_source_with_provider_nat_is_not_a_failure(self):
        report, output = self.report('10.0.0.2', ())
        self.assertEqual(self.check(report), 'ok')
        self.assertNotIn('ошибка', output.getvalue().lower())

    def test_public_source_translation_and_ssh_mismatch_are_cautions(self):
        for source, external, ssh in (
            ('8.8.8.8', '9.9.9.9', ''),
            ('10.0.0.2', '8.8.8.8', '192.0.2.1 12345 9.9.9.9 22'),
        ):
            report, output = self.report(source, ())
            self.assertEqual(self.check(report, external, ssh), 'warn')
            self.assertIn('это может быть намеренно', output.getvalue())

    def test_partial_or_missing_data_is_not_reported_as_verified(self):
        report, output = self.report(addresses=None)
        self.assertEqual(self.check(report), 'skip')
        self.assertIn('неполное', output.getvalue())
        report, _ = self.report()
        self.assertEqual(self.check(report, None), 'skip')
        report.host_route = {}
        self.assertEqual(self.check(report), 'skip')

    def test_route_and_address_parsers_reject_raw_control_strings_and_excess(self):
        invalid_routes = ('SECRET', '{}', '[]', '[null]', '[' + ' ' * 65536 + ']',
                          '[{"dev":"net0\\u001b[31m","prefsrc":"8.8.8.8"}]',
                          '[{"dev":"--bad","prefsrc":"8.8.8.8"}]',
                          '[{"dev":"net0","prefsrc":"bad"}]')
        for value in invalid_routes:
            with self.subTest(value=value[:70]), self.assertRaises((ValueError, TypeError)):
                diag.route_fields(value)
        for value in ('{}', '[null]', '[{"ifname":"wrong","addr_info":[]}]',
                      '[{"ifname":"net0","addr_info":[{"family":"inet","local":"SECRET"}]}]'):
            with self.assertRaises((ValueError, TypeError)):
                diag.public_addresses(value, 'net0')

    def test_private_ipv6_duplicate_and_multicast_addresses_are_not_public_ipv4(self):
        entries = [{'family': 'inet', 'local': ip} for ip in ('10.0.0.1', '127.0.0.1', '224.0.0.1', '8.8.8.8', '8.8.8.8')]
        entries.append({'family': 'inet6', 'local': '2001:db8::1'})
        self.assertEqual(diag.public_addresses(json.dumps([{'ifname': 'net0', 'addr_info': entries}]), 'net0'), ['8.8.8.8'])

    def test_ssh_hint_accepts_only_server_ipv4_and_bounded_port_fields(self):
        self.assertEqual(diag.ssh_server_ipv4('2001:db8::1 12345 9.9.9.9 22'), '9.9.9.9')
        for value in ('', '192.0.2.1 0 9.9.9.9 22', '192.0.2.1 12345 9.9.9.9 65536',
                      '192.0.2.1 12345 9.9.9.9\x1b[31m 22', '192.0.2.1 12345 2001:db8::1 22'):
            self.assertIsNone(diag.ssh_server_ipv4(value))

    def test_host_probe_is_bounded_and_uses_validated_interface_as_single_argument(self):
        report, _ = self.report()
        report.host_route, report.addresses = {}, None
        values = [(True, '[{"dev":"net0","prefsrc":"8.8.8.8"}]'),
                  (True, '[{"ifname":"net0","addr_info":[{"family":"inet","local":"8.8.8.8"},{"family":"inet","local":"9.9.9.9"}]}]')]
        with patch.object(diag, 'run', side_effect=values) as command, patch.object(diag.shutil, 'which', return_value='/fixture'):
            report.host()
        self.assertEqual(report.addresses, ['8.8.8.8', '9.9.9.9'])
        self.assertEqual(command.call_args_list[1].args[0], ['ip', '-j', '-4', 'address', 'show', 'dev', 'net0'])
        self.assertEqual(len(command.call_args_list), 2)

    def test_bad_probe_output_never_leaks_or_runs_repair(self):
        report, output = self.report()
        report.host_route, report.addresses = {}, None
        with patch.object(diag, 'run', return_value=(True, 'SECRET\x1b[31m')) as command, patch.object(diag.shutil, 'which', return_value='/fixture'):
            report.host()
        self.assertNotIn('SECRET', output.getvalue())
        self.assertNotIn('\x1b', output.getvalue())
        self.assertEqual(len(command.call_args_list), 1)
        self.assertEqual(self.check(report), 'skip')

    def test_execute_exposes_mismatch_despite_https_200(self):
        output = io.StringIO()
        report = diag.Report('bridge', '', output=output)
        calls = []

        def command(args, timeout=7):
            calls.append((args, timeout))
            if args[:5] == ['ip', '-j', '-4', 'route', 'get']:
                return True, '[{"dev":"net0","prefsrc":"8.8.8.8"}]'
            if args[:5] == ['ip', '-j', '-4', 'address', 'show']:
                return True, '[{"ifname":"net0","addr_info":[{"family":"inet","local":"8.8.8.8"},{"family":"inet","local":"9.9.9.9"}]}]'
            if diag.TRACE in args:
                return True, 'ip=8.8.8.8\nloc=NL\nwarp=off\n'
            if diag.GEMINI in args:
                return True, '200'
            raise AssertionError(args)

        with patch.object(diag, 'run', side_effect=command), patch.object(diag.shutil, 'which', return_value='/fixture'), patch.dict(os.environ, {'SSH_CONNECTION': '192.0.2.1 12345 9.9.9.9 22'}):
            self.assertEqual(report.execute(), 0)
        self.assertTrue(any(status == 'warn' and title == 'Выбор IP выхода' for status, title, _ in report.rows))
        self.assertIn('HTTP 200', output.getvalue())
        self.assertIn('Замечания: 1', output.getvalue())
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(timeout <= 8 for _, timeout in calls))
        self.assertTrue(all(timeout <= 7 for args, timeout in calls if args[0] == 'ip'))


if __name__ == '__main__':
    unittest.main()
