# GoVPN Manager

Менеджер VPN серверов: WARP, iptables каскад, 3x-ui/x-ui-pro, wgcf, AmneziaWG.

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main/govpn.sh)
```

После первого запуска выйди через `0` — команда `govpn` станет доступна глобально. 

## Возможности

- **WARP** — установка, авторемонт, тест прохождения трафика через Cloudflare
- **iptables каскад** — проброс трафика между серверами (AWG, VLESS, MTProto, кастом)
- **3x-ui / x-ui-pro** — применение WARP outbound через БД (не слетает при рестарте)
- **wgcf** — WireGuard профиль Cloudflare (работает с RU серверов)
- **Серверы и скорость** — статус, пинг, тест скорости, тест цепочки, проверка сайтов
- **Мониторинг** — автоматическая проверка доступности серверов

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- root доступ

## Rollback xray config

```bash
govpn rollback /etc/govpn/backups/config.json.bak.<timestamp>
```
