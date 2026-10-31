"""Local Linux reproduction of a vendor wg at every normal path.

Online access is used ONLY for trusted distro packages. No Cloudflare account,
WARP endpoint, user key or VPS is used. Vendor commands are synthetic stubs.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
from test_awg_warp import safe, PROFILE


def docker(*args):
    return subprocess.run(['docker', *args], capture_output=True, text=True, check=True, timeout=180)


context = json.loads(docker('context', 'inspect').stdout)[0]
endpoint = (os.environ.get('DOCKER_HOST') if not os.environ.get('DOCKER_CONTEXT') else '') or context['Endpoints']['docker']['Host']
if not endpoint.startswith('unix://'):
    raise SystemExit('Refusing non-local Docker endpoint')
debian = '--debian' in sys.argv
name = 'govpn-native-test-' + uuid.uuid4().hex[:12]
image = 'govpn-warp-test:local' if debian else 'python:3.13-alpine'
docker('run', '-d', '--name', name, '--cap-add', 'NET_ADMIN', '--entrypoint', 'sleep', image, '600')
try:
    if not debian:
        docker('exec', name, 'apk', 'add', '--no-cache', 'bash', 'iproute2', 'iptables')
    docker('exec', name, 'sh', '-c', '''printf '#!/bin/sh\n[ "$1" = --version ] && echo amneziawg-tools; exit 42\n' > /usr/bin/wg
cp /usr/bin/wg /usr/bin/wg-quick
cp /usr/bin/wg /usr/bin/awg
chmod 755 /usr/bin/wg /usr/bin/wg-quick /usr/bin/awg''')
    original = docker('exec', name, 'sha256sum', '/usr/bin/wg', '/usr/bin/awg', '/usr/bin/wg-quick').stdout
    with tempfile.TemporaryDirectory() as temp:
        ctl = safe.Controller(name, Path(temp))
        safe.private_dir(ctl.directory)
        tools = ctl.prepare_dependencies(install=True)
        assert tools == {'wg': 'private', 'wg_quick': 'private'}
        assert original == docker('exec', name, 'sha256sum', '/usr/bin/wg', '/usr/bin/awg', '/usr/bin/wg-quick').stdout
        # ELF runs inside Linux; the macOS host only retains the verified bytes.
        assert (ctl.directory / 'native-tools/wg').stat().st_size > 1000
        assert ctl.prepare_dependencies(install=False) == tools
        assert original == docker('exec', name, 'sha256sum', '/usr/bin/wg', '/usr/bin/awg', '/usr/bin/wg-quick').stdout
        # No network beyond this point: test a real private wg-quick kernel link
        # with synthetic credentials and a documentation-only unreachable endpoint.
        docker('network', 'disconnect', 'bridge', name)
        docker('exec', name, 'sh', '-c', '''mkdir -p /opt/amnezia/awg
printf '#!/bin/sh\n# fixture\ntail -f /dev/null\n' > /opt/amnezia/start.sh
printf '[Interface]\nAddress = 10.8.1.254/24\n' > /opt/amnezia/awg/awg0.conf
ip link add awg0 type dummy
ip link set awg0 up''')
        profile = Path(temp) / 'profile'
        profile.write_text(PROFILE.replace('engage.cloudflareclient.com:2408', '192.0.2.1:2408'))
        selected = Path(temp) / 'selected'
        selected.write_text('10.8.1.2/32\n')
        ctl.import_state(profile, selected, 'awg0')
        state = ctl.state()
        state['tools'] = tools
        ctl.deploy(state)
        assert 'warp' in docker('exec', name, 'ip', 'link', 'show', 'warp').stdout
        assert ctl.state()['tools'] == tools
        assert original == docker('exec', name, 'sha256sum', '/usr/bin/wg', '/usr/bin/awg', '/usr/bin/wg-quick').stdout
        ctl.remove()
    print('PASS: ' + ('Debian/Ubuntu authenticated download' if debian else 'signed Alpine extraction') + '; vendor tools unchanged; kernel probe; cached retry; actual private wg-quick up/down without external network')
finally:
    docker('rm', '-f', name)
