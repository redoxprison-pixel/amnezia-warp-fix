"""Full menu navigation with fake Docker, bounded waits and state-based WARP."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from test_clients import function, clients
from test_awg_warp import safe, PROFILE, START

MENUS = '\n'.join(function(n) for n in ('_menu_begin', '_menu_add', '_menu_read'))


def shell(body, data='0\n', env=None):
    return subprocess.run(['bash', '-c', body], input=data, text=True,
                          capture_output=True, timeout=8, env=env)


def harness(mode):
    return MENUS + '\n' + '''
MODE=MODE_VALUE
AWG_CONTAINER=amnezia-awg2
VERSION=6.69
clear() { :; }
is_amnezia() { [[ "$MODE" = amnezia || "$MODE" = combo ]]; }
is_3xui() { [[ "$MODE" = 3xui || "$MODE" = combo ]]; }
is_bridge() { [[ "$MODE" = bridge ]]; }
_menu_input() { IFS= read -r "$1"; }
read_choice() { local choice; read -r choice; printf '%s' "$choice"; }
get_sys_stats() { echo fixture; }; get_awg_stats() { echo fixture; }
_update_cached_ver() { :; }; warp_overall_status() { echo fixture; }
_mtg_count_running() { echo 0; }
'''.replace('MODE_VALUE', mode)


class MenuFlowTests(unittest.TestCase):
    def assert_consecutive(self, output):
        numbers = [int(n) for n in re.findall(r'^  \[(\d+)\]', output, re.M) if n != '0']
        self.assertTrue(numbers)
        self.assertEqual(numbers, list(range(1, len(numbers) + 1)))

    def test_main_and_optional_menus_are_consecutive_in_all_modes(self):
        for mode in ('amnezia', '3xui', 'combo', 'bridge'):
            for menu in ('show_menu', '_additional_services_menu', 'tools_menu'):
                with self.subTest(mode=mode, menu=menu):
                    result = shell(harness(mode) + '\n' + function(menu) + '\n' + menu)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_consecutive(result.stdout)

    def test_main_header_rejects_old_notice_even_if_cache_reader_returns_it(self):
        for version, expected in (('6.65', False), ('6.69', False), ('6.69.0', False), ('99.0', True)):
            body = harness('amnezia') + '\n' + function('_ver_lt') + '\n' + function('show_menu')
            body += f'\n_update_cached_ver() {{ echo {version}; }}\nshow_menu'
            result = shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual('Доступна v' in result.stdout, expected)

    def test_service_restart_numbers_have_no_gaps(self):
        for mode in ('amnezia', '3xui', 'combo'):
            result = shell(harness(mode) + '\n' + function('_service_restart_menu') + '\n_service_restart_menu')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_consecutive(result.stdout)

    def test_system_menu_keeps_update_second_and_has_consecutive_numbers(self):
        body = harness('amnezia') + '\n' + function('system_menu') + '''
_domain_detect_short() { echo fixture; }
BACKUP_DIR=/does-not-exist
system_menu
'''
        result = shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_consecutive(result.stdout)
        self.assertIn('[2] Обновить скрипт', result.stdout)
        self.assertIn('[3] SSH:', result.stdout)

    def test_real_client_menu_reaches_list_and_returns_without_n_plus_one_reads(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            docker = root / 'docker'
            log = root / 'calls'
            table = json.dumps([{'clientId': f'K{i}', 'userData': {'clientName': f'Test Phone {i}'}} for i in range(1, 32)])
            config = ''.join(f'[Peer]\nPublicKey=K{i}\nAllowedIPs=10.8.1.{i}/32\n' for i in range(1, 32))
            frame = ('GOVPN_CONFIG\n' + config + '\nGOVPN_TABLE\n' + table
                     + '\nGOVPN_ALLOWED\n\nGOVPN_HANDSHAKES\nGOVPN_HANDSHAKE_OK\nGOVPN_DONE\n')
            docker.write_text('#!/usr/bin/env python3\nimport sys,pathlib\np=pathlib.Path(' + repr(str(log)) + ')\n'
                              + 'with p.open("a") as f: f.write(sys.argv[1]+"\\n")\n'
                              + 'print("amnezia-awg2" if sys.argv[1]=="ps" else ' + repr(frame) + ')\n')
            docker.chmod(0o755)
            body = harness('amnezia') + '\n' + '\n'.join(function(n) for n in (
                'show_menu', '_clients_hub', 'awg_peers_menu', '_awg_refresh_clients',
                '_awg_client_name', '_awg_client_status', '_awg_route_label', '_awg_route_badge', '_awg_activity_label')) + '\n'
            body += '_awg_clients_data() { python3 ' + shlex.quote(str(Path(__file__).resolve().parents[1] / 'lib/awg_clients.py')) + ' "$AWG_CONTAINER" "$@"; }\n'
            body += '_awg_refresh_policy() { AWG_POLICY_ACTIVE=off; AWG_POLICY_IPS=(); }; show_menu\n'
            result = shell(body, '1\n0\n0\n', dict(os.environ, PATH=str(root) + ':' + os.environ['PATH']))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Загружаю список', result.stdout)
            self.assertIn('Test Phone 31', result.stdout)
            self.assertEqual(log.read_text().splitlines(), ['ps', 'exec'])

    def test_stalled_docker_has_real_deadline(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'docker'
            path.write_text('#!/usr/bin/env python3\nimport time\ntime.sleep(5)\n')
            path.chmod(0o755)
            start = time.monotonic()
            with patch.dict(os.environ, {'PATH': temp + ':' + os.environ['PATH']}), patch.object(clients, 'READ_TIMEOUT', 0.1):
                with self.assertRaisesRegex(clients.ClientError, 'не ответил'):
                    clients.fast_snapshot('amnezia-awg2')
            self.assertLess(time.monotonic() - start, 1)

    def test_missing_warp_offers_setup_first_and_no_test_or_remove(self):
        body = harness('amnezia') + '\n' + function('_awg_warp_screen') + '''
_awg_read_phase() { AWG_PHASE=missing; AWG_PHASE_MANAGED=0; AWG_PHASE_ACTIVE=0; AWG_PHASE_COUNT=0; }
_awg_warp_screen
'''
        result = shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[1] Подключить WARP', result.stdout)
        self.assertNotIn('Проверить выход', result.stdout)
        self.assertNotIn('Отключить WARP,', result.stdout)
        self.assert_consecutive(result.stdout)

    def test_all_warp_stages_have_consecutive_choices(self):
        for stage in ('pending', 'saved', 'legacy', 'ready', 'repair', 'stopped'):
            active = int(stage in ('ready', 'repair'))
            managed = int(stage != 'legacy')
            body = harness('amnezia') + '\n' + function('_awg_warp_screen') + f'\n_awg_read_phase() {{ AWG_PHASE={stage}; AWG_PHASE_MANAGED={managed}; AWG_PHASE_ACTIVE={active}; AWG_PHASE_COUNT=2; }}\n_awg_warp_screen'
            result = shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_consecutive(result.stdout)

    def test_failed_exit_check_requires_consent_before_restore(self):
        body = harness('amnezia') + '\n' + function('_awg_warp_screen').replace('< /dev/tty', '') + '''
_awg_read_phase() { AWG_PHASE=ready; AWG_PHASE_MANAGED=1; AWG_PHASE_ACTIVE=1; AWG_PHASE_COUNT=2; }
warp_test() { echo TEST_FAILED; return 1; }
read_yn() { echo n; }
_awg_install_warp() { echo UNEXPECTED_RESTORE; }
_awg_warp_screen
'''
        result = shell(body, '1\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TEST_FAILED', result.stdout)
        self.assertNotIn('UNEXPECTED_RESTORE', result.stdout)


class PhaseTests(unittest.TestCase):
    def test_phase_distinguishes_missing_pending_disabled_repair_and_ready(self):
        with tempfile.TemporaryDirectory() as temp:
            ctl = safe.Controller('amnezia-awg2', Path(temp))
            safe.private_dir(ctl.directory)
            def docker(*args, **kwargs):
                return subprocess.CompletedProcess([], 0, '')
            with patch.object(ctl, 'inspect', return_value=True), patch.object(ctl, 'docker', side_effect=docker):
                self.assertEqual(ctl.phase()['stage'], 'missing')
                (ctl.directory / 'registration').mkdir()
                (ctl.directory / 'registration/wgcf-account.toml').write_text('synthetic')
                self.assertEqual(ctl.phase()['stage'], 'pending')
                state = {'version':1, 'profile':safe.profile(PROFILE), 'clients':[], 'iface':'awg0', 'enabled':False}
                safe.write_private(ctl.directory / 'state.json', json.dumps(state))
                self.assertEqual(ctl.phase()['stage'], 'saved')
                state['enabled'] = True
                safe.write_private(ctl.directory / 'state.json', json.dumps(state))
                self.assertEqual(ctl.phase()['stage'], 'repair')
            with patch.object(ctl, 'inspect', return_value=True), patch.object(ctl, 'docker', return_value=subprocess.CompletedProcess([], 0, 'active\npolicy\n')):
                self.assertEqual(ctl.phase()['stage'], 'ready')
            with patch.object(ctl, 'inspect', return_value=False):
                self.assertEqual(ctl.phase()['stage'], 'stopped')


if __name__ == '__main__':
    unittest.main()
