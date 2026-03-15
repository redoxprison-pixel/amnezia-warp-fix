#!/bin/bash
# WARP MANAGER v6.1 PRO — Amnezia Edition

# --- Настройки ---
PORT=40000
TUN_DEV="tun0"
TABLE_ID=100
MARK_ID=51820
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

draw_logo() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}WARP MANAGER v6.1 PRO — Amnezia Edition${NC}"
    echo -e "  ${CYAN}Защита SSH: Активна (FWMARK + IPTABLES)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

check_status() {
    if pgrep -x "tun2socks" > /dev/null; then
        TUN_STATUS="${GREEN}● ТУННЕЛЬ ПОДНЯТ${NC}"
        # Проверка IP именно через туннель
        T_IP=$(curl -s4 --interface $TUN_DEV --max-time 2 eth0.me || echo "Ошибка")
    else
        TUN_STATUS="${RED}○ ТУННЕЛЬ ВЫКЛЮЧЕН${NC}"
        T_IP="N/A"
    fi
}

up_tun() {
    echo -e "${YELLOW}Очистка старых ресурсов...${NC}"
    down_tun > /dev/null 2>&1
    sleep 1

    echo -e "${YELLOW}Защита SSH (порт 22)...${NC}"
    iptables -t mangle -F
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -j MARK --set-mark $MARK_ID

    echo -e "${YELLOW}Поднятие интерфейса $TUN_DEV...${NC}"
    ip tuntap add dev $TUN_DEV mode tun
    ip addr add 10.0.0.1/24 dev $TUN_DEV
    ip link set $TUN_DEV up

    echo -e "${YELLOW}Запуск Tun2Socks (DNS 8.8.8.8)...${NC}"
    nohup tun2socks -proxy socks5://127.0.0.1:$PORT -interface $TUN_DEV -dns 8.8.8.8 > /tmp/tun2socks.log 2>&1 &
    sleep 3

    echo -e "${YELLOW}Применение маршрутов...${NC}"
    ip route add default dev $TUN_DEV table $TABLE_ID
    ip rule add fwmark $MARK_ID lookup $TABLE_ID
    
    # Добавляем локальную петлю, чтобы не было зацикливания
    ip route add 127.0.0.1 dev lo table $TABLE_ID 2>/dev/null

    echo -e "${GREEN}Готово! Система переведена на WARP.${NC}"
    sleep 2
}

down_tun() {
    echo -e "${YELLOW}Отключение туннеля и сброс правил...${NC}"
    killall tun2socks > /dev/null 2>&1
    ip rule del fwmark $MARK_ID lookup $TABLE_ID > /dev/null 2>&1
    ip route flush table $TABLE_ID > /dev/null 2>&1
    ip link delete $TUN_DEV > /dev/null 2>&1
    iptables -t mangle -F
    echo -e "${GREEN}Система очищена.${NC}"
    sleep 1
}

update_scripts() {
    echo -e "${YELLOW}Обновление всех скриптов с GitHub...${NC}"
    if curl -sL "$GITHUB_RAW/menu.sh" -o /usr/local/bin/warp && \
       curl -sL "$GITHUB_RAW/setup.sh" -o /usr/local/bin/warp-setup; then
        chmod +x /usr/local/bin/warp /usr/local/bin/warp-setup
        echo -e "${GREEN}Успешно! Перезапустите команду 'warp'.${NC}"
        exit 0
    else
        echo -e "${RED}Ошибка обновления. Проверьте соединение.${NC}"
        read
    fi
}

while true; do
    draw_logo
    check_status
    echo -e "  Статус: $TUN_STATUS"
    echo -e "  IP через WARP: ${GREEN}$T_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}1)${NC} ${GREEN}ПОДНЯТЬ ТУННЕЛЬ${NC} (Весь трафик сервера в WARP)"
    echo -e "  ${WHITE}2)${NC} ${RED}ОТКЛЮЧИТЬ ТУННЕЛЬ${NC}"
    echo -e "  ${WHITE}3)${NC} Проверить статус WARP-CLI"
    echo -e "  ${WHITE}4)${NC} Логи Tun2Socks"
    echo -e "  ${WHITE}5)${NC} ${YELLOW}ОБНОВИТЬ СКРИПТЫ С GITHUB${NC}"
    echo -e "  ${WHITE}0)${NC} Выход"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    read -p " Выберите действие: " choice

    case $choice in
        1) up_tun ;;
        2) down_tun ;;
        3) warp-cli status; read -p "Enter..." ;;
        4) tail -n 20 /tmp/tun2socks.log; read -p "Enter..." ;;
        5) update_scripts ;;
        0) exit 0 ;;
    esac
done
