"""Real controlling-terminal navigation, progress and Enter semantics."""
import errno
import io
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from test_clients import function
from test_awg_warp import safe
from test_menu_flow import harness


def terminal(body, actions, timeout=5):
    """Send each key only after its prompt; always reap/stop the fixture child."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execlp('bash', 'bash', '-c', body)
    output = b''
    deadline = time.monotonic() + timeout
    try:
        for marker, answer in actions:
            while marker.encode() not in output:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError('Terminal deadline: ' + output.decode(errors='replace')[-1000:])
                if select.select([fd], [], [], min(remaining, .1))[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            chunk = b''
                        else:
                            raise
                    if not chunk:
                        raise AssertionError('Terminal closed: ' + output.decode(errors='replace')[-1000:])
                    output += chunk
            # Only search the next prompt after the answer. Return full output separately.
            os.write(fd, answer.encode())
            output += b'\nGOVPN_SENT\n'
            yield output.decode(errors='replace')
            output = b''
        while time.monotonic() < deadline:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                pid = 0
                if select.select([fd], [], [], .05)[0]:
                    try:
                        output += os.read(fd, 65536)
                    except OSError:
                        pass
                yield output.decode(errors='replace')
                if status != 0:
                    raise AssertionError('Fixture exit ' + str(status))
                return
            if select.select([fd], [], [], .05)[0]:
                try:
                    output += os.read(fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
        raise AssertionError('Fixture did not exit')
    finally:
        if pid:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except ProcessLookupError:
                pass
        os.close(fd)


class TerminalUXTests(unittest.TestCase):
    def test_real_tty_main_clients_refresh_back_and_enter_exit(self):
        body = harness('amnezia') + '\n' + '\n'.join(function(n) for n in (
            '_menu_input', 'read_choice', 'ru_to_en', 'show_menu', '_clients_hub',
            'awg_peers_menu', '_awg_refresh_clients', '_awg_client_name',
            '_awg_client_status', '_awg_route_label', '_awg_route_badge', '_awg_activity_label')) + '''
_awg_clients_data() {
 if [ "$1" = containers ]; then echo amnezia-awg2;
 else sleep .15; echo '10.8.1.2/32|Fixture Phone|0|не подключен'; fi
}
_awg_refresh_policy() { AWG_POLICY_ACTIVE=off; AWG_POLICY_IPS=(); }
show_menu
'''
        output = ''.join(terminal(body, [('Выбор (Enter - назад):', '1\n'),
                                        ('Выбор (Enter = обновить):', '\n'),
                                        ('Выбор (Enter = обновить):', '0\n'),
                                        ('Выбор (Enter - назад):', '\n')]))
        self.assertIn('Открываю клиентов', output)
        self.assertEqual(output.count('Fixture Phone'), 2)
        self.assertEqual(output.count('Получаю клиентов...'), 2)

    def test_empty_legacy_menu_selection_is_back_but_list_selection_refreshes(self):
        body = '\n'.join(function(n) for n in ('read_choice', 'ru_to_en')) + '''
a=$(read_choice 'Выбор: '); printf 'MENU=<%s>\\n' "$a"
a=$(read_choice 'Выбор (Enter = обновить): '); printf 'LIST=<%s>\\n' "$a"
'''
        output = ''.join(terminal(body, [('Выбор:', '\n'), ('Выбор (Enter = обновить):', '\n')]))
        self.assertIn('MENU=<>', output)
        self.assertIn('LIST=<>', output)

    def test_palette_separates_number_label_and_danger_without_colorized_data(self):
        body = function('_menu_begin') + '\n' + function('_menu_add') + r'''
YELLOW='\033[33m'; WHITE='\033[37m'; RED='\033[31m'; NC='\033[0m'
_menu_begin; _menu_add clients 'Clients'; _menu_add recovery 'Recovery'
'''
        result = subprocess.run(['bash', '-c', body], text=True, capture_output=True, timeout=5)
        self.assertIn('\033[33m[1]\033[0m \033[37mClients\033[0m', result.stdout)
        self.assertIn('\033[31m[2]', result.stdout)

    def test_operation_failure_keeps_status_and_no_success_summary(self):
        body = function('_awg_run_operation') + '''
_awg_safe() { echo 'fixture failure' >&2; return 7; }
_awg_read_phase() { echo UNEXPECTED; }
_awg_run_operation setup
'''
        result = subprocess.run(['bash', '-c', body], text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 7)
        self.assertIn('код 7', result.stdout)
        self.assertIn('Время:', result.stdout)
        self.assertNotIn('Настройки применены', result.stdout)
        self.assertNotIn('UNEXPECTED', result.stdout)

    def test_operation_summary_distinguishes_prepared_and_incomplete_state(self):
        for stage, expected in (('ready', 'туннель и маршрут найдены'), ('stopped', 'еще не запущено'), ('repair', 'не подтверждены')):
            body = function('_awg_run_operation') + '\n_awg_safe() { echo BACKEND_INTERNAL; }; _awg_read_phase() { AWG_PHASE=' + stage + '; AWG_PHASE_COUNT=20; }; _awg_run_operation setup'
            result = subprocess.run(['bash', '-c', body], text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
            self.assertIn('Выбранных клиентов: 20', result.stdout)
            self.assertNotIn('BACKEND_INTERNAL', result.stdout)
            if stage != 'ready':
                self.assertNotIn('Настройки применены', result.stdout)

    def test_progress_is_opt_in_fixed_messages_to_stderr(self):
        output = io.StringIO()
        with patch.dict(os.environ, {'GOVPN_PROGRESS': '1', 'NO_COLOR': '1'}), patch.object(safe.sys, 'stderr', output):
            safe.progress('Fixture stage')
        self.assertIn('Шаг', output.getvalue())
        self.assertIn('Fixture stage', output.getvalue())
        self.assertNotIn('\033', output.getvalue())
        output = io.StringIO()
        with patch.dict(os.environ, {'GOVPN_PROGRESS': '0'}), patch.object(safe.sys, 'stderr', output):
            safe.progress('Hidden')
        self.assertEqual(output.getvalue(), '')

    def test_header_statistics_executes_one_aggregate_script(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            command = root / 'awg'
            command.write_text('#!/bin/sh\nprintf "A\\t' + str(int(time.time())) + '\\nB\\t0\\n"\n')
            command.chmod(0o755)
            command = root / 'ip'
            command.write_text('#!/bin/sh\nexit 0\n')
            command.chmod(0o755)
            body = function('get_awg_stats') + '\n' + function('_fmt_bytes') + '''
AWG_CONTAINER=amnezia-awg2
is_amnezia() { return 0; }
_docker_read() { shift 4; sh -c "$1"; }
get_awg_stats
'''
            result = subprocess.run(['bash', '-c', body], env=dict(os.environ, PATH=temp + ':' + os.environ['PATH']),
                                    text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('2 клиентов', result.stdout)
            self.assertNotIn('активны', result.stdout)

    def test_simplified_warp_and_diagnostics_hide_manual_tools(self):
        warp = function('_awg_warp_screen')
        diagnostic = function('tools_menu')
        self.assertNotIn('Заменить профиль', warp)
        self.assertNotIn('сохранить профиль', warp)
        self.assertNotIn('_awg_create_warp_conf', warp)
        self.assertNotIn('_awg_create_warp_conf', function('_awg_install_warp'))
        for old in ('_site_check', '_speed_test', '_run_ipregion'):
            self.assertNotIn(old, diagnostic)
        self.assertIn('_connection_report', diagnostic)


if __name__ == '__main__':
    unittest.main()
