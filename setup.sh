#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
VERSION="3.6"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo -e "${RED}ВЫКЛ${NC}")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Исправление Endpoint"
    echo -e " Main IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP IP: $W_IP"
    echo -e " Status:  $W_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ФИКС КОНФИГА (Ключевое решение) ---
patch_config() {
    CONF="/etc/WarpGo/wgcf-profile.conf"
    if [ -f "$CONF" ]; then
        echo -e "${YELLOW}Применяю патч эндпоинта (пробив блокировки)...${NC}"
        # Заменяем engage.cloudflareclient.com на прямой IP и порт 1701 (часто открыт)
        sed -i 's/engage.cloudflareclient.com:2408/162.159.192.1:1701/g' "$CONF"
        echo -e "${GREEN}✓ Конфиг пропатчен.${NC}"
    fi
}

routing_down() {
    systemctl stop tun2socks >/dev/null 2>&1
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 101 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    iptables -t nat -F
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
}

routing_up() {
    routing_down
    patch_config # Патчим перед запуском
    
    echo -e "${YELLOW}Запуск WARP...${NC}"
    systemctl start tun2socks
    sleep 3
    
    ip addr add 192.168.100.1/24 dev "$TUN_DEV" 2>/dev/null
    ip link set dev "$TUN_DEV" mtu 1280
    ip link set dev "$TUN_DEV" up

    # Маршрутизация
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route add default dev "$TUN_DEV" table 100
    
    # SSH Safe
    MY_REMOTE_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    [ -n "$MY_REMOTE_IP" ] && ip rule add to "$MY_REMOTE_IP" priority 100 table main
    
    # Cloudflare IPs Bypass (чтобы не зациклило)
    ip rule add to 162.159.0.0/16 priority 101 table main
    
    ip rule add from all priority 500 table 100
    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE

    echo -e "${BLUE}Тестирую пробивку...${NC}"
    if curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 6 google.com > /dev/null; then
        echo -e "${GREEN}✓ ЕСТЬ КОННЕКТ! WARP пробился.${NC}"
    else
        echo -e "${RED}✗ ПРОВАЛ. Cloudflare всё еще блокирует UDP.${NC}"
        routing_down
        read -p "Нажми Enter..."
    fi
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) Установить (Чистая установка)"
    echo -e " 2) ЗАПУСТИТЬ WARP (С патчем Endpoint)"
    echo -e " 3) ОСТАНОВИТЬ"
    echo -e " 5) Обновить ключи CloudFlare"
    echo -e " 6) Проверить статус сервиса"
    echo -e " 13) ${RED}СБРОС СЕТИ${NC}"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
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
        5) cd /etc/WarpGo && rm -f wgcf* && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate; patch_config ;;
        6) systemctl status tun2socks --no-pager; read -p "Enter..." ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Сброшено."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
