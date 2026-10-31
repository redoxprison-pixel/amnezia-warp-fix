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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
from test_awg_warp import PROFILE, safe


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
        # Fresh server: no legacy profile/list/state. Import the synthetic profile
        # through bootstrap, with real dependency/firewall/kernel preflight.
        first = safe.Controller(name, root / 'first-install')
        safe.private_dir(first.directory)
        assert first.bootstrap(['10.8.1.2/32'], source=profile)
        assert first.state()['clients'] == ['10.8.1.2/32']
        assert first.state()['enabled']
        assert docker('exec', name, 'ip', 'link', 'show', 'warp', check=False).returncode == 0
        try:
            first.bootstrap(['10.8.1.2/32'], source=profile)
            raise AssertionError('Fresh bootstrap overwrote existing profile')
        except safe.SafeError as error:
            assert 'Профиль уже существует' in str(error)
        first.remove()
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
