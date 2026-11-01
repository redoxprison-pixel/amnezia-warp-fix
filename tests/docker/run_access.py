"""Opt-in LOCAL test of pinned OpenFlux CLI and systemd unit syntax.

Network is used only to fetch the hash-pinned public release. The node runs
unprivileged in an offline disposable container, never on a production VPS.
No document service, real client, captcha, or whitelist is exercised.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('access', ROOT / 'lib/access_tools.py')
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)


def docker(*args, **kwargs):
    return subprocess.run(['docker', *args], check=True, timeout=120, **kwargs)


context = json.loads(docker('context','inspect',capture_output=True,text=True).stdout)[0]
endpoint = context['Endpoints']['docker']['Host']
if not os.environ.get('DOCKER_CONTEXT'):
    endpoint = os.environ.get('DOCKER_HOST','') or endpoint
if not endpoint.startswith('unix://'):
    raise SystemExit('Refusing non-local Docker endpoint.')
image = 'govpn-access-test:local'
name = 'govpn-access-test-'+uuid.uuid4().hex[:10]
arch = docker('run','--rm','--network','none','--entrypoint','uname',image,'-m',capture_output=True,text=True).stdout.strip()
asset, digest = access.ASSETS[arch]
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    binary = root / 'openflux'
    access.download(f'https://github.com/p1neappleXpress/OpenFlux/releases/download/{access.VERSION}/openflux-linux-{asset}', binary, 100*1024*1024)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != digest:
        raise SystemExit('Pinned release checksum mismatch; binary was not executed.')
    binary.chmod(0o755)
    fixture = root / 'probe.py'
    fixture.write_text('''import json, pathlib, subprocess, time, os
root=pathlib.Path('/tmp/openflux-probe')
root.mkdir(mode=0o700)
url='https://docs.yandex.ru/docs/view?url=fixture-only-not-real'
secret='a'*64
share={'name':'fixture','negotiate':True,'codec':'batched','secret':secret,'context':url,'transports':[{'type':'yandex','url':url}]}
binary='/opt/govpn-openflux/v0.17.1/openflux'
result=subprocess.run([binary,'--make-link','-'],input=json.dumps(share).encode(),capture_output=True,timeout=5,check=True)
link=json.loads(result.stdout)['link']
result=subprocess.run([binary,'--parse-link','-'],input=link.encode(),capture_output=True,timeout=5,check=True)
decoded=json.loads(result.stdout)
assert decoded['config']['secret']==secret
assert decoded['config']['negotiate'] is True
assert decoded['config']['transports'][0]['url']==url
print('pinned CLI make-link/parse-link with private stdin: PASS')
config=root/'exit.conf'; key=root/'secret.key'
config.write_text(pathlib.Path('/tmp/node.conf').read_text())
key.write_text(secret+'\\n')
# A synthetic config points its cookie store into this unprivileged fixture.
config.write_text(config.read_text().replace('/var/lib/govpn-openflux/cookies.json',str(root/'cookies.json')))
process=subprocess.Popen([binary,'--config='+str(config),'--encryption-key-file='+str(key)],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
try:
    time.sleep(2)
    assert process.poll() is None, 'L4 exit failed before transport retries'
    print('pinned L4 exit starts unprivileged without raw sockets (network disabled): PASS')
finally:
    process.terminate()
    try: process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill();process.communicate()
''')
    config = root / 'node.conf'
    config.write_text(access.node_config('https://docs.yandex.ru/docs/view?url=fixture-only-not-real'))
    unit = root / 'govpn-openflux.service'
    unit.write_text(access.service_unit())
    docker('create','--name',name,'--network','none','--entrypoint','sleep',image,'120',capture_output=True)
    try:
        docker('start',name,capture_output=True)
        docker('exec',name,'mkdir','-p','/opt/govpn-openflux/v0.17.1')
        for path, target in ((binary,str(access.BINARY)),(fixture,'/tmp/probe.py'),(config,'/tmp/node.conf'),(unit,'/tmp/govpn-openflux.service')):
            docker('cp',str(path),name+':'+target,capture_output=True)
        docker('exec',name,'chmod','755',str(access.BINARY))
        docker('exec',name,'chmod','644','/tmp/probe.py','/tmp/node.conf','/tmp/govpn-openflux.service')
        docker('exec',name,'systemd-analyze','verify','/tmp/govpn-openflux.service',capture_output=True)
        print('systemd-analyze verifies DynamicUser/LoadCredential sandbox unit: PASS')
        result=docker('exec','--user','65534:65534',name,'python3','/tmp/probe.py',capture_output=True,text=True)
        print(result.stdout)
    finally:
        docker('rm','-f',name,capture_output=True)
