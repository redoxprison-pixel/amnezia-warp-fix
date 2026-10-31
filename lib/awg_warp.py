"""Safe, single-container WARP controller. Embedded in govpn.sh by tools/bundle.py.

No Docker socket is touched at import time. Errors never include command output,
which may contain private WireGuard keys.
"""
import argparse
import base64
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path('/etc/amnezia-warp')
REMOTE = '/opt/govpn-warp'
START = '/opt/amnezia/start.sh'
BEGIN = '# --- GOVPN SAFE WARP BEGIN ---'
END = '# --- GOVPN SAFE WARP END ---'

# POSIX sh: the container need not have Python or Bash for this helper.
RUNTIME = r'''#!/bin/sh
set -eu
action=$1
iface=$2
case "$iface" in awg0|wg0) ;; *) exit 1 ;; esac
base=${0%/*}
table=51888
mark=0x40000000/0x40000000
ensure() {
    tool=$1; shift
    "$tool" -w 10 "$@" 2>/dev/null
}
add() {
    tool=$1; shift
    # Arguments before -- are the table and chain, after -- the rule.
    tbl=$1; chain=$2; shift 2
    while ensure "$tool" -t "$tbl" -C "$chain" "$@"; do
        ensure "$tool" -t "$tbl" -D "$chain" "$@"
    done
    ensure "$tool" -t "$tbl" -I "$chain" 1 "$@"
}
guard() {
    for tool in iptables ip6tables; do
        add "$tool" filter FORWARD -i "$iface" -m comment --comment govpn-warp-boot -j DROP
        add "$tool" filter INPUT -i "$iface" -m comment --comment govpn-warp-boot -j DROP
    done
}
guard
[ "$action" = guard ] && exit 0
[ "$action" = apply ] || exit 1
command -v wg-quick >/dev/null
command -v ip >/dev/null

# Reserve our own table/priority. Never flush other users' routing tables.
rules=$(ip -4 rule show)
if printf '%s\n' "$rules" | grep '^10900:' | grep -v 'fwmark 0x40000000/0x40000000 lookup 51888' >/dev/null; then
    exit 1
fi
routes=$(ip -4 route show table "$table" 2>/dev/null || true)
if printf '%s\n' "$routes" | grep -v '^$' | grep -v '^unreachable default.*metric 32767' |
    grep -v '^default dev warp.*metric 10' >/dev/null; then
    exit 1
fi
ip -4 route replace unreachable default metric 32767 table "$table"
if ! printf '%s\n' "$rules" | grep -q '^10900:.*fwmark 0x40000000/0x40000000 lookup 51888'; then
    ip -4 rule add priority 10900 fwmark "$mark" lookup "$table"
fi

# Chains are rebuilt only while the ingress blanket guard is installed.
for spec in 'mangle GVPN_WARP_MARK' 'filter GVPN_WARP_FWD' 'filter GVPN_WARP_IN' 'nat GVPN_WARP_NAT'; do
    set -- $spec
    ensure iptables -t "$1" -S "$2" >/dev/null || ensure iptables -t "$1" -N "$2"
    ensure iptables -t "$1" -F "$2"
done
while IFS= read -r client; do
    [ -n "$client" ] || continue
    # Controller validated /32 addresses; no eval or shell interpolation.
    ensure iptables -t filter -A GVPN_WARP_FWD -s "$client" ! -o warp -j DROP
    ensure iptables -t filter -A GVPN_WARP_IN -s "$client" -j DROP
    ensure iptables -t nat -A GVPN_WARP_NAT -s "$client" -o warp -j MASQUERADE
done < "$base/clients.list"
# Explicit MARK + RETURN pairs; no catch-all selection of unknown peers.
while IFS= read -r client; do
    [ -n "$client" ] || continue
    ensure iptables -t mangle -A GVPN_WARP_MARK -s "$client" -j MARK --set-xmark "$mark"
    ensure iptables -t mangle -A GVPN_WARP_MARK -s "$client" -j RETURN
done < "$base/clients.list"
ensure iptables -t mangle -A GVPN_WARP_MARK -j MARK --set-xmark 0x0/0x40000000
add iptables mangle PREROUTING -i "$iface" -j GVPN_WARP_MARK
add iptables filter FORWARD -i "$iface" -j GVPN_WARP_FWD
add iptables filter INPUT -i "$iface" -j GVPN_WARP_IN
add iptables nat POSTROUTING -j GVPN_WARP_NAT

# Deliberate IPv4-only policy: IPv6 cannot be mapped to IPv4 peers reliably.
# Block ALL AWG IPv6, including DNS to the container, before ACCEPT/ESTABLISHED.
add ip6tables filter FORWARD -i "$iface" -m comment --comment govpn-warp-ipv6 -j DROP
add ip6tables filter INPUT -i "$iface" -m comment --comment govpn-warp-ipv6 -j DROP

# Only exact legacy rules created by old GoVPN are removed, under the guard.
while ensure iptables -t mangle -C PREROUTING -i "$iface" -j AWG_WARP; do
    ensure iptables -t mangle -D PREROUTING -i "$iface" -j AWG_WARP
done
while ensure iptables -t mangle -C PREROUTING -i "$iface" -j MARK --set-mark 100; do
    ensure iptables -t mangle -D PREROUTING -i "$iface" -j MARK --set-mark 100
done
while ip -4 rule del priority 100 fwmark 100 lookup 100 2>/dev/null; do :; done
# Remaining unrelated table 100 rules/routes are intentionally preserved.

if ip link show warp >/dev/null 2>&1; then
    wg-quick down "$base/warp.conf" >/dev/null 2>&1
fi
wg-quick up "$base/warp.conf" >/dev/null 2>&1
ip -4 route replace default dev warp metric 10 table "$table"

# Verify the lookup and filter before releasing the ingress guard.
while IFS= read -r client; do
    [ -n "$client" ] || continue
    route=$(ip -4 route get 1.1.1.1 from "${client%/32}" iif "$iface" mark 0x40000000)
    printf '%s\n' "$route" | grep -q 'dev warp'
    ensure iptables -t filter -C GVPN_WARP_FWD -s "$client" ! -o warp -j DROP
done < "$base/clients.list"
for tool in iptables ip6tables; do
    for chain in FORWARD INPUT; do
        while ensure "$tool" -t filter -C "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP; do
            ensure "$tool" -t filter -D "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP
        done
    done
done
'''


class SafeError(Exception):
    pass


def clients(values):
    result = set()
    for value in values:
        try:
            net = ipaddress.ip_network(value.strip(), strict=True)
        except ValueError:
            raise SafeError('Клиенты должны быть корректными IPv4 /32.') from None
        if net.version != 4 or net.prefixlen != 32 or net.network_address.is_unspecified or net.network_address.is_multicast:
            raise SafeError('Разрешены только unicast IPv4 /32.')
        result.add(str(net))
    return sorted(result, key=lambda s: int(ipaddress.ip_network(s).network_address))


def endpoint(value):
    match = re.fullmatch(r'(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})', value)
    if not match or not 1 <= int(match[2]) <= 65535:
        raise SafeError('Некорректный Endpoint.')
    host = match[1]
    if host.startswith('['):
        try:
            ipaddress.IPv6Address(host[1:-1])
        except ValueError:
            raise SafeError('Некорректный IPv6 Endpoint.') from None
    elif not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', host):
        raise SafeError('Некорректное имя Endpoint.')
    return value


def profile(text):
    """Validate data only; wg-quick hooks and SaveConfig can execute/overwrite data."""
    sections = {'Interface': {}, 'Peer': {}}
    section = None
    seen = set()
    allowed = {'Interface': {'PrivateKey', 'Address', 'MTU', 'Table', 'DNS'},
               'Peer': {'PublicKey', 'PresharedKey', 'AllowedIPs', 'Endpoint', 'PersistentKeepalive'}}
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        if line in ('[Interface]', '[Peer]'):
            section = line[1:-1]
            if section in seen:
                raise SafeError('Ожидается один Interface и один Peer.')
            seen.add(section)
            continue
        if section is None or '=' not in line:
            raise SafeError('Неподдерживаемый формат WARP.')
        key, value = (v.strip() for v in line.split('=', 1))
        if key not in allowed[section] or key in sections[section]:
            raise SafeError('Запрещенный или повторный параметр WARP; hooks не допускаются.')
        sections[section][key] = value
    a, p = sections['Interface'], sections['Peer']
    for data, key in ((a, 'PrivateKey'), (p, 'PublicKey')):
        if key not in data:
            raise SafeError('Нет обязательного ключа WARP.')
    for data in (a, p):
        for key in ('PrivateKey', 'PublicKey', 'PresharedKey'):
            if key in data:
                try:
                    if len(base64.b64decode(data[key], validate=True)) != 32:
                        raise ValueError()
                except (ValueError, TypeError):
                    raise SafeError('Некорректный ключ WARP.') from None
    try:
        addresses = [ipaddress.ip_interface(s.strip()) for s in a['Address'].split(',')]
        routes = [ipaddress.ip_network(s.strip()) for s in p['AllowedIPs'].split(',')]
    except (KeyError, ValueError):
        raise SafeError('Некорректные Address/AllowedIPs.') from None
    v4 = [str(s) for s in addresses if s.version == 4]
    if len(v4) != 1 or ipaddress.ip_network('0.0.0.0/0') not in routes:
        raise SafeError('Требуется IPv4 Address и AllowedIPs 0.0.0.0/0.')
    a['Address'] = v4[0]
    a['Table'] = 'off'
    a.pop('DNS', None)
    p['AllowedIPs'] = '0.0.0.0/0'
    p['Endpoint'] = endpoint(p.get('Endpoint', ''))
    for data, key, low, high in ((a, 'MTU', 576, 9000), (p, 'PersistentKeepalive', 0, 65535)):
        if key in data and (not data[key].isdigit() or not low <= int(data[key]) <= high):
            raise SafeError('Некорректный числовой параметр WARP.')
    return ''.join('[' + name + ']\n' + ''.join(k + ' = ' + v + '\n' for k, v in data.items()) + '\n'
                   for name, data in (('Interface', a), ('Peer', p)))


def patch_start(text, iface):
    if iface not in ('awg0', 'wg0'):
        raise SafeError('Неизвестный интерфейс AWG.')
    lines = text.splitlines()
    if not lines or lines[0] not in ('#!/bin/bash', '#!/bin/sh', '#!/usr/bin/env bash'):
        raise SafeError('Неизвестный start.sh; автоматическая подмена шаблоном запрещена.')
    clean = []
    active = None
    markers = {BEGIN: END, '# --- GOVPN WARP BEGIN ---': '# --- GOVPN WARP END ---',
               '# --- WARP-MANAGER BEGIN ---': '# --- WARP-MANAGER END ---',
               '# --- WARP BEGIN ---': '# --- WARP END ---'}
    for line in lines:
        if line in markers:
            if active:
                raise SafeError('Вложенные WARP markers в start.sh.')
            active = markers[line]
        elif line in markers.values():
            if line != active:
                raise SafeError('Несогласованные WARP markers в start.sh.')
            active = None
        elif active is None:
            clean.append(line)
    if active:
        raise SafeError('Незакрытый WARP marker в start.sh.')
    while clean and not clean[-1].strip():
        clean.pop()
    if len(clean) < 3 or clean[-1].strip() not in ('tail -f /dev/null', 'exec tail -f /dev/null'):
        raise SafeError('Поддерживается только start.sh с завершающим tail -f /dev/null.')
    # Refuse unknown background daemons/early exits: boot must reach apply.
    for line in clean[1:-1]:
        if re.search(r'warp|lookup\s+100|fwmark|\bexec\b|\bexit\b|\btail\b|&\s*$', line.split('#', 1)[0], re.I):
            raise SafeError('В start.sh остались неподдерживаемые команды; требуется ручной аудит.')
    boot = [BEGIN, f'sh {REMOTE}/runtime.sh guard {iface} || exit 1', END]
    apply = [BEGIN, f'sh {REMOTE}/runtime.sh apply {iface} || exit 1', END]
    return '\n'.join(clean[:1] + boot + clean[1:-1] + apply + clean[-1:]) + '\n'


def private_dir(path):
    if path.is_symlink():
        raise SafeError('Каталог состояния не должен быть symlink.')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.geteuid():
        raise SafeError('Неверный владелец каталога состояния.')
    path.chmod(0o700)


def write_private(path, data):
    fd, name = tempfile.mkstemp(prefix='.new-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Controller:
    def __init__(self, name, root=ROOT):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name):
            raise SafeError('Некорректное имя контейнера.')
        self.name = name
        self.root = root
        self.directory = root / name
        self.target = name

    def docker(self, *args, check=True):
        result = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=90)
        if check and result.returncode:
            raise SafeError('Операция Docker завершилась ошибкой (вывод скрыт для защиты ключей).')
        return result

    def inspect(self):
        data = json.loads(self.docker('inspect', self.name).stdout)[0]
        if data.get('Name', '/' + self.name).lstrip('/') != self.name:
            raise SafeError('Укажите каноническое имя контейнера, а не ID/alias.')
        if data['HostConfig']['NetworkMode'] == 'host' or data['HostConfig']['NetworkMode'].startswith('container:'):
            raise SafeError('Требуется отдельный сетевой namespace контейнера.')
        self.target = data['Id']  # Pin identity: never mutate a replacement with the same name.
        for mount in data.get('Mounts', []):
            dest = mount['Destination'].rstrip('/')
            if any(p == dest or p.startswith(dest + '/') for p in (REMOTE, START)):
                raise SafeError('Управляемые пути перекрыты mount; требуется отдельный план миграции.')
        return bool(data['State']['Running'])

    def read_container(self, path, optional=False):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / 'data'
            result = self.docker('cp', self.target + ':' + path, str(dest), check=not optional)
            if result.returncode and optional:
                return None
            if dest.is_symlink() or not dest.is_file():
                raise SafeError('Ожидался обычный файл контейнера.')
            return dest.read_text()

    def state(self):
        path = self.directory / 'state.json'
        if path.is_symlink() or not path.is_file():
            raise SafeError('Нет сохраненного состояния. Сначала выполните import.')
        if path.stat().st_mode & 0o077:
            raise SafeError('state.json должен иметь права 600.')
        state = json.loads(path.read_text())
        state['profile'] = profile(state['profile'])
        state['clients'] = clients(state['clients'])
        if state['iface'] not in ('awg0', 'wg0'):
            raise SafeError('Некорректный интерфейс в состоянии.')
        return state

    def import_state(self, source, client_file, iface):
        if (self.directory / 'state.json').exists():
            raise SafeError('Состояние уже существует; используйте apply/restore.')
        # Explicit files only. Never replace the user's saved flat configuration.
        data = profile(Path(source).read_text())
        selected = clients(Path(client_file).read_text().splitlines())
        self.inspect()
        original = self.read_container(START)
        patch_start(original, iface)
        for candidate in ('/opt/amnezia/awg/' + iface + '.conf', '/etc/wireguard/' + iface + '.conf'):
            if self.read_container(candidate, optional=True) is not None:
                break
        else:
            raise SafeError('Конфигурация выбранного AWG интерфейса не найдена.')
        state = {'version': 1, 'profile': data, 'clients': selected, 'iface': iface}
        self.backup(original, None)
        write_private(self.directory / 'state.json', json.dumps(state, indent=2) + '\n')

    def backup(self, start, state):
        directory = self.directory / 'backups'
        private_dir(directory)
        # Back up the actual original BEFORE replacing anything. Never a deleted temp file.
        path = directory / (uuid.uuid4().hex + '.json')
        write_private(path, json.dumps({'start.sh': start, 'state': state}, indent=2) + '\n')

    def deploy(self, state):
        running = self.inspect()
        original = self.read_container(START)
        patched = patch_start(original, state['iface'])
        self.backup(original, self.state())
        if not running:
            raise SafeError('Контейнер остановлен. Для установки hook используйте prepare-stopped.')
        self.install(state, patched, running=True)

    def install(self, state, patched, running):
        mutated = False
        try:
            with tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                remote = REMOTE + '/' + uuid.uuid4().hex
                patched = patched.replace(REMOTE + '/runtime.sh', remote + '/runtime.sh')
                files = {'runtime.sh': RUNTIME, 'warp.conf': state['profile'],
                         'clients.list': '\n'.join(state['clients']) + ('\n' if state['clients'] else ''),
                         'start.sh': patched}
                for name, content in files.items():
                    write_private(directory / name, content)
                start_file = directory / 'start.sh'
                start_file.chmod(0o700)
                # Immutable release directories preserve the previous boot hook
                # during copies, crashes, or a concurrent external restart.
                mutated = True
                empty = directory / 'empty'
                empty.mkdir(mode=0o700)
                self.docker('cp', str(empty) + '/.', self.target + ':' + REMOTE)
                empty.rmdir()
                self.docker('cp', str(directory) + '/.', self.target + ':' + remote)
                if running:
                    self.docker('exec', self.target, 'sh', remote + '/runtime.sh', 'guard', state['iface'])
                    self.docker('exec', self.target, 'sh', '-c', 'mv -f -- "$1" "$2"',
                                'govpn', remote + '/start.sh', START)
                else:
                    self.docker('cp', str(start_file), self.target + ':' + START)
                # Durable desired policy precedes activation. On failure it stays
                # available for an explicit restore, alongside the previous backup.
                write_private(self.directory / 'state.json', json.dumps(state, indent=2) + '\n')
                if running:
                    self.docker('exec', self.target, 'sh', remote + '/runtime.sh', 'apply', state['iface'])
        except Exception:
            if mutated and running:
                # No automatic fail-open rollback. Stop pinned container on partial failure.
                self.docker('stop', '--time', '0', self.target, check=False)
            raise

    def prepare_stopped(self):
        state = self.state()
        if self.inspect():
            raise SafeError('prepare-stopped разрешен только для остановленного контейнера.')
        original = self.read_container(START)
        patched = patch_start(original, state['iface'])
        self.backup(original, state)
        self.install(state, patched, running=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Безопасное сохранение WARP для одного AWG контейнера')
    parser.add_argument('container')
    sub = parser.add_subparsers(dest='action', required=True)
    imp = sub.add_parser('import')
    imp.add_argument('--config', required=True)
    imp.add_argument('--clients', required=True)
    imp.add_argument('--iface', choices=('awg0', 'wg0'), required=True)
    apply = sub.add_parser('apply')
    apply.add_argument('clients', nargs='*', help='IPv4 /32; пустой список явно отключает WARP для всех')
    sub.add_parser('restore')
    sub.add_parser('prepare-stopped')
    sub.add_parser('selected')
    sub.add_parser('status')
    ep = sub.add_parser('endpoint')
    ep.add_argument('endpoint')
    replacement = sub.add_parser('replace-profile')
    replacement.add_argument('--config', required=True)
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        raise SafeError('Требуется root.')
    ctl = Controller(args.container)
    private_dir(ctl.root)
    private_dir(ctl.directory)
    lock_path = ctl.directory / 'lock'
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'import':
            ctl.import_state(args.config, args.clients, args.iface)
            print('Состояние сохранено. Для установки и применения выполните restore.')
        elif args.action == 'prepare-stopped':
            ctl.prepare_stopped()
            print('Hook установлен в остановленный контейнер. Запуск выполняется отдельно.')
        else:
            state = ctl.state()
            if args.action == 'selected':
                print('\n'.join(state['clients']))
            elif args.action == 'status':
                running = ctl.inspect()
                print(f"{ctl.name}: running={running}; saved IPv4 WARP clients={len(state['clients'])}; saved IPv6 policy=block")
            else:
                if args.action == 'apply':
                    state['clients'] = clients(args.clients)
                elif args.action == 'endpoint':
                    value = endpoint(args.endpoint)
                    state['profile'] = profile(re.sub(r'^Endpoint = .*$', 'Endpoint = ' + value,
                                                     state['profile'], flags=re.M))
                elif args.action == 'replace-profile':
                    state['profile'] = profile(Path(args.config).read_text())
                ctl.deploy(state)
                print('WARP сохранен и применен. IPv6 AWG заблокирован.')


def entry():
    try:
        main()
    except (SafeError, OSError, ValueError, KeyError, subprocess.SubprocessError):
        # Do not print exceptions: malformed input/command errors can include keys.
        print('Ошибка safe WARP. Проверьте формат, права, Docker и совместимость start.sh. '
              'При частичном применении контейнер останавливается; см. docs/warp-safety.md.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(entry())
