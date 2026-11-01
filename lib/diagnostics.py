"""Bounded, read-only connection report. No installers, keys, or third-party code.

A VPS probe is not a client packet-path or a Gemini eligibility test.
All displayed remote fields are validated; raw errors/configs never print.
"""
import ipaddress
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


def run(argv, timeout=7):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
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


class Report:
    def __init__(self, mode, container, root=Path('/etc/amnezia-warp'), output=None):
        self.mode, self.container, self.root = mode, container, root
        self.output = output or sys.stdout
        self.rows = []
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
        missing = [c for c in ('ip', 'curl', 'python3') if not shutil.which(c)]
        self.add('error' if missing else 'ok', 'Инструменты', ', '.join(missing) + ' отсутствуют' if missing else 'базовые команды доступны')
        ok, _ = run(['ip', '-4', 'route', 'get', '1.1.1.1'])
        self.add('ok' if ok else 'error', 'Маршрут VPS', 'найден' if ok else 'не удалось проверить за 7 с')
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
        ok, code = run(['curl', '-q', '-4', '-sS', '--noproxy', '*', '--connect-timeout', '3', '--max-time', '6',
                        '-o', '/dev/null', '-w', '%{http_code}', GEMINI], timeout=8)
        code = code.strip()
        valid = ok and re.fullmatch(r'[1-5][0-9]{2}', code)
        self.add('ok' if valid and int(code) < 400 else 'warn', 'HTTPS до Gemini',
                 f'HTTP {code}; это только ответ сайта, не проверка региона или аккаунта' if valid else 'ответ не получен за 6 с; доступ с устройства не определен')

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
        return Report(sys.argv[1], sys.argv[2]).execute()
    except (OSError, ValueError, KeyError, TypeError):
        print('Не удалось завершить диагностику. Настройки не изменялись; ключи и сырой вывод скрыты.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
