#!/bin/bash

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

PORT=40000
TUN_DEV="tun0"
TABLE_ID=100
MARK_ID=51820

draw_logo() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}WARP MANAGER v6.0 — Official Engine + Tun2Socks${NC}"
    echo -e "  ${CYAN}Защита SSH: Активна (FWMARK)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

check_status() {
    if pgrep -x "tun2socks" > /dev/null; then
        TUN_STATUS="${GREEN}● ТУННЕЛЬ ПОДНЯТ${NC}"
    else
        TUN_STATUS="${RED}○ ТУННЕЛЬ ВЫКЛЮЧЕН${NC}"
    fi
    
    # Проверка IP через туннель
    T_IP=$(curl -s4 --interface $TUN_DEV --max-time 2 eth0.me || echo "N/A")
}

up_tun() {
    echo -e "${YELLOW}Очистка старых ресурсов...${NC}"
    down_tun > /dev/null 2>&1
    sleep 1

    echo -e "${YELLOW}Настройка правил исключения SSH...${NC}"
    # 1. Помечаем весь трафик меткой 1
    # 2. Но трафик SSH (порт 22) оставляем без метки (или помечаем иначе)
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j ACCEPT
    iptables -t mangle -A OUTPUT -j MARK --set-mark $MARK_ID

    echo -e "${YELLOW}Запуск интерфейса $TUN_DEV...${NC}"
    ip tuntap add dev $TUN_DEV mode tun
    ip addr add 10.0.0.1/24 dev $TUN_DEV
    ip link set $TUN_DEV up

    # Запуск Tun2Socks
    nohup tun2socks -proxy socks5://127.0.0.1:$PORT -interface $TUN_DEV > /dev/null 2>&1 &
    sleep 2

    echo -e "${YELLOW}Настройка маршрутизации (Таблица $TABLE_ID)...${NC}"
    ip route add default dev $TUN_DEV table $TABLE_ID
    # Направляем в таблицу 100 только помеченный трафик
    ip rule add fwmark $MARK_ID lookup $TABLE_ID
    
    # Чтобы сам сервер (local process) тоже ходил в туннель
    ip route add default dev $TUN_DEV table $TABLE_ID
    
    echo -e "${GREEN}Готово! Проверь доступ.${NC}"
    sleep 2
}

down_tun() {
    echo -e "${YELLOW}Сброс всех настроек...${NC}"
    killall tun2socks > /dev/null 2>&1
    ip rule del fwmark $MARK_ID lookup $TABLE_ID > /dev/null 2>&1
    ip route flush table $TABLE_ID > /dev/null 2>&1
    ip link delete $TUN_DEV > /dev/null 2>&1
    iptables -t mangle -F
    echo -e "${GREEN}Система очищена.${NC}"
    sleep 2
}

while true; do
    draw_logo
    check_status
    echo -e "  Статус: $TUN_STATUS"
    echo -e "  IP в туннеле: ${GREEN}$T_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  1) ${GREEN}ПОДНЯТЬ ТУННЕЛЬ${NC} (Весь трафик в WARP)"
    echo -e "  2) ${RED}ОТКЛЮЧИТЬ ТУННЕЛЬ${NC} (Вернуть как было)"
    echo -e "  3) Логи Tun2Socks"
    echo -e "  4) Обновить скрипт с GitHub"
    echo -e "  0) Выход"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    read -p " Выберите действие: " choice

    case $choice in
        1) up_tun ;;
        2) down_tun ;;
        3) journalctl -xe | grep tun2socks | tail -n 20; read -p "Enter..." ;;
        4) 
            echo "Обновление..."
            curl -sL https://raw.githubusercontent.com/ТВОЙ_ЛОГИН/ТВОЙ_РЕПО/main/menu.sh -o /usr/local/bin/warp
            chmod +x /usr/local/bin/warp
            echo "Обновлено! Перезапусти команду warp."
            exit 0 ;;
        0) exit 0 ;;
    esac
done
