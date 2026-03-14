#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
VERSION="3.2"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# Получаем IP, с которого ты зашел (SSH_CLIENT)
MY_REMOTE_IP=$(echo $SSH_CLIENT | awk '{print $1}')

get_header() {
    clear
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Твой IP: ${MAGENTA}$MY_REMOTE_IP${NC}"
    echo -e " Сервер IP: ${YELLOW}$S_IP${NC} | WARP IP: ${GREEN}$W_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

routing_down() {
    echo -e "${YELLOW}Откат сетевых настроек...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 101 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    iptables -t nat -F
    ip route flush table 100 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
}

routing_up() {
    routing_down
    echo -e "${YELLOW}Запуск туннеля...${NC}"
    
    # 1. Запуск сервиса
    systemctl start tun2socks
    sleep 3
    
    # 2. Настройка интерфейса
    ip link set dev "$TUN_DEV" mtu 1280
    ip addr add 192.168.100.1/24 dev "$TUN_DEV" 2>/dev/null
    ip link set dev "$TUN_DEV" up

    # 3. Маршрутизация
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route add default dev "$TUN_DEV" table 100

    # ПРАВИЛА ИСКЛЮЧЕНИЙ
    # Исключаем ТВОЙ IP (чтобы SSH работал)
    if [ -n "$MY_REMOTE_IP" ]; then
        ip rule add to "$MY_REMOTE_IP" priority 100 table main
    fi
    # Исключаем сам Cloudflare
    ip rule add to 162.159.0.0/16 priority 101 table main
    # Весь остальной трафик в туннель
    ip rule add from all priority 500 table 100

    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE

    # ПРОВЕРКА СВЯЗИ
    echo -ne "${YELLOW}Проверка коннекта... ${NC}"
    if curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 5 google.com > /dev/null; then
        echo -e "${GREEN}УСПЕХ!${NC}"
    else
        echo -e "${RED}НЕТ СВЯЗИ! Откат правил...${NC}"
        routing_down
        echo -e "${RED}Ошибка: WARP не смог пробиться. Проверь ключи (п.5)${NC}"
        sleep 3
    fi
}

# --- МЕНЮ (Компактное, как ты любишь) ---
while true; do
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить всё с нуля (Fix 203/EXEC)"
    echo -e "  2) ЗАПУСТИТЬ WARP (с защитой SSH)"
    echo -e "  3) ОСТАНОВИТЬ WARP"
    echo -e "\n${YELLOW} [2] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e "  5) Обновить ключи CloudFlare"
    echo -e "  6) Показать логи ошибок"
    echo -e " 13) ${RED}ПОЛНЫЙ СБРОС И УДАЛЕНИЕ${NC}"
    echo -e "  0) Выход"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) # Переустановка
           routing_down
           apt update && apt install -y wget unzip curl
           V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
           wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
           unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod 755 /usr/local/bin/tun2socks; rm t2s.zip
           wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod 755 /usr/local/bin/wgcf
           mkdir -p /etc/WarpGo && cd /etc/WarpGo && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate
           cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks
After=network.target
[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
           systemctl daemon-reload && systemctl enable tun2socks
           echo "Готово."; sleep 2 ;;
        2) routing_up ;;
        3) routing_down ;;
        5) cd /etc/WarpGo && rm -f wgcf* && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate ;;
        6) journalctl -u tun2socks -n 50 --no-pager && read -p "Enter..." ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Стерто."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
