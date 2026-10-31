"""Regression coverage for menu removal/reinstall on an existing legacy VPS."""
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_awg_warp import PROFILE, START, KEY, safe, ROOT


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ctl = safe.Controller('amnezia-awg2', self.root)
        safe.private_dir(self.ctl.directory)
        self.state = {'version': 1, 'profile': safe.profile(PROFILE), 'clients': ['10.8.1.2/32'], 'iface': 'awg0'}

    def saved(self):
        safe.write_private(self.ctl.directory / 'state.json', json.dumps(self.state))

    def legacy_read(self, path, optional=False):
        data = {safe.START: START, '/opt/amnezia/awg/awg0.conf': '[Interface]\nAddress = 10.8.1.1/24\n',
                '/opt/warp/warp.conf': PROFILE, '/opt/warp/clients.list': '10.8.1.2/32\n'}
        if path not in data and not optional:
            raise safe.SafeError('Missing fixture file')
        return data.get(path)

    def test_unpatch_preserves_vendor_start(self):
        self.assertEqual(safe.unpatch_start(safe.patch_start(START, 'awg0')), START)
        self.assertEqual(safe.unpatch_start(START), START)

    def test_adopt_legacy_without_manual_import(self):
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', side_effect=self.legacy_read):
            state = self.ctl.adopt()
        self.assertEqual(state['clients'], ['10.8.1.2/32'])
        self.assertEqual(state['profile'], safe.profile(PROFILE))
        self.assertFalse(state['enabled'])
        self.assertEqual(self.ctl.state(), state)

    def test_saved_host_profile_is_reused_without_overwrite(self):
        source = self.root / 'warp.conf'
        source.write_text(PROFILE)
        (self.root / 'clients.list').write_text('10.8.1.3/32\n')
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', side_effect=self.legacy_read):
            state = self.ctl.adopt()
        self.assertEqual(source.read_text(), PROFILE)
        self.assertEqual(state['clients'], ['10.8.1.3/32'])

    def test_no_state_does_not_prevent_removal(self):
        calls = []
        def docker(*args, **kwargs):
            calls.append(args)
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', side_effect=self.legacy_read), patch.object(self.ctl, 'docker', side_effect=docker):
            self.ctl.remove()
        self.assertEqual(calls[-1][-2:], ('remove', 'awg0'))
        self.assertFalse((self.ctl.directory / 'state.json').exists())
        self.assertTrue(list((self.ctl.directory / 'backups').glob('*.json')))
        self.assertFalse(any('apply' in call for call in calls))

    def test_missing_selection_cannot_silently_enable_direct_routing(self):
        def read(path, optional=False):
            return None if path.endswith('clients.list') else self.legacy_read(path, optional)
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', side_effect=read):
            with self.assertRaisesRegex(safe.SafeError, 'Список WARP-клиентов'):
                self.ctl.adopt()
            self.assertFalse((self.ctl.directory / 'state.json').exists())
            # An explicitly empty selection is allowed, including migration.
            self.assertEqual(self.ctl.adopt(selection=[])['clients'], [])

    def test_remove_marks_state_disabled_and_preserves_profile(self):
        self.saved()
        patched = safe.patch_start(START, 'awg0')
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', return_value=patched), patch.object(self.ctl, 'docker'):
            self.ctl.remove()
        self.assertFalse(self.ctl.state()['enabled'])
        self.assertEqual(self.ctl.state()['profile'], self.state['profile'])
        with self.assertRaisesRegex(safe.SafeError, 'setup'):
            self.ctl.prepare_stopped()

    def test_remove_failure_preserves_backup_and_stops_container(self):
        self.saved()
        self.ctl.target = 'pinned-id'
        calls = []
        def docker(*args, **kwargs):
            calls.append(args)
            if args[0] == 'exec' and 'remove' in args:
                raise safe.SafeError('fixture failure')
        with patch.object(self.ctl, 'inspect', return_value=True), patch.object(self.ctl, 'read_container', return_value=START), patch.object(self.ctl, 'docker', side_effect=docker):
            with self.assertRaises(safe.SafeError):
                self.ctl.remove()
        self.assertEqual(calls[-1], ('stop', '--time', '0', 'pinned-id'))

    def test_known_error_is_actionable_without_key_material(self):
        with patch.object(safe, 'main', side_effect=safe.SafeError('Нет сохраненного профиля.')), patch('sys.stderr') as stderr:
            self.assertEqual(safe.entry(), 1)
        output = ''.join(str(call) for call in stderr.write.call_args_list)
        self.assertIn('Нет сохраненного профиля', output)
        self.assertNotIn(KEY, output)

    def test_explicit_setup_can_prepare_stopped_container(self):
        self.saved()
        with patch.object(self.ctl, 'inspect', return_value=False), patch.object(self.ctl, 'read_container', return_value=START), patch.object(self.ctl, 'install') as install:
            self.assertFalse(self.ctl.deploy(self.state, allow_stopped=True))
        install.assert_called_once_with(self.state, safe.patch_start(START, 'awg0'), running=False)

    def menu_remove(self, answer):
        script = (ROOT / 'govpn.sh').read_text()
        wizard = script[script.index('warp_setup_wizard() {'):script.index('warp_test() {')]
        calls = self.root / 'calls'
        harness = '''
MODE=amnezia
AWG_CONTAINER=amnezia-awg2
clear() { :; }
is_amnezia() { return 0; }
is_3xui() { return 1; }
_awg_warp_running() { return 0; }
_awg_warp_ip() { echo 203.0.113.18; }
read_yn() { echo ANSWER; }
_awg_safe() { [ "$1" = selected ] || echo "$*" >> CALLS; }
'''.replace('CALLS', shlex.quote(str(calls))).replace('ANSWER', answer)
        wizard = wizard.replace('< /dev/tty', '< /dev/null')
        result = subprocess.run(['bash'], input=harness + wizard + '\nwarp_setup_wizard\n4\n', text=True,
                                capture_output=True, timeout=10)
        return result, calls

    def test_cancel_remove_does_not_fall_through_or_mutate(self):
        result, calls = self.menu_remove('n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('continue:', result.stderr)
        self.assertFalse(calls.exists())

    def test_confirmation_calls_remove_instead_of_empty_apply(self):
        result, calls = self.menu_remove('y')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('continue:', result.stderr)
        self.assertEqual(calls.read_text().strip(), 'remove')


if __name__ == '__main__':
    unittest.main()
