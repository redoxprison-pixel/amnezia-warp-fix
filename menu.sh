#!/bin/bash
# WARP MANAGER v6.7 — Final Fix

# --- Настройки ---
PORT=40000
TUN_DEV="tun0"
TABLE_ID=100
MARK_ID=51820
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

# Проверка и ремонт демона
fix_daemon() {
    if ! warp-cli --accept-tos status > /dev/null 2>&1; then
        echo -e "${YELLOW}Чиним зависший WARP...${NC}"
        systemctl stop warp-svc 2>/dev/null
        rm -f /run/cloudflare-warp/warp_service_ipc
        systemctl start warp-svc
        sleep 2
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos connect
    fi
}

check_status() {
    if pgrep -x "tun2socks" > /dev/null; then
        TUN_STATUS="${GREEN}● ТУННЕЛЬ ПОДНЯТ${NC}"
        T_IP=$(curl -s4 --interface $TUN_DEV --max-time 3 eth0.me || echo "Ошибка")
    else
        TUN_STATUS="${RED}○ ТУННЕЛЬ ВЫКЛЮЧЕН${NC}"
        T_IP="N/A"
    fi
}

up_tun() {
    fix_daemon
    killall tun2socks >/dev/null 2>&1
    ip link delete $TUN_DEV >/dev/null 2>&1
    
    GW=$(ip route show default | awk '/default/ {print $3}')
    DEV=$(ip route show default | awk '/default/ {print $5}')
    ip route add 162.159.0.0/16 via $GW dev $DEV 2>/dev/null

    iptables -t mangle -F
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -j MARK --set-mark $MARK_ID

    ip tuntap add dev $TUN_DEV mode tun
    ip addr add 10.0.0.1/24 dev $TUN_DEV
    ip link set $TUN_DEV up

    nohup tun2socks -proxy socks5://127.0.0.1:$PORT -interface $TUN_DEV -dns 8.8.8.8 > /tmp/tun2socks.log 2>&1 &
    sleep 3

    ip route add default dev $TUN_DEV table $TABLE_ID
    ip rule add fwmark $MARK_ID lookup $TABLE_ID
    ip route add 127.0.0.1 dev lo table $TABLE_ID 2>/dev/null
    echo -e "${GREEN}Туннель запущен!${NC}"
    sleep 2
}

down_tun() {
    killall tun2socks > /dev/null 2>&1
    ip rule del fwmark $MARK_ID lookup $TABLE_ID > /dev/null 2>&1
    ip route flush table $TABLE_ID > /dev/null 2>&1
    ip link delete $TUN_DEV > /dev/null 2>&1
    iptables -t mangle -F
    echo -e "${GREEN}Очищено.${NC}"
    sleep 1
}

while true; do
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}WARP MANAGER v6.7 — Stable Edition${NC}"
    check_status
    echo -e "  Статус: $TUN_STATUS"
    echo -e "  IP через WARP: ${GREEN}$T_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  1) ПОДНЯТЬ ТУННЕЛЬ"
    echo -e "  2) ОТКЛЮЧИТЬ ТУННЕЛЬ"
    echo -e "  3) Логи и статус"
    echo -e "  4) ОБНОВИТЬ СКРИПТЫ"
    echo -e "  0) Выход"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    read -p " Выбор: " choice

    case $choice in
        1) up_tun ;;
        2) down_tun ;;
        3) warp-cli --accept-tos status; tail -n 10 /tmp/tun2socks.log; read -p "Enter..." ;;
        4) 
            curl -sL "$GITHUB_RAW/menu.sh" -o /usr/local/bin/warp && chmod +x /usr/local/bin/warp
            curl -sL "$GITHUB_RAW/setup.sh" -o /usr/local/bin/warp-setup && chmod +x /usr/local/bin/warp-setup
            echo "Обновлено!"; exit 0 ;;
        0) exit 0 ;;
        *) echo "Ошибка!"; sleep 1 ;;
    esac
done
