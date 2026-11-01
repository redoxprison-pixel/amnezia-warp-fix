"""Optional OpenFlux L4 reserve and client-side country routing exports.

No AWG/Docker/firewall/SSH mutation. Secrets stay in root-private files;
public GitHub/RIPE downloads are bounded and binaries have pinned hashes.
"""
import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

VERSION = 'v0.17.1'
ASSETS = {
    'x86_64': ('amd64', 'c0d00461e8cc59e48429b239fd8044b1c1aaa3769968a7c9160c488f4bd63f3b'),
    'aarch64': ('arm64', '053456982e0668d60f7533c91ec4703870553b5022403abfd072dbf1fe57483d'),
}
ROOT = Path('/etc/govpn/openflux')
BINARY = Path('/opt/govpn-openflux') / VERSION / 'openflux'
UNIT = Path('/etc/systemd/system/govpn-openflux.service')
SERVICE = 'govpn-openflux.service'
ROUTING = Path('/etc/govpn/routing')


class AccessError(Exception):
    pass


def directory(path):
    # Refuse symlinks in every managed ancestor, not just the leaf.
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise AccessError('Управляемый каталог не должен содержать symlink.')
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    if path.stat().st_uid != os.geteuid():
        raise AccessError('Неверный владелец управляемого каталога.')
    path.chmod(0o700)


def atomic(path, data, mode=0o600):
    if path.is_symlink():
        raise AccessError('Управляемый файл не должен быть symlink.')
    fd, temp = tempfile.mkstemp(prefix='.new-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data.encode() if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp)


def command(args, timeout=15, data=None):
    try:
        result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        raise AccessError('Операция не завершена в отведенное время. Сырой вывод скрыт для защиты данных.') from None
    if result.returncode:
        raise AccessError('Команда завершилась ошибкой. Проверьте зависимости и доступ к сервису; секреты и сырой вывод скрыты.')
    return result.stdout


def download(url, path, limit):
    command(['curl', '-q', '-fsSL', '--proto', '=https', '--proto-redir', '=https',
             '--connect-timeout', '10', '--max-time', '60', '--max-filesize', str(limit),
             url, '-o', str(path)], timeout=70)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise AccessError('Загрузка не является допустимым файлом.')


def document_url(value):
    # Upstream INI treats # and ; as comments. Reject rather than truncate.
    if len(value) > 2048 or any(ord(c) < 33 or ord(c) == 127 for c in value) or any(c in value for c in '#;\\'):
        raise AccessError('Недопустимый адрес документа.')
    parsed = urlsplit(value)
    if parsed.scheme != 'https' or parsed.hostname not in ('docs.yandex.ru', 'docs.yandex.com') or parsed.port not in (None, 443) or parsed.username or parsed.password or not parsed.path.startswith('/docs/'):
        raise AccessError('Нужна HTTPS ссылка на документ docs.yandex.ru/docs/ или docs.yandex.com/docs/.')
    return value


def node_config(url):
    value = document_url(url)
    return ('[Interface]\nRole = exit\nMode = l4\nCodec = batched\n'
            'CookieStore = /var/lib/govpn-openflux/cookies.json\nURL = ' + value
            + '\n\n[Transport "yandex"]\nPriority = 50\nURL = ' + value + '\n')


def service_unit(binary=BINARY, root=ROOT):
    # All paths are fixed installation paths, never derived from user input.
    return f'''[Unit]
Description=GoVPN optional OpenFlux L4 reserve
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
DynamicUser=yes
LoadCredential=configuration:{root}/exit.conf
LoadCredential=secret:{root}/secret.key
StateDirectory=govpn-openflux
StateDirectoryMode=0700
WorkingDirectory=/var/lib/govpn-openflux
ExecStart={binary} --config=%d/configuration --encryption-key-file=%d/secret
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=
AmbientCapabilities=
LimitCORE=0
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
'''


class Reserve:
    def __init__(self, root=ROOT, binary=BINARY, unit=UNIT):
        self.root, self.binary, self.unit = root, binary, unit

    @contextlib.contextmanager
    def lock(self):
        directory(self.root)
        fd = os.open(self.root / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise AccessError('Другой запуск уже настраивает резерв.') from None
            yield

    def read(self, name):
        path = self.root / name
        if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077:
            raise AccessError('Нет корректного приватного файла резерва. Существующие данные не заменялись.')
        return path.read_text()

    def ensure_binary(self):
        asset = ASSETS.get(os.uname().machine)
        if os.uname().sysname != 'Linux' or asset is None:
            raise AccessError('OpenFlux резерв поддерживает Linux x86_64/aarch64.')
        arch, digest = asset
        directory(self.binary.parent)
        # The unprivileged service must traverse the directory to the public binary.
        self.binary.parent.chmod(0o755)
        if self.binary.parent.parent.name == 'govpn-openflux':
            self.binary.parent.parent.chmod(0o755)
        def valid(path):
            return path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == digest
        if not valid(self.binary):
            print('[1/4] Загрузка OpenFlux ' + VERSION + ' и проверка SHA256 (до 60 с)...', flush=True)
            with tempfile.TemporaryDirectory(dir=self.binary.parent) as tmp:
                path = Path(tmp) / 'download'
                download(f'https://github.com/p1neappleXpress/OpenFlux/releases/download/{VERSION}/openflux-linux-{arch}', path, 100*1024*1024)
                if not valid(path):
                    raise AccessError('SHA256 OpenFlux не совпал. Код не запускался.')
                atomic(self.binary, path.read_bytes(), 0o755)
        return self.binary

    def preflight(self):
        output = command(['systemctl', '--version']).decode(errors='replace')
        match = re.search(r'^systemd (\d+)', output)
        if not match or int(match[1]) < 247:
            raise AccessError('Для изоляции резерва нужен systemd 247+ с LoadCredential. Ничего не устанавливалось.')
        # Verify this is a live systemd host before downloading or generating keys.
        command(['systemctl', 'show', '--property=Version', '--value'])
        self.ensure_binary()

    def state(self):
        data = json.loads(self.read('state.json'))
        document_url(data['url'])
        if not isinstance(data['secret'], str) or not re.fullmatch('[a-f0-9]{64}', data['secret']):
            raise AccessError('Недопустимое сохраненное состояние резерва.')
        if not isinstance(data['link'], str) or not re.fullmatch(r'openflux://v1/[A-Za-z0-9_\-+/=]+', data['link']) or len(data['link']) > 65536:
            raise AccessError('Недопустимая сохраненная ссылка.')
        return data

    def existing(self):
        if os.path.lexists(self.root / 'state.json'):
            self.state()
            return True
        if any(os.path.lexists(self.root / name) for name in ('exit.conf','secret.key','client.json','client.link')):
            raise AccessError('Найдены данные без целого состояния. Автоматическая смена ключа запрещена; данные не удалялись.')
        return False

    def verify_unit(self):
        if os.path.lexists(self.unit) and (self.unit.is_symlink() or not self.unit.is_file() or self.unit.read_text() != service_unit(self.binary, self.root)):
            raise AccessError('Имя systemd unit занято другой конфигурацией. Она не заменялась.')

    def configure(self, url=None):
        with self.lock():
            self.verify_unit()
            existing = self.existing()
            if not existing and url is None:
                print('Создайте отдельный документ Яндекс с доступом по ссылке. Не используйте личные документы.')
                print('HTTPS ссылка на документ (Enter - отмена): ', end='', flush=True)
                with open('/dev/tty') as tty:
                    url = tty.readline().strip()
                if not url:
                    return False
            if not existing:
                url = document_url(url)
            self.preflight()
            if not existing:
                print('[2/4] Создание отдельного ключа и профиля клиента...', flush=True)
                secret = secrets.token_hex(32)
                share = {'name':'GoVPN reserve', 'negotiate':True, 'codec':'batched',
                         'secret':secret, 'context':url, 'transports':[{'type':'yandex','url':url}]}
                # Use upstream's parser/encoder, never reproduce the share format.
                output = command([str(self.binary), '--make-link', '-'], data=json.dumps(share).encode())
                result = json.loads(output)
                link = result.get('link', '')
                if not isinstance(link, str) or not re.fullmatch(r'openflux://v1/[A-Za-z0-9_\-+/=]+', link) or len(link)>65536:
                    raise AccessError('OpenFlux не создал допустимую ссылку. Сервис не устанавливался.')
                atomic(self.root / 'state.json', json.dumps({'url':url,'secret':secret,'link':link})+'\n')
            state = self.state()
            # One atomic state is authoritative. A crash while materializing
            # credentials resumes with the SAME key and link.
            atomic(self.root / 'secret.key', state['secret']+'\n')
            atomic(self.root / 'exit.conf', node_config(state['url']))
            if self.unit.exists():
                if self.unit.is_symlink() or self.unit.read_text() != service_unit(self.binary, self.root):
                    raise AccessError('Имя systemd unit занято другой конфигурацией. Она не заменялась.')
            print('[3/4] Установка отдельного сервиса L4 без изменения AWG/портов...', flush=True)
            atomic(self.unit, service_unit(self.binary, self.root), 0o644)
            command(['systemctl', 'daemon-reload'])
            try:
                command(['systemctl', 'reset-failed', SERVICE])
                command(['systemctl', 'enable', '--now', SERVICE], timeout=30)
                command(['systemctl', 'is-active', '--quiet', SERVICE])
            except AccessError:
                with contextlib.suppress(AccessError):
                    command(['systemctl', 'stop', SERVICE])
                raise AccessError('Сервис не запущен. Данные сохранены для повторного включения; AWG не изменен.') from None
            print('[4/4] Процесс запущен. Канал и доступность с телефона еще нужно проверить.')
            print('Один активный клиент; нужен OpenFluxAndroid/OpenFluxDesktop. Возможны captcha и ограничения внешнего сервиса.')
            print('Ссылка доступна отдельным действием меню. Она содержит секрет - не публикуйте ее.')
            return True

    def stop(self):
        with self.lock():
            self.verify_unit()
            if not self.existing():
                print('Резерв еще не настроен.')
                return
            if self.unit.is_symlink() or not self.unit.is_file() or self.unit.read_text() != service_unit(self.binary, self.root):
                raise AccessError('Сервис не принадлежит этой конфигурации GoVPN; остановка не выполнялась.')
            command(['systemctl', 'disable', '--now', SERVICE], timeout=30)
            print('Резерв отключен. Повторное включение использует прежний ключ и документ.')

    def detach(self):
        with self.lock():
            if not os.path.lexists(self.unit):
                return
            if self.unit.is_symlink() or self.unit.read_text() != service_unit(self.binary, self.root):
                raise AccessError('Unit резерва изменен извне; автоматическое удаление запрещено.')
            command(['systemctl', 'disable', '--now', SERVICE], timeout=30)
            self.unit.unlink()
            command(['systemctl', 'daemon-reload'])
            print('Сервис резерва удален; приватные данные пока сохранены.')

    def status(self):
        if not self.root.exists():
            print('OpenFlux резерв не настроен.')
            return
        if not self.existing():
            print('OpenFlux резерв не настроен.')
            return
        try:
            command(['systemctl', 'is-active', '--quiet', SERVICE])
            print('Сервис OpenFlux активен. Это не подтверждение связи с устройством или обхода белого списка.')
        except AccessError:
            print('Настройка сохранена; процесс не активен или systemd недоступен.')

    def show_link(self):
        if not sys.stdout.isatty():
            raise AccessError('Ссылка с секретом выводится только явно в терминал.')
        if not self.existing():
            raise AccessError('Сначала настройте резерв.')
        print('Секретная ссылка для приложения OpenFlux (не отправляйте ее в чат/логи):')
        print(self.state()['link'])


def country_networks(payload, country, server):
    if payload.get('status') != 'ok':
        raise AccessError('RIPE не подтвердил успешный ответ.')
    # Current RIPE 0.2 responses omit resource, although the API docs list it.
    # The caller binds country to a fixed HTTPS URL; validate an echo if present.
    echoed = payload['data'].get('resource')
    if echoed is not None and (not isinstance(echoed, str) or echoed.upper() != country):
        raise AccessError('Ответ RIPE относится к другой стране.')
    values = payload['data']['resources']['ipv4']
    if not isinstance(values, list) or not 1 <= len(values) <= 30000:
        raise AccessError('Недопустимый размер списка страны.')
    server = ipaddress.IPv4Address(server)
    result = []
    for value in values:
        if not isinstance(value, str) or '/' not in value:
            raise AccessError('RIPE вернул неверный IPv4 CIDR.')
        net = ipaddress.ip_network(value, strict=True)
        if net.version != 4 or net.prefixlen < 8 or not net.network_address.is_global or not net.broadcast_address.is_global:
            raise AccessError('Список содержит слишком широкую или непубличную сеть.')
        result.extend(net.address_exclude(ipaddress.ip_network(str(server)+'/32')) if server in net else (net,))
    return sorted(ipaddress.collapse_addresses(result), key=lambda n:(int(n.network_address), n.prefixlen))


def country_export(country, server, root=ROUTING):
    if not re.fullmatch('[A-Z]{2}', country):
        raise AccessError('Нужен двухбуквенный код страны, например RU.')
    ipaddress.IPv4Address(server)
    directory(root)
    fd = os.open(root / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            data = Path(tmp) / 'ripe.json'
            print('Загружаю IPv4 сети страны из RIPEstat (до 60 с)...', flush=True)
            download(f'https://stat.ripe.net/data/country-resource-list/data.json?resource={country}&v4_format=prefix', data, 8*1024*1024)
            networks = country_networks(json.loads(data.read_bytes()), country, server)
        if not networks:
            raise AccessError('Пустой список не экспортируется.')
        output = [{'hostname':str(n), 'ips':[str(n)], 'ip':str(n)} for n in networks]
        path = root / (country+'-direct.json')
        atomic(path, json.dumps(output, ensure_ascii=False, indent=2)+'\n')
        print(f'Готово: {path}\nСетей: {len(networks)}. Адрес этого VPS исключен. VPN и маршруты не изменены.')
        print('Скачайте файл на устройство, импортируйте в Amnezia в список адресов БЕЗ VPN и включите раздельное туннелирование.')
        print('Это зарегистрированные сети страны, не все домены .ru/.рф и не гарантия геолокации. IPv6 в список не включен.')
        if len(networks)>8000:
            print('Большой список: импорт и применение на устройстве могут занимать время.')
        return path


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='GoVPN: клиентские маршруты и отдельный резерв')
    sub = parser.add_subparsers(dest='action', required=True)
    for name in ('status','configure','stop','link','detach'):
        sub.add_parser(name)
    country = sub.add_parser('country')
    country.add_argument('--country', default='RU')
    country.add_argument('--server', required=True)
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        raise AccessError('Требуется root.')
    if args.action == 'country':
        country_export(args.country.upper(), args.server)
        return
    ctl = Reserve()
    {'status':ctl.status, 'configure':ctl.configure, 'stop':ctl.stop, 'link':ctl.show_link, 'detach':ctl.detach}[args.action]()


def entry():
    try:
        main()
    except (AccessError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Ошибка: '+str(error) if isinstance(error, AccessError) else 'Операция не завершена. Секреты и сырой вывод скрыты; проверьте сохраненное состояние.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(entry())
