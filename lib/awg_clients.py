"""Read AWG identities without exposing keys or changing Amnezia metadata.

clientsTable may contain a name and clientId without allowedIps. Public keys
join that metadata to the server's peers. GoVPN-only labels are keyed by the
public key, so reusing an IP does not give a new peer the previous peer's name.
"""
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unicodedata


class ClientError(Exception):
    pass


def label(value):
    if not isinstance(value, str):
        return ''
    value = ''.join(c for c in value if not unicodedata.category(c).startswith('C'))
    return ' '.join(value.replace('|', '/').replace('\\', '/').split())[:80]


def addresses(value):
    if isinstance(value, list):
        value = ','.join(v for v in value if isinstance(v, str))
    if not isinstance(value, str):
        return []
    result = []
    for part in re.split(r'[,\s]+', value):
        try:
            net = ipaddress.ip_network(part if '/' in part else part + '/32', strict=True)
            if net.version == 4 and net.prefixlen == 32:
                result.append(str(net))
        except ValueError:
            continue
    return result


def metadata(raw):
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return []
    if isinstance(data, dict):
        # Amnezia's legacy map: public key -> {clientName: ...}.
        data = [{'clientId': k, 'userData': v} for k, v in data.items()]
    if not isinstance(data, list):
        return []
    return [c for c in data if isinstance(c, dict) and isinstance(c.get('userData'), dict)]


def config_peers(raw):
    peers, current = [], None
    for line in raw.splitlines():
        line = line.split('#', 1)[0].strip()
        if line.startswith('['):
            current = {} if line.lower() == '[peer]' else None
            if current is not None:
                peers.append(current)
        elif current is not None and '=' in line:
            key, value = (s.strip() for s in line.split('=', 1))
            current[key.lower()] = value
    return [(c.get('publickey', ''), ip) for c in peers for ip in addresses(c.get('allowedips', ''))]


def live_peers(raw):
    return [(parts[0], ip) for line in raw.splitlines()
            if len(parts := line.split(None, 1)) == 2 for ip in addresses(parts[1])]


def records(table, peers, handshakes='', aliases=None):
    by_key, by_ip = {}, {}
    for entry in metadata(table):
        data = entry['userData']
        name, key = label(data.get('clientName')), entry.get('clientId')
        if isinstance(key, str) and key:
            by_key.setdefault(key, set()).add(name)
        else:
            for ip in addresses(data.get('allowedIps')):
                by_ip.setdefault(ip, set()).add(name)
    stamps = {}
    for line in handshakes.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            stamps[parts[0]] = int(parts[1])
    identities = {}
    for key, ip in peers:
        if key:
            identities.setdefault(ip, set()).add(key)
    result = []
    for ip, keys in identities.items():
        if len(keys) != 1:
            raise ClientError('Один IP назначен нескольким ключам. Исправьте peers в Amnezia.')
        key = next(iter(keys))
        names = by_key.get(key, by_ip.get(ip, set())) - {''}
        name = next(iter(names)) if len(names) == 1 else ''
        name = label((aliases or {}).get(key)) or name
        result.append({'ip': ip, 'key': key, 'name': name, 'handshake': stamps.get(key, 0)})
    return sorted(result, key=lambda r: int(ipaddress.ip_interface(r['ip']).ip))


def docker(container, *args, optional=False):
    try:
        result = subprocess.run(['docker', 'exec', container, *args], capture_output=True,
                                text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        raise ClientError('Не удалось прочитать клиентов через Docker.') from None
    if result.returncode and not optional:
        raise ClientError('Не удалось прочитать peers AWG. Проверьте контейнер и интерфейс.')
    return result.stdout if result.returncode == 0 else ''


def snapshot(container):
    config = ''
    for path in ('/opt/amnezia/awg/awg0.conf', '/opt/amnezia/awg/wg0.conf', '/etc/wireguard/wg0.conf'):
        config = docker(container, 'cat', path, optional=True)
        if config:
            iface = Path(path).stem
            break
    if not config:
        raise ClientError('Серверный конфиг AWG не найден. Список клиентов не изменен.')
    # Query only non-secret wg fields. Never use `wg show dump`.
    allowed = docker(container, 'wg', 'show', iface, 'allowed-ips')
    handshakes = docker(container, 'wg', 'show', iface, 'latest-handshakes', optional=True)
    table = docker(container, 'cat', '/opt/amnezia/awg/clientsTable', optional=True)
    # Include configured peers while the interface is temporarily empty.
    peers = live_peers(allowed) + config_peers(config)
    return records(table, peers, handshakes)


def load_aliases(path):
    if not path.exists():
        return {}
    if path.is_symlink():
        raise ClientError('Файл имен не должен быть символической ссылкой.')
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.items()):
            raise ValueError()
        return data
    except (OSError, ValueError):
        raise ClientError('Не удалось прочитать локальные имена GoVPN.') from None


def rename(path, key, name):
    import fcntl
    if not label(name) or len(name) > 80 or label(name) != name:
        raise ClientError('Имя: 1-80 символов, без управляющих символов, | и обратного слеша.')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink():
        raise ClientError('Каталог имен не должен быть символической ссылкой.')
    os.chmod(path.parent, 0o700)
    lock = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, 'w') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        data = load_aliases(path)
        data[key] = name
        fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.names-')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, path)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temp)


def main():
    container, action, *args = sys.argv[1:]
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}', container):
        raise ClientError('Неверное имя контейнера.')
    alias_path = Path('/etc/govpn/client-names') / (container + '.json')
    rows = snapshot(container)
    aliases = load_aliases(alias_path)
    if action == 'rename' and len(args) == 2:
        matches = [r for r in rows if r['ip'] in addresses(args[0])]
        if len(matches) != 1:
            raise ClientError('Клиент не найден однозначно. Обновите список.')
        rename(alias_path, matches[0]['key'], args[1])
    elif action == 'list' and not args:
        for row in rows:
            name = label(aliases.get(row['key'])) or row['name'] or '(имя не сохранено)'
            stamp = row['handshake']
            age = int(time.time()) - stamp if stamp else None
            status = 'нет handshake' if age is None else (
                f'handshake {max(0, age)} сек. назад' if age >= 0 else 'время handshake в будущем')
            print(f"{row['ip']}|{name}|{stamp}|{status}")
    else:
        raise ClientError('Неизвестная команда имен клиентов.')


if __name__ == '__main__':
    try:
        main()
    except (ClientError, OSError, ValueError) as exc:
        print(str(exc) if isinstance(exc, ClientError) else 'Ошибка чтения имен клиентов.', file=sys.stderr)
        sys.exit(1)
