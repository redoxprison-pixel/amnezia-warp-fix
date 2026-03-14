#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
AMN_SUBNET="172.29.172.0/24"
AMN_PORT="47684"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"

MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ПРОВЕРКА ОКРУЖЕНИЯ ---
check_env() {
    echo -e "${CYAN}--- Проверка ПО на сервере ---${NC}"
    if [ -d "/opt/amnezia" ] || iptables -S | grep -q "amn0"; then
        echo -e " Amnezia VPN: ${GREEN}Обнаружена${NC}"
    else
        echo -e " Amnezia VPN: ${RED}Не найдена${NC}"
    fi

    if [ -d "/usr/local/x-ui" ] || lsof -i :2053 >/dev/null 2>&1; then
        echo -e " 3X-UI:       ${GREEN}Обнаружен${NC}"
    else
        echo -e " 3X-UI:       ${RED}Не найден${NC}"
    fi
    
    echo -e "${CYAN}--- Компоненты WarpGo ---${NC}"
    [ -f "/usr/local/bin/tun2socks" ] && echo -e " tun2socks:   ${GREEN}Установлен${NC}" || echo -e " tun2socks:   ${RED}Отсутствует${NC}"
    [ -f "/usr/local/bin/wgcf" ] && echo -e " wgcf (WARP): ${GREEN}Установлен${NC}" || echo -e " wgcf (WARP): ${RED}Отсутствует${NC}"
}

check_status() {
    if ip link show "$TUN_DEV" >/dev/null 2>&1 && systemctl is-active --quiet tun2socks; then
        echo -e " Статус WARP: ${GREEN}● РАБОТАЕТ${NC}"
    else
        echo -e " Статус WARP: ${RED}○ ВЫКЛЮЧЕН${NC}"
    fi
}

check_ips() {
    echo -e "${CYAN}--- Статус сети ---${NC}"
    REAL_IP=$(curl -s --interface "$MAIN_IFACE" --max-time 2 eth0.me || echo "Ошибка")
    WARP_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    echo -e " IP Сервера: ${YELLOW}$REAL_IP${NC}"
    echo -e " IP WARP:    ${GREEN}$WARP_IP${NC}"
    
    if [ "$WARP_IP" != "ВЫКЛ" ]; then
        PING_WARP=$(ping -c 1 -I "$TUN_DEV" 1.1.1.1 | grep 'time=' | awk -F'time=' '{print $2}' || echo "timeout")
        echo -e " Пинг WARP:  ${GREEN}$PING_WARP${NC}"
    fi
}

# --- МОДУЛЬНАЯ УСТАНОВКА ---
install_wgcf() {
    echo -e "${YELLOW}Установка/Перевыпуск ключей WARP...${NC}"
    apt update && apt install -y wget wireguard-tools
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    mkdir -p /etc/WarpGo && cd /etc/WarpGo || exit
    rm -f wgcf-account.json wgcf-profile.conf
    yes | wgcf register && wgcf generate
    echo -e "${GREEN}Ключи обновлены в /etc/WarpGo/${NC}"
    sleep 2
}

install_tun2socks() {
    echo -e "${YELLOW}Установка tun2socks...${NC}"
    apt update && apt install -y unzip curl
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks
    rm t2s.zip
    
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo Tun2Socks
After=network.target
[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable tun2socks && systemctl restart tun2socks
    echo -e "${GREEN}Сервис tun2socks готов.${NC}"
    sleep 2
}

# --- ОБНОВЛЕНИЕ СКРИПТА ---
self_update() {
    echo -e "${YELLOW}Проверка новой версии WarpGo...${NC}"
    curl -sL "$GITHUB_RAW" -o /tmp/WarpGo_new
    if ! diff -q "$LOCAL_PATH" /tmp/WarpGo_new > /dev/null; then
        echo -e "${CYAN}Найдено обновление! Устанавливаю...${NC}"
        mv /tmp/WarpGo_new "$LOCAL_PATH"
        chmod +x "$LOCAL_PATH"
        echo -e "${GREEN}Скрипт обновлен. Перезапустите его командой WarpGo${NC}"
        exit 0
    else
        echo -e "${GREEN}У вас актуальная версия.${NC}"
        sleep 1.5
    fi
}

# --- МАРШРУТЫ ---
routing_up() {
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport "$AMN_PORT" priority 5 table main 2>/dev/null
    ip rule add sport "$AMN_PORT" priority 6 table main 2>/dev/null
    ip rule add from "$AMN_SUBNET" priority 100 table warp 2>/dev/null
    iptables -t nat -I POSTROUTING -s "$AMN_SUBNET" ! -d "$AMN_SUBNET" -j MASQUERADE
    iptables -t nat -I PREROUTING -i amn0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
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

# --- МЕНЮ ---
while true; do
    clear
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}             WarpGo v1.2 (Modular)            ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    check_status
    check_ips
    check_env

    echo -e "\n${YELLOW} [1] УПРАВЛЕНИЕ ТРАФИКОМ:${NC}"
    echo -e "  2) Включить маршруты (UP)"
    echo -e "  3) Выключить маршруты (DOWN)"
    
    echo -e "\n${YELLOW} [2] УСТАНОВКА КОМПОНЕНТОВ:${NC}"
    echo -e "  4) Установить/Обновить tun2socks"
    echo -e "  5) Регистрация/Сброс ключей WARP"
    
    echo -e "\n${YELLOW} [3] СЕРВИС И ОБНОВЛЕНИЯ:${NC}"
    echo -e "  6) Показать логи | 7) JSON 3X-UI"
    echo -e " 12) ОБНОВИТЬ СКРИПТ (WarpGo)"
    echo -e " 11) ${RED}Удалить всё${NC} | 0) Выход"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    read -p " Выберите пункт: " choice

    case $choice in
        2) routing_up ;;
        3) routing_down ;;
        4) install_tun2socks ;;
        5) install_wgcf ;;
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        7) echo '{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]},"tag":"warp"}' && read -p "Enter..." ;;
        11) 
            systemctl stop tun2socks && systemctl disable tun2socks
            rm -f /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks /usr/local/bin/wgcf
            rm -rf /etc/WarpGo
            routing_down
            echo -e "${RED}Удалено.${NC}" && sleep 2 ;;
        12) self_update ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ошибка!${NC}" && sleep 1 ;;
    esac
done
