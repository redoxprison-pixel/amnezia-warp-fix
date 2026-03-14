#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
VERSION="1.3"
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
AMN_PORT="47684"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"

MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ПРОВЕРКА ОБНОВЛЕНИЯ (ФОНОВАЯ) ---
check_update_silent() {
    REMOTE_VER=$(curl -sL "$GITHUB_RAW" | grep -m1 'VERSION=' | cut -d'"' -f2)
    if [[ "$REMOTE_VER" != "$VERSION" && -n "$REMOTE_VER" ]]; then
        UPDATE_LABEL="${RED}[ ДОСТУПНА v$REMOTE_VER ]${NC}"
    else
        UPDATE_LABEL="${GREEN}(v$VERSION)${NC}"
    fi
}

# --- СТАТУС WARP (УЛУЧШЕННЫЙ) ---
check_status() {
    # Проверка: запущен ли процесс и есть ли интерфейс
    if pgrep -x "tun2socks" > /dev/null || ip link show "$TUN_DEV" >/dev/null 2>&1; then
        echo -e " Статус WARP: ${GREEN}● РАБОТАЕТ${NC}"
    else
        echo -e " Статус WARP: ${RED}○ ВЫКЛЮЧЕН${NC}"
    fi
}

# --- ДИАГНОСТИКА И ПИНГ (ОТДЕЛЬНОЕ МЕНЮ) ---
show_diagnostics() {
    clear
    echo -e "${CYAN}═══ ДИАГНОСТИКА СИСТЕМЫ ═══${NC}\n"
    
    # Проверка ПО
    echo -e "${YELLOW}Установленное ПО:${NC}"
    [ -d "/opt/amnezia" ] && echo -e " - Amnezia VPN: ${GREEN}Да${NC}" || echo -e " - Amnezia VPN: ${RED}Нет${NC}"
    [ -d "/usr/local/x-ui" ] && echo -e " - 3X-UI:       ${GREEN}Да${NC}" || echo -e " - 3X-UI:       ${RED}Нет${NC}"
    
    # Проверка Сети
    echo -e "\n${YELLOW}Проверка задержки:${NC}"
    P_DIR=$(curl -o /dev/null -s -w "%{time_total}\n" --interface "$MAIN_IFACE" google.com || echo "0")
    if (( $(echo "$P_DIR > 0" | bc -l) )); then
        echo -e " Прямой доступ: ${GREEN}${P_DIR} сек.${NC}"
    else
        echo -e " Прямой доступ: ${RED}Ошибка${NC}"
    fi

    P_WARP=$(curl -o /dev/null -s -w "%{time_total}\n" --proxy socks5h://127.0.0.1:"$WARP_PORT" google.com || echo "0")
    if (( $(echo "$P_WARP > 0" | bc -l) )); then
        echo -e " Через WARP:    ${GREEN}${P_WARP} сек.${NC}"
    else
        echo -e " Через WARP:    ${RED}Недоступно${NC}"
    fi

    echo -e "\n${CYAN}═══════════════════════════${NC}"
    read -p " Нажмите Enter для выхода..."
}

# --- JSON ДЛЯ 3X-UI (КРАСИВЫЙ) ---
show_json() {
    echo -e "\n${YELLOW}Данные для Outbound в 3X-UI:${NC}"
    echo -e "${CYAN}{${NC}"
    echo -e "  \"protocol\": ${GREEN}\"socks\"${NC},"
    echo -e "  \"settings\": {"
    echo -e "    \"servers\": ["
    echo -e "      {"
    echo -e "        \"address\": ${GREEN}\"127.0.0.1\"${NC},"
    echo -e "        \"port\": ${YELLOW}$WARP_PORT${NC}"
    echo -e "      }"
    echo -e "    ]"
    echo -e "  },"
    echo -e "  \"tag\": ${GREEN}\"warp\"${NC}"
    echo -e "${CYAN}}${NC}"
    read -p " Нажмите Enter..."
}

# --- ОБНОВЛЕНИЕ СКРИПТА ---
self_update() {
    echo -e "${YELLOW}Загрузка новой версии...${NC}"
    curl -sL "$GITHUB_RAW" -o /tmp/WarpGo_new
    mv /tmp/WarpGo_new "$LOCAL_PATH"
    chmod +x "$LOCAL_PATH"
    echo -e "${GREEN}Готово! Перезапустите скрипт командой WarpGo${NC}"
    exit 0
}

# --- УПРАВЛЕНИЕ МАРШРУТАМИ ---
routing_up() {
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport "$AMN_PORT" priority 5 table main 2>/dev/null
    ip rule add sport "$AMN_PORT" priority 6 table main 2>/dev/null
    ip rule add from 172.29.172.0/24 priority 100 table warp 2>/dev/null
    iptables -t nat -I POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE
    conntrack -F &>/dev/null
    echo -e "${GREEN}Маршруты подняты.${NC}"
    sleep 1
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    echo -e "${YELLOW}Маршруты удалены.${NC}"
    sleep 1
}

# --- ГЛАВНОЕ МЕНЮ ---
check_update_silent
while true; do
    clear
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}        WarpGo $UPDATE_LABEL              ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    check_status
    
    # Быстрая проверка IP в шапке
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 1 eth0.me || echo "ВЫКЛ")
    echo -e " IP WARP: ${GREEN}$W_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"

    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ ТРАФИКОМ:${NC}"
    echo -e "  2) Включить маршруты (UP)"
    echo -e "  3) Выключить маршруты (DOWN)"
    
    echo -e "\n${YELLOW} [2] УСТАНОВКА И КЛЮЧИ:${NC}"
    echo -e "  4) Установить/Обновить tun2socks"
    echo -e "  5) Регистрация ключей WARP"
    
    echo -e "\n${YELLOW} [3] СИСТЕМА И ТЕСТЫ:${NC}"
    echo -e "  6) Показать логи"
    echo -e "  7) JSON для 3X-UI"
    echo -e "  8) Диагностика ПО и Пинг"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 12) ОБНОВИТЬ СКРИПТ (WarpGo)"
    echo -e " 11) ${RED}Удалить всё${NC}"
    echo -e "  0) Выход"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    read -p " Выберите пункт: " choice

    case $choice in
        2) routing_up ;;
        3) routing_down ;;
        4) 
            V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
            wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
            unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks
            systemctl restart tun2socks ;;
        5) cd /etc/WarpGo && wgcf register --force && wgcf generate && read -p "Готово..." ;;
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        7) show_json ;;
        8) show_diagnostics ;;
        11) 
            systemctl stop tun2socks && rm -rf /etc/WarpGo /usr/local/bin/tun2socks && routing_down
            echo "Удалено." && sleep 2 ;;
        12) self_update ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ошибка!${NC}" && sleep 1 ;;
    esac
done
