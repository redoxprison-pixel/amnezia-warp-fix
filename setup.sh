#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="3.0"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Server IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP Status: $W_STAT | WARP IP: ${GREEN}$W_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ИСПРАВЛЕННЫЙ СБРОС (Пункт 13) ---
routing_down() {
    echo -e "${YELLOW}Принудительная очистка сети...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    
    # Удаляем правила по приоритетам
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    
    # Полная чистка NAT и таблиц
    iptables -t nat -F
    ip route flush table 100 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    
    # Сброс DNS
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Сеть полностью восстановлена.${NC}"
    sleep 1
}

# --- ИСПРАВЛЕННЫЙ ЗАПУСК (Пункт 2) ---
routing_up() {
    routing_down # Сначала чистим всё
    
    echo -e "${YELLOW}Запуск WARP...${NC}"
    systemctl start tun2socks
    sleep 3

    if ! pgrep -x "tun2socks" >/dev/null; then
        echo -e "${RED}Ошибка: tun2socks не запустился! Проверь пункт 6.${NC}"
        return
    fi

    # Настройка интерфейса
    ip link set dev "$TUN_DEV" mtu 1280
    ip addr add 192.168.100.1/24 dev "$TUN_DEV" 2>/dev/null
    ip link set dev "$TUN_DEV" up

    # Создаем таблицу маршрутизации
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default dev "$TUN_DEV" table warp

    # --- ПРАВИЛА ИСКЛЮЧЕНИЙ (Чтобы не потерять доступ) ---
    # 1. Оставляем SSH и локальный трафик в основной таблице
    MY_IP=$(curl -s eth0.me)
    ip rule add to $MY_IP priority 100 table main
    
    # 2. Исключаем трафик до самого Cloudflare (чтобы WARP не пытался идти через самого себя)
    # Это критически важно для коннекта!
    ip rule add to 162.159.0.0/16 priority 101 table main
    
    # 3. Всё остальное — в WARP
    ip rule add from all priority 500 table warp

    # NAT (Маскарад)
    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE
    
    echo -e "${GREEN}✓ Маршрутизация настроена.${NC}"
    sleep 2
}

# --- МЕНЮ (Восстановленное оформление) ---
while true; do
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) ПОЛНАЯ УСТАНОВКА (tun2 + wgcf + keys)"
    echo -e "  2) ЗАПУСТИТЬ ТУННЕЛЬ (UP)"
    echo -e "  3) ОСТАНОВИТЬ ТУННЕЛЬ (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  5) Обновить ключи CloudFlare"
    echo -e "  6) Показать логи ошибок (journalctl)"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ:${NC}"
    echo -e "  8) Тест скорости"
    echo -e "  9) Установить DNS Google"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 13) ${RED}КРИТИЧЕСКИЙ СБРОС И УДАЛЕНИЕ${NC}"
    echo ""
    echo -e "  0) Выход"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) # Упрощенная установка из v2.9
           apt update && apt install -y wget unzip curl
           V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
           wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
           unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod 755 /usr/local/bin/tun2socks; rm t2s.zip
           wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod 755 /usr/local/bin/wgcf
           mkdir -p /etc/WarpGo && cd /etc/WarpGo && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate
           # Создаем сервис заново
           cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks
After=network.target
[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
           systemctl daemon-reload && systemctl enable tun2socks
           echo "Установка завершена."; sleep 2 ;;
        2) routing_up ;;
        3) routing_down ;;
        5) cd /etc/WarpGo && rm -f wgcf* && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate ;;
        6) journalctl -u tun2socks -n 50 --no-pager && read -p "Enter..." ;;
        8) speedtest-cli --simple || echo "Не установлен"; read -p "Enter..." ;;
        9) echo "nameserver 8.8.8.8" > /etc/resolv.conf; sleep 1 ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Стерто."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
