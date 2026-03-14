#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="3.1"
WARP_PORT="40000"
TUN_DEV="tun0"
# Авто-определение интерфейса
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● OK${NC}" || W_STAT="${RED}● OFF${NC}"
    
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    DNS_CUR=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Interface: $MAIN_IFACE"
    echo -e " Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | IP: ${GREEN}$W_IP${NC}"
    echo -e " DNS:    ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПОЛНЫЙ СБРОС (Пункт 13) ---
routing_down() {
    echo -e "${YELLOW}Очистка сетевых правил и остановка сервисов...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 101 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    
    iptables -t nat -F
    ip route flush table 100 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Система очищена.${NC}"
    sleep 1
}

# --- ЗАПУСК (Пункт 2) ---
routing_up() {
    if [ ! -f /usr/local/bin/tun2socks ]; then
        echo -e "${RED}Файл tun2socks не найден! Нажми пункт 1.${NC}"; sleep 2; return
    fi
    
    routing_down
    chmod +x /usr/local/bin/tun2socks
    
    echo -e "${YELLOW}Запуск туннеля...${NC}"
    systemctl start tun2socks
    sleep 3

    if ! pgrep -x "tun2socks" >/dev/null; then
        echo -e "${RED}Критическая ошибка: tun2socks не смог запуститься!${NC}"
        echo -e "${YELLOW}Лог ошибки:${NC}"
        journalctl -u tun2socks -n 5 --no-pager
        read -p "Нажми Enter..."
        return
    fi

    # Настройка сети
    ip link set dev "$TUN_DEV" mtu 1280
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table 100
    ip route add default dev "$TUN_DEV" table 100

    # Правила (Исключаем SSH и запросы к самому Cloudflare)
    MY_IP=$(curl -s eth0.me)
    ip rule add to $MY_IP priority 100 table main
    ip rule add to 162.159.0.0/16 priority 101 table main
    ip rule add from all priority 500 table 100

    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE
    
    echo -e "${GREEN}✓ WARP запущен и маршруты настроены.${NC}"
    sleep 2
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить WARP (Все компоненты + Ключи)"
    echo -e "  2) Запустить WARP (UP)"
    echo -e "  3) Остановить WARP (DOWN)"
    
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
        1) # Установка
           apt update && apt install -y wget unzip curl
           V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
           wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
           unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod 755 /usr/local/bin/tun2socks; rm t2s.zip
           wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod 755 /usr/local/bin/wgcf
           mkdir -p /etc/WarpGo && cd /etc/WarpGo && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate
           
           cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks for WarpGo
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
