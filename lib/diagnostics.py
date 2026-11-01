"""Bounded, read-only connection report. No installers, keys, or third-party code.

A VPS probe is not a client packet-path or a Gemini eligibility test.
All displayed remote fields are validated; raw errors/configs never print.
"""
import ipaddress
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

TRACE = 'https://www.cloudflare.com/cdn-cgi/trace'
GEMINI = 'https://gemini.google.com/'

# Never read WG configuration or dump private keys. One bounded exec obtains
# counts/booleans and timestamps only. Exact rules, not arbitrary fwmark matches.
NETWORK = r'''
iface=awg0
ip link show awg0 >/dev/null 2>&1 || iface=wg0
ip link show "$iface" >/dev/null 2>&1 && echo awg=yes
test "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 && echo forward=yes
if command -v awg >/dev/null 2>&1; then tool=awg; else tool=wg; fi
if command -v timeout >/dev/null 2>&1; then
    handshakes=$(timeout 2 "$tool" show "$iface" latest-handshakes 2>/dev/null); code=$?
else
    handshakes=$("$tool" show "$iface" latest-handshakes 2>/dev/null); code=$?
fi
if [ "$code" = 0 ]; then
    echo handshake=yes
    printf '%s\n' "$handshakes" | awk -v now="$(date +%s)" 'BEGIN {n=0; a=0} NF==2 && $2 ~ /^[0-9]+$/ {n++; if($2>0 && now-$2>=0 && now-$2<180) a++} END {print "peers="n; print "active="a}'
fi
ip link show warp >/dev/null 2>&1 && echo warp=yes
ip -4 rule show | grep -q '^10900:.*fwmark 0x40000000/0x40000000 lookup 51888' && echo policy=yes
ip -4 route show table 51888 2>/dev/null | grep -q '^unreachable default.*metric 32767' && echo fallback=yes
ip -4 route show table 51888 2>/dev/null | grep -q '^default dev warp.*metric 10' && echo route=yes
iptables -w 2 -t filter -C FORWARD -i "$iface" -j GVPN_WARP_FWD 2>/dev/null && echo guard=yes
ip6tables -w 2 -t filter -C FORWARD -i "$iface" -m comment --comment govpn-warp-ipv6 -j DROP 2>/dev/null && echo ipv6forward=yes
ip6tables -w 2 -t filter -C INPUT -i "$iface" -m comment --comment govpn-warp-ipv6 -j DROP 2>/dev/null && echo ipv6input=yes
command -v curl >/dev/null 2>&1 && echo curl=yes
if [ "$#" -gt 0 ]; then
    selected_ok=yes
    for client in "$@"; do
        iptables -w 1 -t mangle -C GVPN_WARP_MARK -s "$client" -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || selected_ok=no
        iptables -w 1 -t filter -C GVPN_WARP_FWD -s "$client" ! -o warp -j DROP 2>/dev/null || selected_ok=no
        iptables -w 1 -t filter -C GVPN_WARP_IN -s "$client" -j DROP 2>/dev/null || selected_ok=no
        iptables -w 1 -t nat -C GVPN_WARP_NAT -s "$client" -o warp -j MASQUERADE 2>/dev/null || selected_ok=no
    done
    [ "$selected_ok" != yes ] || echo selection=yes
fi
true
'''


def run(argv, timeout=7, env=None):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
        return result.returncode == 0, result.stdout
    except (OSError, ValueError, subprocess.SubprocessError):
        return False, ''


def trace_fields(text):
    fields = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
    result = {}
    try:
        result['ip'] = str(ipaddress.IPv4Address(fields.get('ip', '')))
    except ipaddress.AddressValueError:
        return {}
    if re.fullmatch('[A-Z]{2}', fields.get('loc', '')):
        result['loc'] = fields['loc']
    if fields.get('warp') in ('on', 'off', 'plus'):
        result['warp'] = fields['warp']
    return result


def trace(prefix=(), interface=False):
    args = [*prefix, 'curl', '-q', '-4', '-fsS', '--noproxy', '*', '--connect-timeout', '3',
            '--max-time', '6', '--max-filesize', '8192']
    if interface:
        args += ['--interface', 'warp']
    ok, output = run([*args, TRACE], timeout=8)
    return trace_fields(output) if ok else {}


def route_fields(text):
    """Parse only the selected interface/source. Never display raw ip output."""
    if len(text) > 65536:
        raise ValueError('route size')
    rows = json.loads(text)
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        raise ValueError('route shape')
    row = rows[0]
    interface = row.get('dev', '')
    if not isinstance(interface, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}', interface):
        raise ValueError('interface')
    value = row.get('prefsrc', row.get('src', ''))
    if not isinstance(value, str):
        raise ValueError('source type')
    source = ipaddress.IPv4Address(value)
    if source.is_unspecified or source.is_multicast:
        raise ValueError('source')
    return {'dev': interface, 'source': str(source)}


def public_addresses(text, interface):
    if len(text) > 65536:
        raise ValueError('address size')
    rows = json.loads(text)
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict) or rows[0].get('ifname') != interface:
        raise ValueError('address shape')
    addresses = rows[0].get('addr_info')
    if not isinstance(addresses, list) or len(addresses) > 256:
        raise ValueError('address count')
    result = set()
    for entry in addresses:
        if not isinstance(entry, dict):
            raise ValueError('address entry')
        if entry.get('family') != 'inet':
            continue
        value = entry.get('local', '')
        if not isinstance(value, str):
            raise ValueError('address type')
        address = ipaddress.IPv4Address(value)
        if address.is_global and not address.is_multicast:
            result.add(str(address))
    return sorted(result, key=ipaddress.IPv4Address)


def ssh_server_ipv4(value):
    """SSH_CONNECTION is an optional hint, not a trusted desired-IP setting."""
    if len(value) > 1024:
        return None
    fields = value.split()
    if len(fields) != 4:
        return None
    try:
        ipaddress.ip_address(fields[0])
        if not all(re.fullmatch(r'[0-9]{1,5}', fields[i]) and 1 <= int(fields[i]) <= 65535 for i in (1, 3)):
            return None
        return str(ipaddress.IPv4Address(fields[2]))
    except ValueError:
        return None


BASE_TOOLS = ('curl', 'python3', 'ip', 'flock')
PACKAGES = {
    'apt-get': {'curl':'curl', 'python3':'python3', 'ip':'iproute2', 'flock':'util-linux', 'iptables':'iptables'},
    'apk': {'curl':'curl', 'python3':'python3', 'ip':'iproute2', 'flock':'util-linux', 'iptables':'iptables'},
    'dnf': {'curl':'curl', 'python3':'python3', 'ip':'iproute', 'flock':'util-linux', 'iptables':'iptables'},
}


def dependency_plan():
    missing = [name for name in BASE_TOOLS if not shutil.which(name)]
    manager = next((name for name in PACKAGES if shutil.which(name)), None)
    packages = sorted({PACKAGES[manager][name] for name in missing}) if manager else []
    return missing, manager, packages


def dependency_report(mode):
    report = Report(mode, '')
    report.line('Базовые зависимости GoVPN', '36')
    for name in BASE_TOOLS:
        found = bool(shutil.which(name))
        report.add('ok' if found else 'error', name, 'найден' if found else 'отсутствует; доступно отдельное исправление')
    if mode in ('amnezia', 'combo'):
        report.add('ok' if shutil.which('docker') else 'error', 'Docker CLI',
                   'найден' if shutil.which('docker') else 'установите Docker и Amnezia по официальной инструкции; GoVPN их не переустанавливает')
    report.line('wgcf нужен только для первой регистрации WARP и загружается его мастером с проверкой SHA256.', '37')
    report.line('Системные wg/wg-quick, YAML, qrencode и сканеры не требуются для списка клиентов AWG.', '37')
    report.line('Это проверка наличия команд. Состояние сети: главное меню 3.', '37')
    report.line('Успешно: '+str(sum(row[0] == 'ok' for row in report.rows))+' | Ошибки: '+str(sum(row[0] == 'error' for row in report.rows)), '37')
    return int(any(row[0] == 'error' for row in report.rows))


def repair_dependencies(lock_path=Path('/etc/govpn-dependencies.lock')):
    if os.geteuid() != 0:
        print('Исправление зависимостей требует root.', file=sys.stderr)
        return 1
    missing, manager, packages = dependency_plan()
    if not missing:
        print('Базовые зависимости уже доступны. Изменения не нужны.')
        return 0
    if not manager:
        print('Неизвестный пакетный менеджер. Автоматическое исправление не выполнялось.', file=sys.stderr)
        return 1
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Другое исправление уже выполняется.', file=sys.stderr)
            return 1
        # Recheck after acquiring the lock. Fixed package allowlist; no eval.
        missing, current, packages = dependency_plan()
        if current != manager:
            print('Состав инструментов изменился. Повторите проверку.', file=sys.stderr)
            return 1
        if not missing:
            return 0
        if manager == 'apt-get':
            print('[1/3] Обновляю список пакетов (до 120 с)...', flush=True)
            ok, _ = run(['apt-get', 'update'], timeout=120)
            if not ok:
                print('Не удалось обновить список пакетов. Установка не начиналась.', file=sys.stderr)
                return 1
            command = ['apt-get', 'install', '-y', '--no-install-recommends', *packages]
        elif manager == 'apk':
            command = ['apk', 'add', '--no-cache', *packages]
        else:
            command = ['dnf', 'install', '-y', *packages]
        print('[2/3] Устанавливаю: ' + ', '.join(packages) + ' (до 180 с)...', flush=True)
        ok, _ = run(command, timeout=180, env=dict(os.environ, DEBIAN_FRONTEND="noninteractive"))
        print('[3/3] Повторно проверяю наличие команд...', flush=True)
        remaining = [name for name in BASE_TOOLS if not shutil.which(name)]
        if not ok or remaining:
            print('Исправление не завершено. Проверьте пакетный менеджер; недоступны: ' + ', '.join(remaining or missing), file=sys.stderr)
            return 1
        print('Базовые зависимости установлены и проверены. Docker, SSH, AWG и firewall-правила не перенастраивались.')
        return 0


class Report:
    def __init__(self, mode, container, root=Path('/etc/amnezia-warp'), output=None):
        self.mode, self.container, self.root = mode, container, root
        self.output = output or sys.stdout
        self.rows = []
        self.host_route = {}
        self.addresses = None
        self.started = time.monotonic()
        self.color = self.output.isatty() and 'NO_COLOR' not in os.environ

    def line(self, text, color='0'):
        begin, end = (f'\033[{color}m', '\033[0m') if self.color else ('', '')
        print(begin + text + end, file=self.output, flush=True)

    def section(self, step, title):
        self.line(f'\n[{step}/5] {title} - проверка...', '36')

    def add(self, status, title, detail):
        self.rows.append((status, title, detail))
        icon, color = {'ok': ('OK', '32'), 'warn': ('!', '33'),
                       'error': ('X', '31'), 'skip': ('-', '37')}[status]
        self.line(f'  [{icon}] {title}: {detail}', color)

    def host(self):
        self.section(1, 'VPS и инструменты')
        self.host_route, self.addresses = {}, None
        missing = [c for c in ('ip', 'curl', 'python3') if not shutil.which(c)]
        self.add('error' if missing else 'ok', 'Инструменты', ', '.join(missing) + ' отсутствуют' if missing else 'базовые команды доступны')
        ok, output = run(['ip', '-j', '-4', 'route', 'get', '1.1.1.1'])
        try:
            if ok:
                self.host_route = route_fields(output)
                interface = self.host_route['dev']
                found, addresses = run(['ip', '-j', '-4', 'address', 'show', 'dev', interface])
                if found:
                    self.addresses = public_addresses(addresses, interface)
        except (ValueError, TypeError):
            pass
        detail = (f'{self.host_route["dev"]}; исходный IPv4 {self.host_route["source"]}' if self.host_route else
                  'маршрут получен, но интерфейс/IPv4 не разобраны' if ok else 'не удалось проверить за 7 с')
        self.add('ok' if self.host_route else 'warn' if ok else 'error', 'Маршрут VPS', detail)
        try:
            space = shutil.disk_usage('/').free // (1024**2)
            self.add('warn' if space < 256 else 'ok', 'Место на диске', f'{space} МБ свободно')
        except OSError:
            self.add('warn', 'Место на диске', 'недоступно')

    def internet(self):
        self.section(2, 'DNS и HTTPS с VPS')
        data = trace()
        if data:
            self.add('ok', 'DNS + TLS + HTTPS', f'IPv4 {data["ip"]}; страна по Cloudflare: {data.get("loc", "неизвестна")}')
        else:
            self.add('error', 'DNS + TLS + HTTPS', 'нет ответа Cloudflare за 6 с; DNS, сеть или удаленный сервис недоступны')
        self.egress(data)
        ok, code = run(['curl', '-q', '-4', '-sS', '--noproxy', '*', '--connect-timeout', '3', '--max-time', '6',
                        '-o', '/dev/null', '-w', '%{http_code}', GEMINI], timeout=8)
        code = code.strip()
        valid = ok and re.fullmatch(r'[1-5][0-9]{2}', code)
        self.add('ok' if valid and int(code) < 400 else 'warn', 'HTTPS до Gemini',
                 f'HTTP {code}; это только ответ сайта, не проверка региона или аккаунта' if valid else 'ответ не получен за 6 с; доступ с устройства не определен')

    def egress(self, data):
        external = data.get('ip')
        ssh = ssh_server_ipv4(os.environ.get('SSH_CONNECTION', ''))
        if not self.host_route:
            self.add('skip', 'Выбор IP выхода', 'сопоставление с локальной сетью не выполнено; маршрут не разобран')
            return
        source = self.host_route['source']
        details = [f'исходный IP маршрута к 1.1.1.1: {source}']
        if external:
            details.append(f'внешний IP VPS: {external}')
        if ssh:
            details.append(f'адрес текущего SSH: {ssh}')
        multiple = self.addresses is not None and len(self.addresses) > 1
        different = bool(ssh and external and ssh != external)
        translated = bool(external and external != source and ipaddress.IPv4Address(source).is_global)
        if multiple:
            shown = ', '.join(self.addresses[:8])
            if len(self.addresses) > 8:
                shown += f' (всего {len(self.addresses)})'
            details.append(f'на {self.host_route["dev"]} несколько публичных IPv4: {shown}')
        if different:
            details.append('SSH и внешний выход различаются')
        if translated:
            details.append('внешний IP отличается от публичного исходного IP маршрута; возможны NAT/туннель или другой путь к сервису проверки')
        if multiple or different or translated:
            details.append('это может быть намеренно; после смены IP проверьте, через какой адрес должны выходить VPS и клиенты')
            self.add('warn', 'Выбор IP выхода', '; '.join(details))
            self.line('    Старый/новый IP автоматически не определяется. SSH_CONNECTION - подсказка, не целевая настройка.', '37')
            self.line('    На устройстве с Amnezia и выходом VPS откройте https://api.ipify.org и сравните с нужным IP.', '36')
            self.line('    Одного изменения маршрута VPS может быть недостаточно: проверьте Docker NAT/MASQUERADE и сохранение сетевой настройки.', '33')
            self.line('    GoVPN не меняет адреса, маршруты или NAT автоматически и не проверяет право аккаунта на Gemini.', '37')
        elif not external or self.addresses is None:
            self.add('skip', 'Выбор IP выхода', '; '.join(details) + '; часть данных недоступна, сравнение неполное')
        else:
            self.add('ok', 'Выбор IP выхода', '; '.join(details) + '; это снимок выхода VPS, не проверка пути клиента')

    def saved_policy(self):
        path = self.root / self.container / 'state.json'
        if not path.exists():
            return None
        if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
            raise ValueError('private state')
        data = json.loads(path.read_text())
        enabled = data.get('enabled', True)
        selected = data['clients']
        if type(enabled) is not bool or not isinstance(selected, list):
            raise ValueError('policy')
        for value in selected:
            if not isinstance(value, str) or '/' not in value or ipaddress.ip_network(value).prefixlen != 32 or ipaddress.ip_network(value).version != 4:
                raise ValueError('selection')
        self.selected = sorted(set(selected))
        return enabled, len(self.selected)

    def awg(self):
        self.section(3, 'Amnezia и клиенты')
        if self.mode not in ('amnezia', 'combo'):
            self.add('skip', 'AWG', 'не используется в этом режиме')
            return None
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', self.container):
            self.add('error', 'Контейнер', 'имя недоступно; сеть не изменялась')
            return None
        ok, output = run(['docker', 'inspect', '--format', '{{.State.Running}}', self.container], timeout=6)
        if not ok or output.strip() != 'true':
            self.add('error', 'Контейнер AWG', 'остановлен или Docker не отвечает за 6 с')
            return None
        selection = []
        try:
            policy = self.saved_policy()
            if policy and policy[0]:
                selection = self.selected
        except (OSError, ValueError, KeyError, TypeError):
            pass  # The WARP section reports an invalid state, never substitutes a policy.
        ok, output = run(['docker', 'exec', self.container, 'sh', '-c', NETWORK, 'govpn-report', *selection], timeout=10)
        if not ok:
            self.add('error', 'Сеть AWG', 'нет ответа за 10 с; перезапуск автоматически не выполняется')
            return None
        flags = dict(line.split('=', 1) for line in output.splitlines() if re.fullmatch(r'[a-z0-9]+=(yes|[0-9]{1,6})', line))
        self.add('ok' if flags.get('awg') == 'yes' else 'error', 'Интерфейс AWG', 'найден' if flags.get('awg') == 'yes' else 'не найден')
        self.add('ok' if flags.get('forward') == 'yes' else 'error', 'Передача IPv4', 'включена в контейнере' if flags.get('forward') == 'yes' else 'выключена или недоступна')
        if flags.get('handshake') == 'yes':
            self.add('ok' if int(flags.get('active', '0')) else 'warn', 'Клиенты',
                     f'настроено в live AWG: {flags.get("peers", "?")}; handshake за 3 мин: {flags.get("active", "?")}; это не тест интернета клиента')
        else:
            self.add('warn', 'Клиенты', 'данные handshake недоступны; это не означает отсутствие клиентов')
        return flags

    def warp(self, flags):
        self.section(4, 'WARP, маршруты и IPv6')
        if self.mode not in ('amnezia', 'combo'):
            if self.mode in ('3xui', 'combo'):
                ok, output = run(['warp-cli', '--accept-tos', 'status'])
                connected = ok and bool(re.search(r'\bConnected\b', output))
                self.add('ok' if connected else 'warn', 'Host WARP', 'подключен по данным warp-cli' if connected else 'не подключен или команда недоступна')
            else:
                self.add('skip', 'WARP', 'не используется в режиме bridge')
            return
        try:
            policy = self.saved_policy()
        except (OSError, ValueError, KeyError, TypeError):
            self.add('error', 'Настройки WARP', 'не удалось безопасно прочитать состояние; ключи не выводятся')
            return
        if policy is None:
            self.add('warn' if flags and flags.get('warp') else 'skip', 'WARP', 'нет управляемой настройки; возможен прежний туннель' if flags and flags.get('warp') else 'не настроен; для прямого выхода через VPS не обязателен')
            return
        enabled, count = policy
        if not enabled:
            self.add('warn' if flags and flags.get('warp') else 'skip', 'WARP', 'выключен; активный интерфейс все еще найден' if flags and flags.get('warp') else 'отключен; повторное включение доступно в меню 2')
            return
        self.add('ok' if count else 'warn', 'Выбор маршрута', f'{count} клиентов направлены через WARP')
        if flags is None:
            self.add('error', 'Проверка WARP', 'AWG недоступен; рабочее подключение не подтверждено')
            return
        for key, title in (('warp', 'Интерфейс WARP'), ('policy', 'Правило маршрутизации'),
                           ('route', 'Маршрут через туннель'), ('fallback', 'Резервный запрет прямого выхода'),
                           ('guard', 'Подключение защитной цепочки'), ('ipv6forward', 'Запрет IPv6 FORWARD'),
                           ('ipv6input', 'Запрет IPv6 INPUT')):
            self.add('ok' if flags.get(key) == 'yes' else 'error', title, 'найден' if flags.get(key) == 'yes' else 'не найден или не удалось проверить')
        if count:
            self.add('ok' if flags.get('selection') == 'yes' else 'error', 'Правила выбранных клиентов',
                     'MARK, запрет прямого выхода, INPUT и NAT найдены' if flags.get('selection') == 'yes' else 'часть правил отсутствует или не проверена')
        if flags.get('warp') == 'yes' and flags.get('curl') == 'yes':
            data = trace(('docker', 'exec', self.container), interface=True)
            good = data.get('warp') in ('on', 'plus')
            self.add('ok' if good else 'error', 'HTTPS через WARP',
                     f'Cloudflare подтвердил WARP; IPv4 {data["ip"]}; страна {data.get("loc", "?")}' if good else 'WARP не подтвержден ответом Cloudflare за 6 с')
        else:
            self.add('warn', 'HTTPS через WARP', 'не проверен: нет интерфейса или curl в контейнере; ничего не устанавливалось')

    def summary(self):
        self.section(5, 'Итог')
        counts = {status: sum(row[0] == status for row in self.rows) for status in ('ok', 'warn', 'error', 'skip')}
        self.line(f'  Успешно: {counts["ok"]} | Замечания: {counts["warn"]} | Ошибки: {counts["error"]} | Пропущено: {counts["skip"]}', '37')
        self.line(f'  Время: {time.monotonic() - self.started:.1f} с. Настройки не изменялись.', '37')
        self.line('  Сначала устраните отмеченные ошибки; WARP восстанавливается через меню 2.' if counts['error'] else '  Серверные проверки завершены. Полный путь клиента ими не подтверждается.', '33' if counts['error'] else '36')
        self.line('  На устройстве проверьте VPN, внешний IPv4 DNS и маршрут всего трафика.', '37')
        self.line('  При managed WARP IPv6 должен идти в VPN и блокироваться там либо быть отключен на устройстве.', '37')
        self.line('  Регион/аккаунт Gemini и утечки мимо VPN с VPS проверить нельзя.', '33')
        self.line('  Исправление: меню диагностики -> действия исправления; WARP не нужен, если Gemini работает через VPS.', '36')
        return int(bool(counts['error']))

    def execute(self):
        self.line('GoVPN - общая проверка соединения', '36')
        self.host()
        self.internet()
        flags = self.awg()
        self.warp(flags)
        return self.summary()


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('amnezia', 'combo', '3xui', 'bridge'):
        return 2
    try:
        scope = os.environ.get('GOVPN_DIAG_SCOPE', 'connection')
        if scope == 'dependencies':
            return dependency_report(sys.argv[1])
        if scope == 'repair':
            return repair_dependencies()
        if scope != 'connection':
            return 2
        return Report(sys.argv[1], sys.argv[2]).execute()
    except (OSError, ValueError, KeyError, TypeError):
        print('Исправление не завершено; проверьте состояние пакетов.' if os.environ.get('GOVPN_DIAG_SCOPE') == 'repair' else 'Не удалось завершить диагностику. Настройки не изменялись; ключи и сырой вывод скрыты.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
