"""Route editor review/apply/result flow and context-aware WARP recovery."""
import subprocess
import unittest
from test_clients import function
from test_menu_flow import harness, shell
from test_terminal_ux import terminal


class RouteChangeTests(unittest.TestCase):
    def body(self, state='on', selected='10.9.1.3/32'):
        return function('_awg_change_client_route') + '''
STATE=STATE_VALUE
PERSISTED="SELECTION_VALUE"
CALLS=0
_awg_refresh_policy() { AWG_POLICY_ACTIVE="$STATE"; read -r -a AWG_POLICY_IPS <<< "$PERSISTED"; }
_awg_apply_rules() { CALLS=$((CALLS+1)); STATE=on; PERSISTED="$*"; echo BACKEND_RAW_MUST_BE_HIDDEN; }
read_yn() { echo y; }
'''.replace('STATE_VALUE',state).replace('SELECTION_VALUE',selected)

    def test_review_then_apply_verify_and_result_preserve_other_clients(self):
        result=shell(self.body()+'''\n_awg_change_client_route 10.8.1.2/32 warp "Fixture Phone"
printf 'FINAL:%s|%s\\n' "$CALLS" "$PERSISTED"
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('VPS -> WARP',result.stdout)
        self.assertIn('FINAL:1|10.9.1.3/32 10.8.1.2/32',result.stdout)
        self.assertNotIn('BACKEND_RAW',result.stdout)
        self.assertLess(result.stdout.index('Проверьте изменение'),result.stdout.index('[1/2]'))
        self.assertLess(result.stdout.index('[2/2]'),result.stdout.index('Выбор сохранен'))
        self.assertIn('Доступ к сайтам этим шагом не проверялся',result.stdout)

    def test_same_exit_is_noop_without_confirmation_or_apply(self):
        result=shell(self.body('on','10.8.1.2/32')+'''
read_yn() { echo UNEXPECTED >&2; }
_awg_change_client_route 10.8.1.2/32 warp
printf 'CALLS=%s\\n' "$CALLS"
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('уже выбран',result.stdout)
        self.assertIn('CALLS=0',result.stdout)
        self.assertNotIn('UNEXPECTED',result.stderr)

    def test_cancel_has_no_mutation(self):
        result=shell(self.body()+'''
read_yn() { echo n; }
_awg_change_client_route 10.8.1.2/32 warp; rc=$?
printf 'RESULT:%s|%s\\n' "$rc" "$CALLS"
''')
        self.assertIn('RESULT:2|0',result.stdout)
        self.assertNotIn('[1/2]',result.stdout)

    def test_starting_warp_for_one_client_does_not_resume_others_from_disabled_state(self):
        result=shell(self.body('off','10.9.1.3/32 10.9.1.4/32')+'''
_awg_change_client_route 10.8.1.2/32 warp
printf 'FINAL:%s\\n' "$PERSISTED"
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('FINAL:10.8.1.2/32\n',result.stdout)

    def test_apply_failure_does_not_claim_success_or_run_verification(self):
        result=shell(self.body()+'''
_awg_apply_rules() { return 7; }
_awg_change_client_route 10.8.1.2/32 warp
''')
        self.assertEqual(result.returncode,7,result.stderr)
        self.assertNotIn('Выбор сохранен',result.stdout)
        self.assertNotIn('[2/2]',result.stdout)
        self.assertIn('Изменение не завершено',result.stdout)

    def test_unverified_state_does_not_claim_success(self):
        result=shell(self.body()+'''
_awg_apply_rules() { :; }
_awg_change_client_route 10.8.1.2/32 warp
''')
        self.assertEqual(result.returncode,1,result.stderr)
        self.assertNotIn('Выбор сохранен',result.stdout)
        self.assertIn('Успех не подтвержден',result.stdout)

    def test_unknown_policy_cannot_apply(self):
        result=shell(self.body('unknown')+'''
_awg_change_client_route 10.8.1.2/32 warp; rc=$?
printf 'RESULT:%s|%s\\n' "$rc" "$CALLS"
''')
        self.assertIn('RESULT:1|0',result.stdout)


class TerminalRouteTests(unittest.TestCase):
    def terminal_body(self):
        return harness('amnezia')+'\n'+'\n'.join(function(n) for n in (
            '_menu_input','read_choice','ru_to_en','read_yn','_awg_show_client_menu',
            '_awg_edit_client_route','_awg_change_client_route','_awg_route_badge'))+'''
AWG_POLICY_ACTIVE=on; AWG_POLICY_IPS=(10.9.1.3/32)
_awg_client_name() { echo 'Fixture Phone'; }
_awg_refresh_policy() { :; }
_awg_apply_rules() { AWG_POLICY_IPS=("$@"); echo BACKEND_RAW; }
_awg_show_client_menu 10.8.1.2/32
'''

    def test_real_terminal_card_choose_review_apply_result_back(self):
        output=''.join(terminal(self.terminal_body(),[
            ('Выбор (Enter - назад):','1\n'),
            ('Выбор (Enter - назад):','2\n'),
            ('Сохранить этот выбор? (y/n):','y\n'),
            ('Enter - к карточке клиента...','\n'),
            ('Выбор (Enter - назад):','0\n'),
        ]))
        self.assertIn('Выберите выход в интернет',output)
        self.assertIn('VPS -> WARP',output)
        self.assertIn('Выбор сохранен',output)
        self.assertNotIn('BACKEND_RAW',output)
        self.assertNotIn('command not found',output)
        self.assertNotIn('Сведения о связи',output)

    def test_enter_from_exit_picker_returns_without_applying(self):
        output=''.join(terminal(self.terminal_body(),[
            ('Выбор (Enter - назад):','1\n'),
            ('Выбор (Enter - назад):','\n'),
            ('Выбор (Enter - назад):','0\n'),
        ]))
        self.assertNotIn('Сохранить этот выбор?',output)
        self.assertNotIn('Выбор сохранен',output)


class RecoveryUXTests(unittest.TestCase):
    def recovery(self, stage, managed=1, active=1, answer='1\n\n', confirm='y'):
        body=harness('amnezia')+'\n'+function('_awg_emergency_restore').replace('< /dev/tty','')+f'''
_awg_read_phase() {{ AWG_PHASE={stage}; AWG_PHASE_MANAGED={managed}; AWG_PHASE_ACTIVE={active}; }}
read_yn() {{ echo {confirm}; }}
_awg_run_operation() {{ echo APPLY:"$1"; }}
_awg_emergency_restore
'''
        return shell(body,answer)

    def test_stopped_recovery_is_only_prepare_and_does_not_start(self):
        result=self.recovery('stopped')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('останется остановленным',result.stdout)
        self.assertIn('APPLY:prepare-stopped',result.stdout)
        self.assertNotIn('APPLY:restore',result.stdout)
        self.assertNotIn('hook',result.stdout)

    def test_running_recovery_reapplies_saved_state_only(self):
        result=self.recovery('repair')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('APPLY:restore',result.stdout)
        self.assertNotIn('prepare-stopped',result.stdout)

    def test_disabled_or_unmanaged_warp_cannot_restore(self):
        for stage,managed,active in (('saved',1,0),('missing',0,0),('legacy',0,1)):
            result=self.recovery(stage,managed,active,answer='\n')
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('APPLY:',result.stdout)

    def test_cancel_cannot_apply(self):
        result=self.recovery('repair',confirm='n')
        self.assertNotIn('APPLY:',result.stdout)

    def test_list_and_main_do_not_show_heuristic_or_generic_awg_recovery(self):
        source=function('awg_peers_menu')
        self.assertNotIn('_awg_activity_label',source)
        self.assertNotIn('_awg_emergency_restore',source)
        self.assertNotIn('_awg_emergency_restore',function('show_menu'))
        self.assertNotIn('details',function('_awg_show_client_menu'))
        self.assertIn('_awg_emergency_restore',function('system_menu'))


if __name__ == '__main__':
    unittest.main()
