"""Opt-in, disposable LOCAL Docker integration test; never use a remote daemon."""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
from test_awg_warp import PROFILE, safe
from test_clients import clients
sys.path.insert(0, str(ROOT / 'lib'))
import diagnostics
import io


def docker(*args, check=True):
    return subprocess.run(['docker', *args], check=check, capture_output=True, text=True, timeout=120)


host = os.environ.get('DOCKER_HOST', '')
context = json.loads(docker('context', 'inspect').stdout)[0]
endpoint = host or context['Endpoints']['docker']['Host']
if not endpoint.startswith('unix://'):
    sys.exit('Refusing non-local Docker endpoint: ' + endpoint)
name = 'govpn-test-' + uuid.uuid4().hex[:12]
image = os.environ.get('GOVPN_TEST_IMAGE', 'govpn-warp-test:local')
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    profile = root / 'profile'
    selected = root / 'selected'
    profile.write_text(PROFILE)
    selected.write_text('10.8.1.2/32\n')
    fixture_args = ['--name', name, '--network', 'none', '--cap-add', 'NET_ADMIN',
           '--sysctl', 'net.ipv6.conf.all.disable_ipv6=0',
           '--sysctl', 'net.ipv4.ip_forward=1', '--sysctl', 'net.ipv6.conf.all.forwarding=1',
           '--sysctl', 'net.ipv4.conf.all.rp_filter=0', '--sysctl', 'net.ipv4.conf.default.rp_filter=0', image]
    docker('run', '-d', *fixture_args)
    try:
        ctl = safe.Controller(name, root)
        safe.private_dir(ctl.directory)
        for attempt in range(30):
            if docker('exec', name, 'ip', 'link', 'show', 'awg0', check=False).returncode == 0:
                break
            time.sleep(0.1)
        assert ctl.phase()['stage'] == 'missing'
        # The client screen obtains a real snapshot in one exec and excludes
        # secret fields before copying any config text out of the container.
        test_config = root / 'server.conf'
        test_config.write_text('[Interface]\nAddress=10.8.1.1/24\nPrivateKey=fixture-only-private\n[Peer]\nPublicKey=A\nPresharedKey=fixture-only-psk\nAllowedIPs=10.8.1.2/32\n')
        docker('cp', str(test_config), name + ':/opt/amnezia/awg/awg0.conf')
        table = root / 'clientsTable'
        table.write_text(json.dumps([{'clientId':'A', 'userData':{'clientName':'Fixture Phone'}}]))
        docker('cp', str(table), name + ':/opt/amnezia/awg/clientsTable')
        real_run = subprocess.run
        def inspect_snapshot(*args, **kwargs):
            result = real_run(*args, **kwargs)
            assert 'fixture-only-private' not in result.stdout
            assert 'fixture-only-psk' not in result.stdout
            return result
        with patch.object(clients.subprocess, 'run', side_effect=inspect_snapshot):
            rows = clients.fast_snapshot(name)
        assert rows[0]['name'] == 'Fixture Phone'
        print('bounded single-exec client snapshot and secret filtering: PASS')
        # Fresh server: no legacy profile/list/state. Import the synthetic profile
        # through bootstrap, with real dependency/firewall/kernel preflight.
        first = safe.Controller(name, root / 'first-install')
        safe.private_dir(first.directory)
        # Reproduce a vendor AWG command shadowing the distro's standard wg.
        docker('exec', name, 'sh', '-c', 'printf "#!/bin/sh\nexit 42\n" > /usr/local/bin/wg; chmod 755 /usr/local/bin/wg')
        prepare = first.prepare_dependencies
        def fixture_tools(*args, **kwargs):
            tools = prepare(*args, **kwargs)
            assert tools['wg'] == '/usr/bin/wg'
            # Keep the WARP data path deterministic and offline.
            tools['wg_quick'] = '/usr/local/bin/wg-quick'
            return tools
        with patch.object(first, 'prepare_dependencies', side_effect=fixture_tools):
            assert first.bootstrap(['10.8.1.2/32'], source=profile)
        assert first.state()['clients'] == ['10.8.1.2/32']
        assert first.state()['enabled']
        assert first.phase()['stage'] == 'ready'
        # Exercise the actual read-only report against real kernel rules.
        report = diagnostics.Report('amnezia', name, first.root, io.StringIO())
        flags = report.awg()
        assert flags['selection'] == 'yes'
        report.warp(flags)
        assert not any(row[0] == 'error' for row in report.rows), report.rows
        docker('exec', name, 'ip6tables', '-D', 'INPUT', '-i', 'awg0', '-m', 'comment',
               '--comment', 'govpn-warp-ipv6', '-j', 'DROP')
        broken = diagnostics.Report('amnezia', name, first.root, io.StringIO())
        broken.warp(broken.awg())
        assert any(row[0] == 'error' and row[1] == 'Запрет IPv6 INPUT' for row in broken.rows)
        docker('exec', name, 'ip6tables', '-I', 'INPUT', '1', '-i', 'awg0', '-m', 'comment',
               '--comment', 'govpn-warp-ipv6', '-j', 'DROP')
        print('read-only report detects selected-client rules and missing IPv6 guard: PASS')
        startup = docker('exec', name, 'cat', '/opt/amnezia/start.sh').stdout
        release = re.search(r'/opt/govpn-warp/[a-f0-9]+', startup)[0]
        docker('exec', name, release + '/tool-bin/wg', 'show', 'interfaces')
        assert docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode == 0
        try:
            first.bootstrap(['10.8.1.2/32'], source=profile)
            raise AssertionError('Fresh bootstrap overwrote existing profile')
        except safe.SafeError as error:
            assert 'Профиль уже существует' in str(error)
        first.remove()
        assert first.phase()['stage'] == 'saved'
        docker('exec', name, 'rm', '/usr/local/bin/wg')
        print('fresh bootstrap/preflight/persistence/repeat protection: PASS')
        # Simulate the user's running legacy installation with no state.json.
        docker('exec', name, 'mkdir', '-p', '/opt/warp')
        docker('cp', str(profile), name + ':/opt/warp/warp.conf')
        docker('cp', str(selected), name + ':/opt/warp/clients.list')
        docker('exec', name, 'wg-quick', 'up', '/opt/warp/warp.conf')
        docker('exec', name, 'iptables', '-t', 'mangle', '-N', 'AWG_WARP')
        docker('exec', name, 'iptables', '-t', 'mangle', '-A', 'AWG_WARP', '-j', 'MARK', '--set-mark', '100')
        docker('exec', name, 'iptables', '-t', 'mangle', '-A', 'PREROUTING', '-i', 'awg0', '-j', 'AWG_WARP')
        ctl.remove()
        assert docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode != 0
        assert not (ctl.directory / 'state.json').exists()
        state = ctl.adopt()
        assert state['clients'] == ['10.8.1.2/32']
        state['enabled'] = True
        docker('cp', str(ROOT / 'govpn.sh'), name + ':/tmp/govpn.sh')
        version = re.search(r'^VERSION="([^"]+)"', (ROOT / 'govpn.sh').read_text(), re.M)[1]
        assert 'v' + version in docker('exec', name, 'bash', '/tmp/govpn.sh', 'version').stdout
        docker('exec', name, 'bash', '/tmp/govpn.sh', 'warp-safe', name, '--help')
        # Exact old GoVPN mark is migrated; unrelated table 100 entries survive.
        docker('exec', name, 'ip', '-4', 'route', 'add', 'default', 'dev', 'uplink', 'table', '100')
        docker('exec', name, 'ip', '-4', 'rule', 'add', 'priority', '100', 'fwmark', '100', 'lookup', '100')
        docker('exec', name, 'ip', '-4', 'rule', 'add', 'priority', '200', 'from', '10.8.1.77/32', 'lookup', '100')
        docker('exec', name, 'iptables', '-t', 'mangle', '-A', 'PREROUTING', '-i', 'awg0', '-j', 'MARK', '--set-mark', '100')
        ctl.deploy(state)
        assert 'from 10.8.1.77 lookup 100' in docker('exec', name, 'ip', '-4', 'rule', 'show').stdout
        assert 'default dev uplink' in docker('exec', name, 'ip', '-4', 'route', 'show', 'table', '100').stdout
        # Real wg-quick parses the sanitized profile, without printing its keys.
        startup = docker('exec', name, 'cat', '/opt/amnezia/start.sh').stdout
        runtime = re.search(r'/opt/govpn-warp/[a-f0-9]+/runtime.sh', startup)[0]
        docker('exec', name, '/usr/bin/wg-quick', 'strip', runtime.removesuffix('runtime.sh') + 'warp.conf')

        def probe(source, expected):
            print(docker('exec', name, 'python3', '/usr/local/bin/probe.py', source, expected).stdout.strip())

        def check_paths():
            probe('10.8.1.2', 'warp')
            probe('10.8.1.3', 'uplink')
            probe('10.8.1.99', 'uplink')
            probe('fd00:1::2', 'drop')

        check_paths()
        # Removal does not depend on tunnel startup, even when wg-quick fails.
        docker('exec', name, 'touch', '/tmp/fail-warp')
        ctl.remove()
        assert not ctl.state()['enabled']
        assert safe.BEGIN not in docker('exec', name, 'cat', '/opt/amnezia/start.sh').stdout
        assert docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode != 0
        assert 'from 10.8.1.77 lookup 100' in docker('exec', name, 'ip', '-4', 'rule', 'show').stdout
        probe('10.8.1.2', 'uplink')
        probe('fd00:1::2', 'uplink')
        ctl.remove()  # repeat removal is idempotent
        docker('restart', name)
        time.sleep(1)
        probe('10.8.1.2', 'uplink')
        assert docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode != 0
        docker('exec', name, 'rm', '-f', '/tmp/fail-warp')
        state = ctl.state()
        state['enabled'] = True
        ctl.deploy(state)
        check_paths()
        def rules():
            # iptables-save adds generated/completed timestamps; compare rules.
            return '\n'.join(line for line in docker('exec', name, 'iptables-save').stdout.splitlines()
                             if line and not line.startswith('#'))
        first = rules()
        ctl.deploy(ctl.state())
        assert first == rules()
        check_paths()
        docker('restart', name)
        for attempt in range(50):
            if docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode == 0:
                break
            time.sleep(0.1)
        check_paths()
        # Physical tunnel loss must retain both unreachable fallback and filter.
        docker('exec', name, 'ip', 'link', 'delete', 'warp')
        probe('10.8.1.2', 'drop')
        probe('10.8.1.3', 'uplink')
        # Even if our policy rule is lost, the forwarding guard prevents leaks.
        docker('exec', name, 'ip', '-4', 'rule', 'del', 'priority', '10900')
        probe('10.8.1.2', 'drop')
        ctl.deploy(ctl.state())
        # Explicitly empty selection survives restart and routes IPv4 direct.
        state = ctl.state()
        state['clients'] = []
        ctl.deploy(state)
        probe('10.8.1.2', 'uplink')
        docker('restart', name)
        time.sleep(1)
        probe('10.8.1.2', 'uplink')
        probe('fd00:1::2', 'drop')
        state['clients'] = ['10.8.1.2/32']
        docker('exec', name, 'touch', '/tmp/fail-warp')
        try:
            ctl.deploy(state)
        except safe.SafeError:
            pass
        else:
            raise AssertionError('Expected tunnel failure')
        assert not json.loads(docker('inspect', name).stdout)[0]['State']['Running']
        assert ctl.state()['clients'] == ['10.8.1.2/32']
        # Supported Docker cp into a stopped container; no storage internals.
        ctl.prepare_stopped()
        # Recreate remains stopped until the saved hook/configuration is installed.
        docker('rm', name)
        docker('create', *fixture_args)
        state = ctl.state()
        state['enabled'] = True
        assert not ctl.deploy(state, allow_stopped=True)
        assert not json.loads(docker('inspect', name).stdout)[0]['State']['Running']
        docker('start', name)
        for attempt in range(50):
            if docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode == 0:
                break
            time.sleep(0.1)
        check_paths()
        print('PASS: legacy removal without import, migration, removal with failed wg-quick, repeat removal, removed restart, reinstall; CLI, wg-quick parse, foreign routes, kernel packet paths, repeat apply, restart, empty selection, tunnel loss, fail-closed stop, stopped restore, recreate')
    finally:
        docker('rm', '-f', name, check=False)
