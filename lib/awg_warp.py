"""Safe, single-container WARP controller. Embedded in govpn.sh by tools/bundle.py.

No Docker socket is touched at import time. Errors never include command output,
which may contain private WireGuard keys.
"""
import argparse
import base64
import fcntl
import hashlib
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

# Pinned upstream release assets, verified against GitHub release digests.
# https://github.com/ViRb3/wgcf/releases/tag/v2.3.1
WGCF_VERSION = '2.3.1'
WGCF_ASSETS = {
    'x86_64': ('amd64', '4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8'),
    'aarch64': ('arm64', '710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301'),
    'armv7l': ('armv7', 'de57cf6cdc8678cb15ae1cde75dacca39959e30a3a27482a14b9828da2308f03'),
}

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
# Explicit removal permits direct routing and must work without wg-quick or a
# working tunnel. Keep ingress blocked until only our resources are removed.
if [ "$action" = remove ]; then
    v6=0
    ip6tables -t filter -S >/dev/null 2>&1 && v6=1
    for chain in FORWARD INPUT; do
        add iptables filter "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP
        if [ "$v6" = 1 ]; then
            add ip6tables filter "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP
        fi
    done
    for spec in 'mangle PREROUTING GVPN_WARP_MARK' 'filter FORWARD GVPN_WARP_FWD' 'filter INPUT GVPN_WARP_IN'; do
        set -- $spec
        while ensure iptables -t "$1" -C "$2" -i "$iface" -j "$3"; do
            ensure iptables -t "$1" -D "$2" -i "$iface" -j "$3"
        done
    done
    while ensure iptables -t nat -C POSTROUTING -j GVPN_WARP_NAT; do
        ensure iptables -t nat -D POSTROUTING -j GVPN_WARP_NAT
    done
    for spec in 'mangle GVPN_WARP_MARK' 'filter GVPN_WARP_FWD' 'filter GVPN_WARP_IN' 'nat GVPN_WARP_NAT'; do
        set -- $spec
        if ensure iptables -t "$1" -S "$2" >/dev/null; then
            ensure iptables -t "$1" -F "$2"
            ensure iptables -t "$1" -X "$2"
        fi
    done
    while ensure iptables -t mangle -C PREROUTING -i "$iface" -j AWG_WARP; do
        ensure iptables -t mangle -D PREROUTING -i "$iface" -j AWG_WARP
    done
    if ensure iptables -t mangle -S AWG_WARP >/dev/null; then
        ensure iptables -t mangle -F AWG_WARP
        ensure iptables -t mangle -X AWG_WARP
    fi
    while ensure iptables -t mangle -C PREROUTING -i "$iface" -j MARK --set-mark 100; do
        ensure iptables -t mangle -D PREROUTING -i "$iface" -j MARK --set-mark 100
    done
    while ensure iptables -t nat -C POSTROUTING -o warp -j MASQUERADE; do
        ensure iptables -t nat -D POSTROUTING -o warp -j MASQUERADE
    done
    while ensure iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; do
        ensure iptables -t mangle -D FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    done
    while ip -4 rule del priority 10900 fwmark "$mark" lookup "$table" 2>/dev/null; do :; done
    while ip -4 rule del priority 100 fwmark 100 lookup 100 2>/dev/null; do :; done
    if ip link show warp >/dev/null 2>&1; then ip link delete warp; fi
    ip -4 route del unreachable default metric 32767 table "$table" 2>/dev/null || true
    for chain in FORWARD INPUT; do
        if [ "$v6" = 1 ]; then
            while ensure ip6tables -t filter -C "$chain" -i "$iface" -m comment --comment govpn-warp-ipv6 -j DROP; do
                ensure ip6tables -t filter -D "$chain" -i "$iface" -m comment --comment govpn-warp-ipv6 -j DROP
            done
            while ensure ip6tables -t filter -C "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP; do
                ensure ip6tables -t filter -D "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP
            done
        fi
        while ensure iptables -t filter -C "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP; do
            ensure iptables -t filter -D "$chain" -i "$iface" -m comment --comment govpn-warp-boot -j DROP
        done
    done
    exit 0
fi
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


def unpatch_start(text):
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
    return '\n'.join(clean) + '\n'


def patch_start(text, iface):
    if iface not in ('awg0', 'wg0'):
        raise SafeError('Неизвестный интерфейс AWG.')
    clean = unpatch_start(text).splitlines()
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

    def find_iface(self):
        for iface in ('awg0', 'wg0'):
            for path in ('/opt/amnezia/awg/' + iface + '.conf', '/etc/wireguard/' + iface + '.conf'):
                if self.read_container(path, optional=True) is not None:
                    return iface
        raise SafeError('Конфигурация AWG не найдена; контейнер не изменен.')

    def saved_clients(self, required=False):
        if (self.directory / 'state.json').exists():
            return self.state()['clients']
        for path in (self.directory / 'clients.list', self.root / 'clients.list', self.root / 'warp-clients.list'):
            if path.is_file() and not path.is_symlink():
                return clients(path.read_text().splitlines())
        for path in ('/opt/warp/clients.list', '/opt/amnezia/awg/warp_clients.txt'):
            content = self.read_container(path, optional=True)
            if content is not None:
                return clients(content.splitlines())
        if required:
            raise SafeError('Список WARP-клиентов не найден. Выберите клиентов в пункте 3 и примените выбор; пустой список автоматически не подставляется.')
        return []

    def existing_profile(self):
        """Read-only discovery. Invalid existing data must never trigger registration."""
        if (self.directory / 'state.json').exists():
            return self.state()['profile']
        original = self.read_container(START)
        for path in (self.directory / 'warp.conf', self.root / 'warp.conf', self.root / 'wgcf-profile.conf'):
            if path.is_file() and not path.is_symlink():
                return profile(path.read_text())
        releases = re.findall(r'/opt/govpn-warp/[a-f0-9]{32}/runtime.sh', original)
        candidates = [s[:-len('runtime.sh')] + 'warp.conf' for s in releases]
        candidates += ['/opt/warp/warp.conf', '/etc/amnezia/amneziawg/warp.conf', '/etc/wireguard/warp.conf']
        for path in dict.fromkeys(candidates):
            content = self.read_container(path, optional=True)
            if content is not None:
                return profile(content)
        return None

    def adopt(self, replacement=None, selection=None):
        """Reuse existing credentials; never register a new account implicitly."""
        if (self.directory / 'state.json').exists():
            return self.state()
        self.inspect()
        original = self.read_container(START)
        iface = self.find_iface()
        patch_start(original, iface)  # preflight before recording the migration
        data = replacement if replacement is not None else self.existing_profile()
        if data is None:
            raise SafeError('Профиль WARP отсутствует: для первой установки выберите создание нового профиля в меню 1 → 3. Переустановка (setup) аккаунт не создает.')
        selected = self.saved_clients(required=True) if selection is None else clients(selection)
        state = {'version': 1, 'profile': data, 'clients': selected, 'iface': iface, 'enabled': False}
        self.backup(original, None)
        write_private(self.directory / 'state.json', json.dumps(state, indent=2) + '\n')
        return state

    def prepare_dependencies(self, install=False):
        """Preflight before account creation or ingress guard. Never restart AWG."""
        if not self.inspect():
            raise SafeError('Первая установка требует работающего AWG контейнера.')
        check = 'for c in bash wg wg-quick ip iptables ip6tables; do command -v "$c" >/dev/null || exit 1; done'
        if self.docker('exec', self.target, 'sh', '-c', check, check=False).returncode:
            if not install:
                raise SafeError('В контейнере нет инструментов WARP. Повторите первую установку с --install-deps; сеть AWG не изменена.')
            packages = '''set -eu
if command -v apk >/dev/null; then
    apk add --no-cache bash wireguard-tools iproute2 iptables
elif command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bash wireguard-tools iproute2 iptables
else
    exit 1
fi'''
            if self.docker('exec', self.target, 'sh', '-c', packages, check=False).returncode:
                raise SafeError('Не удалось установить WARP packages в контейнере; AWG не перезапускался. Проверьте доступ к package repositories.')
            if self.docker('exec', self.target, 'sh', '-c', check, check=False).returncode:
                raise SafeError('После установки packages инструменты WARP недоступны; сеть AWG не изменена.')
        for tool in ('iptables', 'ip6tables'):
            if self.docker('exec', self.target, tool, '-w', '10', '-t', 'filter', '-S', check=False).returncode:
                raise SafeError('Недоступен IPv4/IPv6 firewall контейнера; применение WARP не начиналось.')
        # A transient unconfigured link tests kernel support without routing traffic.
        name = 'gvpn' + uuid.uuid4().hex[:10]
        if self.docker('exec', self.target, 'ip', 'link', 'add', name, 'type', 'wireguard', check=False).returncode:
            raise SafeError('Ядро/контейнер не позволяет создать WireGuard интерфейс для WARP. AWG не изменен; нужен WireGuard kernel support и NET_ADMIN.')
        try:
            if self.docker('exec', self.target, 'wg', 'show', name, 'public-key', check=False).returncode:
                raise SafeError('Команда wg несовместима с WireGuard kernel interface. Инструменты AWG не подменяются автоматически; сеть AWG не изменена.')
        finally:
            self.docker('exec', self.target, 'ip', 'link', 'delete', name)

    def wgcf_binary(self):
        machine = os.uname().machine
        if os.uname().sysname != 'Linux' or machine not in WGCF_ASSETS:
            raise SafeError('Автоматическая регистрация поддерживает Linux x86_64/aarch64/armv7l. Используйте import готового профиля.')
        arch, digest = WGCF_ASSETS[machine]
        cache = self.root / 'tools'
        private_dir(cache)
        binary = cache / ('wgcf-' + WGCF_VERSION + '-' + arch)

        def valid(path):
            return (path.is_file() and not path.is_symlink()
                    and hashlib.sha256(path.read_bytes()).hexdigest() == digest)

        if not valid(binary):
            with tempfile.TemporaryDirectory(dir=cache) as tmp:
                download = Path(tmp) / 'wgcf'
                url = f'https://github.com/ViRb3/wgcf/releases/download/v{WGCF_VERSION}/wgcf_{WGCF_VERSION}_linux_{arch}'
                result = subprocess.run(['curl', '-fsSL', '--proto', '=https', '--proto-redir', '=https',
                                         '--connect-timeout', '10', '--max-time', '90', '--max-filesize',
                                         '41943040', url, '-o', str(download)], capture_output=True, timeout=100)
                if result.returncode or not valid(download):
                    raise SafeError('Не удалось скачать wgcf или SHA256 не совпадает. Код не запускался, регистрация не начиналась.')
                download.chmod(0o700)
                os.replace(download, binary)
        binary.chmod(0o700)
        return binary

    def bootstrap(self, selection, accept_tos=False, install_deps=False, source=None):
        """Explicit first install only. Persist credentials before touching routes."""
        if selection is None:
            raise SafeError('Для первой установки нужен явный --clients со списком IPv4 /32; --clients без адресов означает выбор никого.')
        selected = clients(selection)
        self.inspect()
        if self.existing_profile() is not None:
            raise SafeError('Профиль уже существует. Используйте setup, новая регистрация не выполнялась.')
        original = self.read_container(START)
        patch_start(original, self.find_iface())
        data = profile(Path(source).read_text()) if source else None
        if data is None and not accept_tos:
            raise SafeError('Новая регистрация требует --accept-tos после принятия условий Cloudflare. Можно импортировать готовый профиль через --config.')
        self.prepare_dependencies(install_deps)
        if data is None:
            binary = self.wgcf_binary()
            registration = self.directory / 'registration'
            private_dir(registration)
            account = registration / 'wgcf-account.toml'
            generated = registration / 'wgcf-profile.conf'
            attempt = registration / 'attempt.json'
            if any(p.is_symlink() for p in (account, generated, attempt)):
                raise SafeError('Файлы регистрации не должны быть символическими ссылками.')
            env = {k: v for k, v in os.environ.items() if not k.startswith('WGCF_')}

            def run(*args):
                try:
                    result = subprocess.run([str(binary), '--config', str(account), *args], cwd=registration,
                                            env=env, capture_output=True, timeout=120)
                except (OSError, subprocess.SubprocessError):
                    raise SafeError('wgcf не завершился. Данные регистрации сохранены; повторная регистрация автоматически не выполняется.') from None
                if result.returncode:
                    raise SafeError('wgcf завершился ошибкой. Возможно, Cloudflare недоступен или отклонил регистрацию. Вывод скрыт для защиты ключей; сохраненные данные не удалены.')

            if not account.exists():
                if attempt.exists():
                    raise SafeError('Предыдущая регистрация не дала локальный account. Повторная регистрация заблокирована: проверьте каталог registration или используйте --config с готовым профилем.')
                write_private(attempt, json.dumps({'version': WGCF_VERSION, 'registration_started': True}) + '\n')
                run('register', '--accept-tos')
            if not account.is_file() or not account.stat().st_size:
                raise SafeError('wgcf не сохранил account. Повторная регистрация заблокирована; сеть AWG не изменена.')
            account.chmod(0o600)
            # Resume with the same account after a failed generate; never delete it.
            if not generated.exists():
                run('generate', '--profile', str(generated), '--keepalive', '25')
            if not generated.is_file():
                raise SafeError('Профиль не создан; account сохранен для повторной генерации.')
            generated.chmod(0o600)
            data = profile(generated.read_text())
        state = self.adopt(replacement=data, selection=selected)
        state['enabled'] = True
        return self.deploy(state)

    def remove(self):
        """Remove active WARP even when managed state was never imported."""
        running = self.inspect()
        original = self.read_container(START)
        plain = unpatch_start(original)
        state = self.state() if (self.directory / 'state.json').exists() else None
        iface = state['iface'] if state else self.find_iface()
        self.backup(original, state)
        mutated = False
        try:
            with tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                remote = REMOTE + '/' + uuid.uuid4().hex
                write_private(directory / 'runtime.sh', RUNTIME)
                write_private(directory / 'start.sh', plain)
                (directory / 'start.sh').chmod(0o700)
                empty = directory / 'empty'
                empty.mkdir(mode=0o700)
                mutated = True
                self.docker('cp', str(empty) + '/.', self.target + ':' + REMOTE)
                empty.rmdir()
                self.docker('cp', str(directory) + '/.', self.target + ':' + remote)
                if running:
                    self.docker('exec', self.target, 'sh', '-c', 'mv -f -- "$1" "$2"',
                                'govpn', remote + '/start.sh', START)
                else:
                    self.docker('cp', str(directory / 'start.sh'), self.target + ':' + START)
                if state:
                    state['enabled'] = False
                    write_private(self.directory / 'state.json', json.dumps(state, indent=2) + '\n')
                if running:
                    self.docker('exec', self.target, 'sh', remote + '/runtime.sh', 'remove', iface)
        except Exception:
            if mutated and running:
                self.docker('stop', '--time', '0', self.target, check=False)
            raise

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

    def deploy(self, state, allow_stopped=False):
        running = self.inspect()
        original = self.read_container(START)
        patched = patch_start(original, state['iface'])
        self.backup(original, self.state())
        if not running and not allow_stopped:
            raise SafeError('Контейнер остановлен. Выберите setup для переустановки или prepare-stopped для включенного состояния.')
        self.install(state, patched, running=running)
        return running

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
        if state.get('enabled') is False:
            raise SafeError('WARP удален. Для повторной установки используйте setup; restore отключен до установки.')
        if self.inspect():
            raise SafeError('prepare-stopped разрешен только для остановленного контейнера.')
        original = self.read_container(START)
        patched = patch_start(original, state['iface'])
        self.backup(original, state)
        self.install(state, patched, running=False)


def main(argv=None):
    os.umask(0o077)
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
    sub.add_parser('profile-source')
    setup = sub.add_parser('setup')
    setup.add_argument('--install-deps', action='store_true')
    first = sub.add_parser('bootstrap', help='Первая установка: отдельная регистрация либо готовый профиль')
    first.add_argument('--clients', nargs='*', default=None)
    first.add_argument('--accept-tos', action='store_true')
    first.add_argument('--install-deps', action='store_true')
    first.add_argument('--config')
    sub.add_parser('remove')
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
        elif args.action == 'remove':
            ctl.remove()
            print('Активный WARP удален. Клиенты могут выходить напрямую; сохраненные профили и backups оставлены.')
        elif args.action == 'selected':
            ctl.inspect()
            print('\n'.join(ctl.saved_clients()))
        elif args.action == 'status':
            running = ctl.inspect()
            exists = (ctl.directory / 'state.json').exists()
            state = ctl.state() if exists else None
            count = len(state['clients']) if state else len(ctl.saved_clients())
            enabled = state.get('enabled', True) if state else 'legacy/unknown'
            print(f'{ctl.name}: running={running}; managed_state={exists}; enabled={enabled}; saved_clients={count}')
        elif args.action == 'profile-source':
            ctl.inspect()
            print('saved' if ctl.existing_profile() is not None else 'missing')
        elif args.action == 'bootstrap':
            running = ctl.bootstrap(args.clients, args.accept_tos, args.install_deps, args.config)
            print('Профиль создан/импортирован, сохранен и применен. IPv6 AWG заблокирован. Выбранных клиентов: ' + str(len(clients(args.clients))))
        else:
            if args.action == 'setup' and args.install_deps and ctl.inspect():
                ctl.prepare_dependencies(install=True)
            replacement = profile(Path(args.config).read_text()) if args.action == 'replace-profile' else None
            selection = clients(args.clients) if args.action == 'apply' else None
            state = ctl.adopt(replacement, selection)
            if args.action == 'restore' and state.get('enabled') is False:
                raise SafeError('WARP еще не установлен или был удален. Выберите переустановку (setup).')
            state['enabled'] = True
            if args.action == 'apply':
                state['clients'] = clients(args.clients)
            elif args.action == 'endpoint':
                value = endpoint(args.endpoint)
                state['profile'] = profile(re.sub(r'^Endpoint = .*$', 'Endpoint = ' + value,
                                                 state['profile'], flags=re.M))
            elif args.action == 'replace-profile':
                state['profile'] = replacement
            running = ctl.deploy(state, allow_stopped=args.action == 'setup')
            if running:
                print('WARP сохранен и применен. IPv6 AWG заблокирован. Выбранных клиентов: ' + str(len(state['clients'])))
            else:
                print('WARP подготовлен в остановленном контейнере. Контейнер не запускался; запуск выполняется отдельно.')


def entry():
    try:
        main()
    except SafeError as error:
        # SafeError messages are fixed diagnostics, never raw subprocess output.
        print('Ошибка WARP: ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        # Do not print exceptions: malformed input/command errors can include keys.
        print('Ошибка safe WARP. Проверьте формат, права, Docker и совместимость start.sh. '
              'При частичном применении контейнер останавливается; см. docs/warp-safety.md.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(entry())
