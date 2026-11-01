"""Real iproute2 multi-address fixture. Local, offline, disposable Linux only.

The HTTPS fields are synthetic. This does not test Gemini, Cloudflare or any VPS.
"""
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def docker(*args):
    result = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


context = json.loads(docker('context', 'inspect'))[0]
endpoint = (os.environ.get('DOCKER_HOST') if not os.environ.get('DOCKER_CONTEXT') else '') or context['Endpoints']['docker']['Host']
if not endpoint.startswith('unix://'):
    raise SystemExit('Refusing a non-local Docker endpoint')
name = 'govpn-egress-test-' + uuid.uuid4().hex[:12]
created = False
try:
    docker('run', '-d', '--network', 'none', '--cap-add', 'NET_ADMIN', '--name', name,
           '--entrypoint', 'sleep', 'govpn-warp-test:local', '180')
    created = True
    docker('cp', str(ROOT / 'lib/diagnostics.py'), name + ':/tmp/diagnostics.py')
    # Public resolver addresses are only synthetic interface addresses in an
    # isolated namespace with no external connection. No real packets are sent.
    docker('exec', name, 'sh', '-ec', '''
ip link add net0 type dummy
ip link set net0 up
ip address add 8.8.8.8/32 dev net0
ip address add 9.9.9.9/32 dev net0
ip route add 10.0.0.1/32 dev net0 scope link
ip route add default via 10.0.0.1 dev net0
''')
    probe = '''
import diagnostics as d
import io, os, subprocess
source = os.environ['EXPECTED_SOURCE']
before = [subprocess.check_output(argv) for argv in (
    ['ip', '-j', '-4', 'route', 'show'], ['iptables-save'])]
report = d.Report('bridge', '', output=io.StringIO())
report.host()
assert report.host_route == {'dev': 'net0', 'source': source}, report.host_route
assert report.addresses == ['8.8.8.8', '9.9.9.9'], report.addresses
report.egress({'ip': source})  # synthetic remote observation, no curl request
assert report.rows[-1][0] == 'warn'
mismatch = 'SSH и внешний выход различаются' in report.output.getvalue()
assert mismatch == (source != '9.9.9.9')
after = [subprocess.check_output(argv) for argv in (
    ['ip', '-j', '-4', 'route', 'show'], ['iptables-save'])]
assert before == after, 'report mutated routes/firewall'
'''
    for source in ('8.8.8.8', '9.9.9.9'):
        if source == '9.9.9.9':
            docker('exec', name, 'ip', 'route', 'change', 'default', 'via', '10.0.0.1', 'dev', 'net0', 'src', source)
        docker('exec', '-e', 'SSH_CONNECTION=192.0.2.1 12345 9.9.9.9 22', '-e', 'EXPECTED_SOURCE=' + source,
               '-e', 'PYTHONPATH=/tmp', name, 'python3', '-c', probe)
    print('PASS: actual Linux JSON/source selection before and after preferred source; two public IPv4; SSH mismatch; report leaves routes/NAT unchanged. HTTPS fields synthetic.')
finally:
    if created:
        docker('rm', '-f', name)
