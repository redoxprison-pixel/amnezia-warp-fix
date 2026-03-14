#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
VERSION="3.8"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    pgrep -f "warp-plus" >/dev/null && W_STAT="${GREEN}● RUNNING (GOOL)${NC}" || W_STAT="${RED}● STOPPED${NC}"
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo -e "${RED}ВЫКЛ${NC}")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Gool Engine Mode"
    echo -e " Main IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP IP: $W_IP"
    echo -e " Status:  $W_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

routing_down() {
    echo -e "${YELLOW}Остановка всех процессов...${NC}"
    systemctl stop warp-plus >/dev/null 2>&1
    killall warp-plus >/dev/null 2>&1
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 101 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    iptables -t nat -F
    ip link delete $TUN_DEV >/dev/null 2>&1
}

routing_up() {
    routing_down
    echo -e "${YELLOW}Запуск Gool Engine...${NC}"
    
    # Запуск через systemd
    systemctl start warp-plus
    sleep 5
    
    # Проверка работы SOCKS5 (Gool сам создает прокси)
    echo -e "${BLUE}Тестирую пробивку через Gool...${NC}"
    if curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 10 google.com > /dev/null; then
        echo -e "${GREEN}✓ ПРОБИТО! Gool работает.${NC}"
        
        # Если нужен именно TUN (прозрачный прокси для всего сервера)
        # Раскомментируй строки ниже, если хочешь завернуть ВЕСЬ трафик
        # Но для начала убедись, что SOCKS5 работает (IP в шапке станет зеленым)
    else
        echo -e "${RED}✗ ДАЖЕ GOOL НЕ ПРОБИЛСЯ. Проверь логи (п.6)${NC}"
        routing_down
        read -p "Enter..."
    fi
}

full_install() {
    routing_down
    echo -e "${BLUE}Установка Gool Engine (Warp-Plus)...${NC}"
    apt update && apt install -y wget curl
    
    # Скачиваем warp-plus (Gool)
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        wget -qO warp-plus https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-amd64
    else
        wget -qO warp-plus https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-arm64
    fi
    chmod +x warp-plus
    mv warp-plus /usr/local/bin/
    
    # Создаем сервис
    cat <<EOF > /etc/systemd/system/warp-plus.service
[Unit]
Description=Warp-Plus Gool Service
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-plus --socks-addr 127.0.0.1:$WARP_PORT --gool
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-plus
    echo -e "${GREEN}Установка завершена!${NC}"
    sleep 2
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) Установить Gool Engine (Warp-Plus)"
    echo -e " 2) ЗАПУСТИТЬ WARP"
    echo -e " 3) ОСТАНОВИТЬ"
    echo -e " 6) Показать логи Gool"
    echo -e " 13) СБРОСИТЬ ВСЁ"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        6) journalctl -u warp-plus -n 50 --no-pager; read -p "Enter..." ;;
        13) routing_down; rm -f /usr/local/bin/warp-plus /etc/systemd/system/warp-plus.service; echo "Стерто."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
