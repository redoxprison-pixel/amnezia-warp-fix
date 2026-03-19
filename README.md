## Установка
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main/govpn.sh)
```

После первого запуска скрипт устанавливается как команда:
```bash
govpn
```

### Rollback xray config вручную
```bash
govpn rollback /etc/govpn/backups/config.json.bak.<timestamp>
```

### Требования
- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- root доступ
- x-ui / 3x-ui / x-ui-pro (опционально, для интеграции с xray)
