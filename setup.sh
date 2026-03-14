#!/bin/bash

# Цвета и конфиг
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
VERSION="3.4"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | SSH Safe Mode"
    echo -e " Main IP: ${YELLOW}$S_IP${NC} (SSH доступен)"
    echo -e " WARP IP: ${GREEN}$W_IP${NC} (через SOCKS5:40000)"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# Безопасный стоп
routing_down() {
    systemctl stop tun2socks >/dev/null 2>&1
    ip link delete $TUN_DEV >/dev/null 2>&1
    iptables -t nat -F
    echo -e "${GREEN}✓ Остановлено.${NC}"
    sleep 1
}

# Безопасный запуск
routing_up() {
    routing_down
    echo -e "${YELLOW}Запуск WARP...${NC}"
    systemctl start tun2socks
    sleep 3
    
    # Просто поднимаем интерфейс, но НЕ меняем шлюз по умолчанию!
    ip addr add 192.168.100.1/24 dev "$TUN_DEV" 2>/dev/null
    ip link set dev "$TUN_DEV" mtu 1280
    ip link set dev "$TUN_DEV" up
    
    # Теперь интернет на сервере идет как обычно, 
    # а WARP доступен через 127.0.0.1:40000
    echo -e "${GREEN}✓ WARP готов. SSH в безопасности.${NC}"
    sleep 2
}

# МЕНЮ
while true; do
    get_header
    echo -e " 1) Установить / Переустановить (Fix 203)"
    echo -e " 2) ЗАПУСТИТЬ (Без риска для SSH)"
    echo -e " 3) ОСТАНОВИТЬ"
    echo -e " 5) Обновить ключи CloudFlare"
    echo -e " 13) ${RED}ПОЛНОЕ УДАЛЕНИЕ${NC}"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) # Переустановка бинарников
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
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Удалено."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
