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


if __name__ == '__main__':
    unittest.main()
