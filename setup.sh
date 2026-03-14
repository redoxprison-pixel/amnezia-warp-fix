#!/bin/bash

# WarpGo v1.1 - Менеджер Cloudflare WARP
# Исправлен статус и добавлена проверка задержки (Ping)

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

# --- ФУНКЦИИ ПРОВЕРКИ ---
check_status() {
    # Проверяем наличие интерфейса и работу службы
    if ip link show "$TUN_DEV" >/dev/null 2>&1 && systemctl is-active --quiet tun2socks; then
        echo -e " Статус WARP: ${GREEN}● РАБОТАЕТ${NC}"
    else
        echo -e " Статус WARP: ${RED}○ ВЫКЛЮЧЕН${NC}"
    fi
}

check_ips() {
    echo -e "${CYAN}--- Статус сети ---${NC}"
    # Определение IP
    REAL_IP=$(curl -s --interface "$MAIN_IFACE" --max-time 2 eth0.me || echo "Ошибка")
    WARP_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    
    echo -e " IP Сервера: ${YELLOW}$REAL_IP${NC}"
    echo -e " IP WARP:    ${GREEN}$WARP_IP${NC}"
    
    # Проверка задержки (Ping)
    echo -e "\n${CYAN}--- Задержка (Ping) ---${NC}"
    PING_DIR=$(ping -c 1 -I "$MAIN_IFACE" 8.8.8.8 | grep 'time=' | awk -F'time=' '{print $2}' || echo "timeout")
    echo -e " Прямой пинг (8.8.8.8): ${YELLOW}$PING_DIR${NC}"
    
    if [ "$WARP_IP" != "ВЫКЛ" ]; then
        # Пинг через туннель (используем интерфейс туннеля)
        PING_WARP=$(ping -c 1 -I "$TUN_DEV" 1.1.1.1 | grep 'time=' | awk -F'time=' '{print $2}' || echo "timeout")
        echo -e " WARP пинг   (1.1.1.1): ${GREEN}$PING_WARP${NC}"
    else
        echo -e " WARP пинг:             ${RED}недоступно${NC}"
    fi
    echo -e "${CYAN}-----------------------${NC}"
}

# --- УПРАВЛЕНИЕ МАРШРУТАМИ ---
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
    echo -e "${GREEN}Маршрутизация включена!${NC}"
    sleep 1
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    # Очистка iptables (опционально, если нужно)
    echo -e "${YELLOW}Маршрутизация отключена.${NC}"
    sleep 1
}

# --- УСТАНОВКА ---
install_all() {
    echo -e "${CYAN}Установка зависимостей...${NC}"
    apt update && apt install -y curl wget unzip iptables conntrack wireguard-tools iputils-ping
    
    echo -e "${CYAN}Регистрация Cloudflare WARP (wgcf)...${NC}"
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    mkdir -p /etc/WarpGo && cd /etc/WarpGo || exit
    yes | wgcf register && wgcf generate
    
    echo -e "${CYAN}Установка tun2socks...${NC}"
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks
    
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo Tun2Socks Service
After=network.target

[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable tun2socks && systemctl start tun2socks
    routing_up
    echo -e "${GREEN}Установка WarpGo v1.1 завершена!${NC}"
    read -p "Нажмите Enter..."
}

# --- ГЛАВНЫЙ ЦИКЛ МЕНЮ ---
while true; do
    clear
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}             WarpGo v1.1                      ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    check_status
    check_ips
    
    echo -e "${YELLOW} УПРАВЛЕНИЕ:${NC}"
    echo -e "  1) ${GREEN}Полная установка (Soft + WARP)${NC}"
    echo -e "  2) Включить маршруты (UP)"
    echo -e "  3) Выключить маршруты (DOWN)"
    echo ""
    echo -e "${YELLOW} ИНСТРУМЕНТЫ:${NC}"
    echo -e "  4) Настройки 3X-UI (JSON)"
    echo -e "  5) Перевыпустить ключи (WGCF)"
    echo -e "  6) Показать логи"
    echo ""
    echo -e "${YELLOW} СИСТЕМА:${NC}"
    echo -e " 11) ${RED}Полное удаление${NC}"
    echo -e "  0) Выход"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    read -p " Выберите пункт: " choice

    case $choice in
        1) install_all ;;
        2) routing_up ;;
        3) routing_down ;;
        4) 
            echo -e "\n${YELLOW}Добавьте этот Outbound в 3X-UI:${NC}"
            echo '{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]},"tag":"warp"}'
            read -p "Enter..." ;;
        5) cd /etc/WarpGo && wgcf register --force && wgcf generate && read -p "Готово. Enter..." ;;
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        11) 
            systemctl stop tun2socks && systemctl disable tun2socks
            rm -f /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks /usr/local/bin/wgcf
            rm -rf /etc/WarpGo
            routing_down
            echo -e "${RED}Удалено.${NC}" && sleep 2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ошибка!${NC}" && sleep 1 ;;
    esac
done
