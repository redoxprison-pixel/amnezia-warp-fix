#!/bin/bash
# WARP MANAGER v6.5 — Final Stable Edition for Aeza

# --- Настройки ---
PORT=40000
TUN_DEV="tun0"
TABLE_ID=100
MARK_ID=51820
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

# Функция "лечения" демона WARP
fix_warp_daemon() {
    if ! warp-cli --accept-tos status > /dev/null 2>&1; then
        echo -e "${YELLOW}Исправление демона WARP (IPC Timeout)...${NC}"
        systemctl stop warp-svc 2>/dev/null
        rm -f /run/cloudflare-warp/warp_service_ipc
        systemctl start warp-svc
        sleep 3
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port $PORT
        warp-cli --accept-tos connect
    fi
}

draw_logo() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}WARP MANAGER v6.5 — Final Stable Edition${NC}"
    echo -e "  ${CYAN}Статус защиты SSH: Активна${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
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
    # 1. Сначала чиним демон, если он упал
    fix_warp_daemon

    echo -e "${YELLOW}Очистка ресурсов...${NC}"
    down_tun > /dev/null 2>&1
    sleep 1

    # 2. Получаем данные сети Aeza
    GW=$(ip route show default | awk '/default/ {print $3}')
    DEV=$(ip route show default | awk '/default/ {print $5}')

    # 3. Маршрут, чтобы сам WARP не зациклился через себя
    ip route add 162.159.0.0/16 via $GW dev $DEV table main 2>/dev/null

    # 4. Защита SSH (порт 22)
    iptables -t mangle -F
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -j MARK --set-mark $MARK_ID

    # 5. Поднятие tun0
    ip tuntap add dev $TUN_DEV mode tun
    ip addr add 10.0.0.1/24 dev $TUN_DEV
    ip link set $TUN_DEV up

    # 6. Запуск Tun2Socks (направляем DNS на 8.8.8.8 напрямую мимо туннеля для стабильности)
    nohup tun2socks -proxy socks5://127.0.0.1:$PORT -interface $TUN_DEV -dns 8.8.8.8 > /tmp/tun2socks.log 2>&1 &
    sleep 3

    # 7. Финальная маршрутизация
    ip route add default dev $TUN_DEV table $TABLE_ID
    ip rule add fwmark $MARK_ID lookup $TABLE_ID
    
    # Чтобы прокси был доступен локально
    ip route add 127.0.0.1 dev lo table $TABLE_ID 2>/dev/null

    echo -e "${GREEN}Туннель запущен!${NC}"
    sleep 2
}

down_tun() {
    echo -e "${YELLOW}Сброс системы...${NC}"
    killall tun2socks > /dev/null 2>&1
    ip rule del fwmark $MARK_ID lookup $TABLE_ID > /dev/null 2>&1
    ip route flush table $TABLE_ID > /dev/null 2>&1
    ip link delete $TUN_DEV > /dev/null 2>&1
    iptables -t mangle -F
    # Удаляем маршрут WARP, чтобы вернуть как было
    GW=$(ip route show default | awk '/default/ {print $3}')
    DEV=$(ip route show default | awk '/default/ {print $5}')
    ip route del 162.159.0.0/16 via $GW dev $DEV 2>/dev/null
    echo -e "${GREEN}Готово.${NC}"
    sleep 1
}

while true; do
    draw_logo
    check_status
    echo -e "  Статус: $TUN_STATUS"
    echo -e "  IP через WARP: ${GREEN}$T_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}1)${NC} ${GREEN}ПОДНЯТЬ ТУННЕЛЬ${NC}"
    echo -e "  ${WHITE}2)${NC} ${RED}ОТКЛЮЧИТЬ ТУННЕЛЬ${NC}"
    echo -e "  ${WHITE}3)${NC} Статус WARP-CLI (Проверка демона)"
    echo -e "  ${WHITE}4)${NC} Логи (Почему ошибка)"
    echo -e "  ${WHITE}5)${NC} ${YELLOW}ОБНОВИТЬ СКРИПТЫ${NC}"
    echo -e "  ${WHITE}0)${NC} Выход"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    read -p " Выберите действие: " choice

    case $choice in
        1) up_tun ;;
        2) down_tun ;;
        3) fix_warp_daemon; warp-cli --accept-tos status; read -p "Enter..." ;;
        4) echo -e "${YELLOW}Логи Tun2Socks:${NC}"; tail -n 20 /tmp/tun2socks.log; echo -e "\n${YELLOW}Статус службы WARP:${NC}"; systemctl status warp-svc --no-pager; read -p "Enter..." ;;
        5) curl -sL "$GITHUB_RAW/menu.sh" -o /usr/local/bin/warp && chmod +x /usr/local/bin/warp
           curl -sL "$GITHUB_RAW/setup.sh" -o /usr/local/bin/warp-setup && chmod +x /usr/local
