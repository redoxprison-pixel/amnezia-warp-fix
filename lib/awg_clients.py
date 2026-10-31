"""Read AWG identities without exposing keys or changing Amnezia metadata.

clientsTable may contain a name and clientId without allowedIps. Public keys
join that metadata to the server's peers. GoVPN-only labels are keyed by the
public key, so reusing an IP does not give a new peer the previous peer's name.
"""
import contextlib
import base64
import hashlib
import hmac
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


READ_TIMEOUT = 6


def container_names():
    try:
        result = subprocess.run(['docker', 'ps', '--format', '{{.Names}}'], capture_output=True,
                                text=True, timeout=READ_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise ClientError('Docker не ответил за 6 секунд. Проверьте daemon; список клиентов не изменен.') from None
    if result.returncode:
        raise ClientError('Не удалось получить список контейнеров Docker.')
    return sorted(n for n in result.stdout.splitlines() if re.fullmatch(r'amnezia-awg[A-Za-z0-9_.-]*', n))


def fast_snapshot(container):
    # One bounded exec for a screen. Secret key fields are excluded at source.
    script = r'''set -eu
conf=
for f in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf /etc/wireguard/wg0.conf; do
    if [ -r "$f" ]; then conf=$f; break; fi
done
[ -n "$conf" ] || exit 1
iface=${conf##*/}; iface=${iface%.conf}
printf '%s\n' GOVPN_CONFIG
awk -F= 'tolower($1) !~ /^[[:space:]]*(privatekey|presharedkey)[[:space:]]*$/' "$conf"
printf '\n%s\n' GOVPN_TABLE
cat /opt/amnezia/awg/clientsTable 2>/dev/null || printf '[]'
tool=awg
command -v awg >/dev/null 2>&1 || tool=wg
run() {
    if command -v timeout >/dev/null 2>&1; then timeout 2 "$@"; else "$@"; fi
}
printf '\n%s\n' GOVPN_ALLOWED
run "$tool" show "$iface" allowed-ips 2>/dev/null || true
printf '\n%s\n' GOVPN_HANDSHAKES
if run "$tool" show "$iface" latest-handshakes 2>/dev/null; then
    printf '\nGOVPN_HANDSHAKE_OK\n'
else
    printf '\nGOVPN_HANDSHAKE_UNKNOWN\n'
fi
printf '\n%s\n' GOVPN_DONE
'''
    try:
        result = subprocess.run(['docker', 'exec', container, 'sh', '-c', script], capture_output=True,
                                text=True, timeout=READ_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise ClientError('Docker не ответил за 6 секунд. Операция прервана; данные и сеть не изменены.') from None
    if result.returncode:
        raise ClientError('Не удалось прочитать клиентов: проверьте контейнер и AWG config.')
    try:
        config, rest = result.stdout.split('GOVPN_CONFIG\n', 1)[1].split('\nGOVPN_TABLE\n', 1)
        table, rest = rest.split('\nGOVPN_ALLOWED\n', 1)
        allowed, rest = rest.split('\nGOVPN_HANDSHAKES\n', 1)
        handshakes, _ = rest.split('\nGOVPN_DONE', 1)
    except (ValueError, IndexError):
        raise ClientError('Ответ Docker неполный; список не изменен.') from None
    rows = records(table, config_peers(config) + live_peers(allowed), handshakes)
    for row in rows:
        row['handshake_known'] = 'GOVPN_HANDSHAKE_OK' in handshakes
    return rows


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
                                text=True, timeout=READ_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise ClientError('Не удалось прочитать клиентов через Docker.') from None
    if result.returncode and not optional:
        raise ClientError('Не удалось прочитать peers AWG. Проверьте контейнер и интерфейс.')
    return result.stdout if result.returncode == 0 else ''


def read_config(container):
    config = ''
    for path in ('/opt/amnezia/awg/awg0.conf', '/opt/amnezia/awg/wg0.conf', '/etc/wireguard/wg0.conf'):
        config = docker(container, 'cat', path, optional=True)
        if config:
            iface = Path(path).stem
            break
    if not config:
        raise ClientError('Серверный конфиг AWG не найден. Список клиентов не изменен.')
    return config, iface


def snapshot(container):
    config, iface = read_config(container)
    # Query only non-secret wg fields. Never use `wg show dump`.
    # Modern AWG exposes `awg`; older installations use a fork named `wg`.
    allowed = docker(container, 'awg', 'show', iface, 'allowed-ips', optional=True)
    tool = 'awg'
    if not allowed:
        tool = 'wg'
        allowed = docker(container, tool, 'show', iface, 'allowed-ips', optional=True)
    handshakes = docker(container, tool, 'show', iface, 'latest-handshakes', optional=True)
    table = docker(container, 'cat', '/opt/amnezia/awg/clientsTable', optional=True)
    # Config remains authoritative when there are no live peers or wg tools.
    peers = live_peers(allowed) + config_peers(config)
    return records(table, peers, handshakes)


def sections(text):
    result, current = [], None
    for line in text.splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        if line.startswith('['):
            current = {}
            result.append((line.lower(), current))
        elif current is not None and '=' in line:
            k, v = (s.strip() for s in line.split('=', 1))
            if k.lower() in current:
                raise ClientError('Повторный параметр в профиле.')
            current[k.lower()] = v
        else:
            raise ClientError('Неподдерживаемый формат профиля.')
    return result


def public_key(container, private):
    try:
        if len(base64.b64decode(private, validate=True)) != 32:
            raise ValueError()
        for tool in ('awg', 'wg'):
            result = subprocess.run(['docker', 'exec', '-i', container, tool, 'pubkey'],
                                    input=private + '\n', text=True, capture_output=True, timeout=15)
            value = result.stdout.strip()
            if result.returncode == 0 and len(base64.b64decode(value, validate=True)) == 32:
                return value
    except (ValueError, OSError, subprocess.SubprocessError):
        pass
    raise ClientError('Не удалось проверить ключ профиля; он не сохранен и не выдан.')


def validate_client_profile(text, row, container):
    if len(text) > 65536 or any(unicodedata.category(c).startswith('C') and c not in '\n\r\t' for c in text):
        raise ClientError('Некорректный размер или управляющие символы в профиле.')
    data = sections(text)
    if [name for name, _ in data] != ['[interface]', '[peer]']:
        raise ClientError('Нужен обычный .conf с одним Interface и одним Peer, не ссылка Amnezia.')
    own, peer = data[0][1], data[1][1]
    allowed = {'privatekey', 'address', 'dns', 'mtu', 'listenport'} | {
        'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5'}
    if set(own) - allowed or set(peer) - {'publickey', 'presharedkey', 'allowedips', 'endpoint', 'persistentkeepalive'}:
        raise ClientError('Исполняемые hooks и неизвестные параметры профиля запрещены.')
    try:
        own_ips = [ipaddress.ip_interface(s.strip()).ip for s in own['address'].split(',')]
        routes = [ipaddress.ip_network(s.strip()) for s in peer['allowedips'].split(',')]
        if ipaddress.ip_interface(row['ip']).ip not in own_ips or not routes:
            raise ValueError()
        if not hmac.compare_digest(public_key(container, own['privatekey']), row['key']):
            raise ValueError()
        server, _ = read_config(container)
        blocks = sections(server)
        interfaces = [v for k, v in blocks if k == '[interface]']
        matches = [v for k, v in blocks if k == '[peer]' and v.get('publickey') == row['key']
                   and row['ip'] in addresses(v.get('allowedips'))]
        if len(matches) != 1 or len(interfaces) != 1:
            raise ValueError()
        if not hmac.compare_digest(public_key(container, interfaces[0]['privatekey']), peer['publickey']):
            raise ValueError()
        if not hmac.compare_digest(matches[0].get('presharedkey', ''), peer.get('presharedkey', '')):
            raise ValueError()
    except (ValueError, KeyError):
        raise ClientError('Профиль не соответствует текущему ключу, IP или серверу этого клиента.') from None
    return text


def profile_path(root, container, row):
    return root / 'client-profiles' / container / (hashlib.sha256(row['key'].encode()).hexdigest() + '.conf')


def saved_profile(root, container, row):
    path = profile_path(root, container, row)
    if not path.exists():
        path = root / 'awg_clients' / (str(ipaddress.ip_interface(row['ip']).ip) + '.conf')
    if path.is_symlink() or not path.is_file():
        raise ClientError('Сохраненного профиля нет. Экспортируйте его с устройства или из доверенной копии.')
    return validate_client_profile(path.read_text(), row, container)


def import_profile(root, container, row, source):
    source = Path(source)
    if source.is_symlink() or not source.is_file():
        raise ClientError('Нужен обычный файл профиля.')
    text = validate_client_profile(source.read_text(), row, container)
    path = profile_path(root, container, row)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.parent.parent.is_symlink():
        raise ClientError('Каталог профилей не должен быть символической ссылкой.')
    os.chmod(path.parent.parent, 0o700)
    os.chmod(path.parent, 0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp)


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
    if action == 'containers' and not args:
        print('\n'.join(container_names()))
        return
    rows = fast_snapshot(container) if action in ('list', 'profile-hint') else snapshot(container)
    if action in ('profile-status', 'profile-hint', 'profile-export', 'profile-import'):
        if len(args) != (2 if action == 'profile-import' else 1):
            raise ClientError('Укажите IP клиента и, для импорта, файл .conf.')
        matches = [r for r in rows if r['ip'] in addresses(args[0])]
        if len(matches) != 1:
            raise ClientError('Клиент не найден однозначно.')
        row = matches[0]
        root = Path('/etc/govpn')
        if action == 'profile-hint':
            path = profile_path(root, container, row)
            legacy = root / 'awg_clients' / (str(ipaddress.ip_interface(row['ip']).ip) + '.conf')
            print('available' if any(p.is_file() and not p.is_symlink() for p in (path, legacy)) else 'unavailable')
            return
        if action == 'profile-import':
            import_profile(root, container, row, args[1])
            print('Профиль сохранен с правами 600. Ключ и конфигурация сервера не изменялись.')
        elif action == 'profile-export':
            print(saved_profile(root, container, row), end='')
        else:
            try:
                saved_profile(root, container, row)
                print('available')
            except ClientError:
                print('unavailable')
        return
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
            if not row.get('handshake_known', True):
                status = 'данные handshake недоступны'
            print(f"{row['ip']}|{name}|{stamp}|{status}")
    else:
        raise ClientError('Неизвестная команда имен клиентов.')


if __name__ == '__main__':
    try:
        main()
    except (ClientError, OSError, ValueError) as exc:
        print(str(exc) if isinstance(exc, ClientError) else 'Ошибка чтения имен клиентов.', file=sys.stderr)
        sys.exit(1)
