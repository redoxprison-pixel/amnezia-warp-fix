"""Opt-in RIPE schema/export check. Public read-only HTTP; no VPS or VPN changes."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('access', ROOT / 'lib/access_tools.py')
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp).resolve()
    if '--inspect' in sys.argv:
        source=root/'source.json'
        access.download('https://stat.ripe.net/data/country-resource-list/data.json?resource=RU&v4_format=prefix',source,8*1024*1024)
        data=json.loads(source.read_text())
        print({'top_keys':list(data),'data_keys':list(data.get('data',{})),'parameters':data.get('parameters'),'resource':data.get('resource'),'messages':data.get('messages')})
        raise SystemExit(0)
    with contextlib.redirect_stdout(io.StringIO()):
        path = access.country_export('RU','192.0.2.1',root)
    rows = json.loads(path.read_text())
    assert len(rows)>100
    assert all(set(row)=={'hostname','ips','ip'} and row['ips']==[row['hostname']] and row['ip']==row['hostname'] for row in rows)
    assert all(access.ipaddress.ip_network(row['ip']).version==4 for row in rows)
    print('RIPE live RU response and Amnezia JSON export: PASS; prefixes='+str(len(rows)))
