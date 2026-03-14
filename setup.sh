#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Конфигурация
VERSION="2.9"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ШАПКА ---
get_header() {
    clear
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● OK${NC}" || W_STAT="${RED}● OFF${NC}"
    
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    DNS_CUR=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION"
    echo -e " Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | IP: ${GREEN}$W_IP${NC}"
    echo -e " DNS:    ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ФУНКЦИИ ---
routing_down() {
    echo -e "${YELLOW}Остановка и очистка маршрутов...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    iptables -t nat -F POSTROUTING 2>/dev/null
    ip route flush table 100 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Сеть восстановлена.${NC}"
    sleep 1
}

full_install() {
    echo -e "${BLUE}Установка всех компонентов (tun2socks, wgcf, service)...${NC}"
    apt update && apt install -y wget unzip curl python3-pip
    
    # tun2socks
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod 755 /usr/local/bin/tun2socks && rm t2s.zip
    
    # wgcf
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod 755 /usr/local/bin/wgcf
    
    # Регистрация
    mkdir -p /etc/WarpGo && cd /etc/WarpGo
    /usr/local/bin/wgcf register --accept-tos
    /usr/local/bin/wgcf generate
    
    # Service
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
    systemctl daemon-reload
    systemctl enable tun2socks >/dev/null 2>&1
    echo -e "${GREEN}Готово!${NC}"
    sleep 2
}

routing_up() {
    routing_down
    echo -e "${YELLOW}Запуск туннеля...${NC}"
    systemctl start tun2socks
    sleep 3
    
    ip link set dev "$TUN_DEV" mtu 1280
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table 100
    ip route add default dev "$TUN_DEV" table 100
    
    # SSH Protection & Global Redirect
    MY_IP=$(curl -s eth0.me)
    ip rule add to $MY_IP priority 100 table main
    ip rule add from all priority 500 table 100
    
    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE
    echo -e "${GREEN}✓ WARP активен.${NC}"
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
    echo -e "  4) Компоненты (Ручное обновление)"
    echo -e "  5) Обновить ключи CloudFlare"
    echo -e "  6) Показать логи (journalctl)"
    echo -e "  7) Прокси для Telegram (SOCKS5 33854)"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ И DNS:${NC}"
    echo -e "  8) Тест скорости (Speedtest)"
    echo -e "  9) Управление DNS"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 13) ${RED}ПОЛНОЕ УДАЛЕНИЕ И СБРОС${NC}"
    echo ""
    echo -e "  0) Выход"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        4) # Просто быстрая переустановка tun2socks
           install_comp "t"; sleep 1 ;;
        5) cd /etc/WarpGo && rm -f wgcf* && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate ;;
        6) journalctl -u tun2socks -n 50 --no-pager && read -p "Enter..." ;;
        7) echo -e "IP: $S_IP | Port: 33854 (Amnezia)"; read -p "Enter..." ;;
        8) clear; apt install -y speedtest-cli >/dev/null 2>&1; speedtest-cli --simple; read -p "Enter..." ;;
        9) echo "nameserver 1.1.1.1" > /etc/resolv.conf; echo "DNS установлен на Cloudflare"; sleep 1 ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Система очищена."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
