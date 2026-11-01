"""Regression coverage for retired installers/key menus and honest repair actions."""
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_clients import function, SCRIPT
from test_connection_report import diag
from test_menu_flow import harness, shell


class MenuCleanupTests(unittest.TestCase):
    def test_awg_list_has_no_create_delete_or_secret_profile_actions(self):
        source = function('awg_peers_menu')
        for action in ('_awg_add_peer', '_awg_del_peer', 'Конфиг / QR', '[+]','[-]'):
            self.assertNotIn(action,source)
        card = function('_awg_show_client_menu')
        for action in ('profile-hint','profile-import','_awg_show_qr','_awg_show_config','_awg_del_peer'):
            self.assertNotIn(action,card)
        self.assertIn('_awg_change_client_route',card)

    def test_retired_creation_and_deletion_cannot_touch_docker_even_if_called(self):
        for name in ('_awg_add_peer','_awg_del_peer','install_wizard'):
            result = shell(function(name) + '\ndocker() { echo UNEXPECTED; }; ' + name)
            self.assertEqual(result.returncode,2)
            self.assertNotIn('UNEXPECTED',result.stdout)

    def test_extra_menu_hides_protocols_proxies_and_scanner(self):
        result = shell(harness('amnezia')+'\n'+function('_additional_services_menu')+'\n_additional_services_menu')
        self.assertIn('OpenFlux',result.stdout)
        self.assertIn('Российские сети',result.stdout)
        for text in ('Установка компонентов','MTProto','Reality','SSL'):
            self.assertNotIn(text,result.stdout)

    def test_main_palette_has_no_bold_and_menu_has_spaces_between_groups(self):
        self.assertIn("WHITE='\\033[0;37m'",SCRIPT)
        self.assertIn("YELLOW='\\033[0;33m'",SCRIPT)
        result = shell(harness('amnezia')+'\n'+function('show_menu')+'\nshow_menu')
        self.assertIn('\n\nПроверка и обслуживание',result.stdout)
        self.assertIn('\n\nДополнительно',result.stdout)

    def test_route_badges_and_compact_activity_do_not_assert_working_internet(self):
        body='\n'.join(function(n) for n in ('_awg_route_badge','_awg_activity_label'))+'''
AWG_POLICY_ACTIVE=on; AWG_POLICY_IPS=(10.8.1.2/32)
_awg_route_badge 10.8.1.2/32; echo; _awg_route_badge 10.8.1.3/32; echo
AWG_CLIENT_IPS=(10.8.1.2/32); AWG_CLIENT_STAMPS=(0); AWG_CLIENT_STATUS=('нет handshake')
_awg_activity_label 10.8.1.2/32
'''
        result = shell(body)
        self.assertIn('[WARP]\n[VPS]',result.stdout)
        self.assertIn('нет свежей связи',result.stdout)
        self.assertNotIn('handshake',result.stdout)

    def test_dependency_screen_does_not_offer_system_wgcf_download_or_eval(self):
        source = function('_check_deps_full')
        self.assertNotIn('eval',source)
        self.assertNotIn('wgcf',source)
        self.assertIn('GOVPN_DIAG_SCOPE=repair',source)
        source = function('_connection_repair_menu')
        self.assertIn('AWG_PHASE_MANAGED',source)
        self.assertIn('AWG_PHASE_ACTIVE',source)
        self.assertIn('Восстановить сохраненную',source)


class DependencyRepairTests(unittest.TestCase):
    def test_working_awg_does_not_require_wgcf_host_wireguard_yaml_or_qr(self):
        output=io.StringIO()
        def which(name):
            return '/fixture/'+name if name in (*diag.BASE_TOOLS,'docker') else None
        with patch.object(diag.shutil,'which',side_effect=which), patch.object(diag.sys,'stdout',output):
            self.assertEqual(diag.dependency_report('amnezia'),0)
        self.assertIn('только для первой регистрации',output.getvalue())
        self.assertNotIn('[X]',output.getvalue())

    def test_repair_rechecks_tools_and_does_not_report_false_success(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'lock'
            with patch.object(diag.os,'geteuid',return_value=0), patch.object(diag,'dependency_plan',return_value=(['curl'],'apt-get',['curl'])), patch.object(diag,'run',return_value=(True,'')) as run, patch.object(diag.shutil,'which',return_value=None):
                self.assertEqual(diag.repair_dependencies(path),1)
            self.assertEqual(run.call_args_list[0].args[0],['apt-get','update'])
            self.assertEqual(run.call_args_list[1].args[0],['apt-get','install','-y','--no-install-recommends','curl'])
            self.assertEqual(run.call_args_list[1].kwargs['env']['DEBIAN_FRONTEND'],'noninteractive')

    def test_failed_package_index_prevents_install(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(diag.os,'geteuid',return_value=0), patch.object(diag,'dependency_plan',return_value=(['curl'],'apt-get',['curl'])), patch.object(diag,'run',return_value=(False,'')) as run:
                self.assertEqual(diag.repair_dependencies(Path(temp)/'lock'),1)
            self.assertEqual(run.call_count,1)

    def test_complete_dependencies_do_not_run_package_manager(self):
        with patch.object(diag.os,'geteuid',return_value=0), patch.object(diag,'dependency_plan',return_value=([],None,[])), patch.object(diag,'run') as run:
            self.assertEqual(diag.repair_dependencies(),0)
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
