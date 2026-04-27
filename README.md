# GoVPN Manager v5.18

Управление VPN-серверами: AmneziaWG, 3X-UI, WARP, MTProto, iptables-проброс.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main/govpn.sh \
  -o /usr/local/bin/govpn && chmod +x /usr/local/bin/govpn && govpn
```

## CLI-команды

```bash
govpn                  # интерактивное меню
govpn version          # текущая версия
govpn update           # обновить скрипт
govpn update --force   # переустановить принудительно
govpn check-update     # проверить версию в репо
govpn backup           # создать полный бэкап
govpn rollback <файл>  # восстановить x-ui.db или config.json из файла
```

## Что умеет

- **Автодетект режима** — amnezia / 3xui / combo / bridge при каждом запуске
- **WARP** — установка, настройка, тест; per-client маршрутизация для AWG
- **AWG клиенты** — добавить, удалить, QR-код, список с handshake-статусом
- **MTProto прокси** — запуск mtg-контейнеров с FakeTLS
- **iptables проброс** — каскад через rxpn bridge
- **Reality SNI Scanner** — поиск рабочих SNI для VLESS/XTLS
- **Бэкапы** — полный архив (AWG + x-ui.db + WARP-ключи + скрипт), автобэкап перед изменениями клиентов, rollback по компонентам
- **Автообновление** — фоновая проверка версии, уведомление в шапке меню
- **Мониторинг в шапке** — CPU, RAM, диск, AWG peers и трафик
- **Мультисервер** — цепочка серверов с алиасами и отображением маршрута
