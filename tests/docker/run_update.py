"""Run unit tests with real Linux Bash/flock in a disposable container."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def docker(*args, **kwargs):
    return subprocess.run(['docker', *args], check=True, timeout=90, **kwargs)


context = json.loads(docker('context', 'inspect', capture_output=True, text=True).stdout)[0]
endpoint = context['Endpoints']['docker']['Host']
if not os.environ.get('DOCKER_CONTEXT'):
    endpoint = os.environ.get('DOCKER_HOST', '') or endpoint
if not endpoint.startswith('unix://'):
    raise SystemExit('Refusing a non-local Docker endpoint.')
name = 'govpn-update-test-' + uuid.uuid4().hex[:12]
with tempfile.TemporaryDirectory() as temp:
    files = Path(temp)
    for relative in ('govpn.sh', 'lib/awg_warp.py', 'lib/awg_clients.py', 'tools/bundle.py',
                     'tests/test_awg_warp.py', 'tests/test_update.py', 'tests/test_lifecycle.py',
                     'tests/test_clients.py', 'tests/test_bootstrap.py'):
        target = files / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)
    docker('create', '--name', name, '--network', 'none', '--workdir', '/workspace',
           '--entrypoint', 'python3', 'govpn-warp-test:local',
           '-m', 'unittest', 'discover', '-s', 'tests', '-v', capture_output=True)
    try:
        docker('cp', str(files) + '/.', name + ':/workspace')
        docker('start', '--attach', name)
        status = docker('wait', name, capture_output=True, text=True).stdout.strip()
        if status != '0':
            raise SystemExit('Linux updater tests failed: ' + status)
    finally:
        docker('rm', '-f', name, capture_output=True)
