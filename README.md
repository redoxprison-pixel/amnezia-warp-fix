# GoVPN Manager v3.4

Менеджер VPN серверов для связки **RU bridge → AMS exit → Cloudflare**.

Управляет: WARP, iptables каскад, 3x-ui/x-ui-pro, wgcf, AmneziaWG.

---

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main/govpn.sh)
```

После первого запуска — выйди через `0`. Команда `govpn` станет доступна глобально.

---

## Архитектура

```
Клиент (РФ)
    ↓  VLESS + Reality / AmneziaWG
RU bridge  155.212.247.249  (Россия)
    ↓  iptables DNAT / xHTTP bridge
AMS exit   85.192.26.32    (Amsterdam)
    ↓  xray outbound → WARP SOCKS5
Cloudflare  104.28.197.7
    ↓
Интернет
```

---

## Меню

### IPTABLES ПРОБРОС

| # | Действие |
|---|---|
| 1 | AmneziaWG / WireGuard (UDP) |
| 2 | VLESS / XRay (TCP) |
| 3 | MTProto / TProxy (TCP) |
| 4 | Кастомное правило |
| 5 | Список правил |
| 6 | Удалить правило |
| 7 | Сбросить все |

### WARP

| # | Действие |
|---|---|
| 8 | Установить |
| 8r | Авторемонт |
| 8p | Чистая переустановка |
| 9 | Статус |
| 10 | Запустить |
| 11 | Остановить |
| 12 | Перевыпустить ключ |
| 13 | Изменить порт SOCKS5 |
| 14 | Удалить |
| **15** | **★ Тест WARP** (7 проверок + xray outbound) |

### 3X-UI / XRAY

| # | Действие |
|---|---|
| 16 | JSON для ручного добавления через панель |
| **17** | **Применить WARP в xray** (патч xrayTemplateConfig в БД) |
| 18 | Бэкапы и Rollback |

> п.17 патчит `xrayTemplateConfig` в `/etc/x-ui/x-ui.db` — outbound сохраняется навсегда.

### ИНСТРУМЕНТЫ

| # | Действие |
|---|---|
| **18** | **Серверы, скорость, мониторинг** |
| 19 | Статистика, бэкапы, управление сервером |

**П.18 — что показывает:**
```
  [1] ● AMS  85.192.26.32 ←  12ms
  [2] ● RU-bridge  155.212.247.249  38ms
      ● Cloudflare WARP  104.28.197.7

  3)  Тест скорости
  4)  Тест цепочки
  5)  Проверить сайт / IP
  6)  Автомониторинг
```
- Нажми номер → тест скорости или переименовать
- **Тест скорости** — 10 пингов (ICMP/TCP fallback) + скорость Cloudflare + скорость через WARP
- **Тест цепочки** — задержка на каждом уровне
- **Проверить сайт** — DNS, GeoIP, пинг, HTTP статус, проверка через WARP

### РОУТЕР / ДОПОЛНИТЕЛЬНО

| # | Действие |
|---|---|
| 20 | AmneziaWG на роутер *(только Amnezia)* |
| 21 | wgcf — WireGuard профиль CF |

### СИСТЕМА

| # | Действие |
|---|---|
| 22 | Проверка конфликтов |
| 23 | Обновить скрипт |
| 24 | Полное удаление |

---

## WARP

Официальный Cloudflare клиент в режиме SOCKS5 (`127.0.0.1:40000`).

**RU серверы:** Cloudflare API блокирует регистрацию с российских IP. Устанавливай WARP только на **AMS exit**. На RU bridge используй wgcf (п.21).

**Тест WARP (п.15)** — проверяет 7 компонентов включая xray outbound и routing rules.

---

## wgcf (п.21)

Альтернатива warp-cli через WireGuard. Работает с RU серверов.
Создаёт туннель `wgcf0`. Автоматически адаптируется под IPv4-only хосты.

> **Amnezia:** туннель поднимается, но маршрутизировать трафик контейнеров через него нельзя. Используй WARP SOCKS5.

---

## Совместимость

| | |
|---|---|
| 3x-ui / x-ui-pro | ✅ |
| Amnezia (Docker) | ✅ |
| Ubuntu 22.04 / 24.04 | ✅ |
| Debian 11 / 12 | ✅ |

---

## Файлы

```
/etc/govpn/config          # настройки
/etc/govpn/aliases         # имена серверов
/etc/govpn/backups/        # бэкапы xray config + x-ui.db
/etc/wireguard/wgcf0.conf  # WireGuard профиль CF
/var/log/govpn.log         # лог
/usr/local/bin/govpn       # команда
```

## Rollback

```bash
govpn rollback /etc/govpn/backups/config.json.bak.<timestamp>
```
