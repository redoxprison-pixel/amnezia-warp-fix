#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфиг
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
AMN_SUBNET="172.29.172.0/24"
AMN_PORT="47684"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"

MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ФУНКЦИИ ---
check_ips() {
    echo -e "${CYAN}--- Статус IP ---${NC}"
    REAL_IP=$(curl -s --interface "$MAIN_IFACE" eth0.me || echo "Ошибка")
    WARP_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" eth0.me || echo "ВЫКЛ")
    echo -e "IP Сервера: ${YELLOW}$REAL_IP${NC} | IP WARP: ${GREEN}$WARP_IP${NC}"
}

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
    echo -e "${GREEN}Маршруты активны!${NC}"
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    echo -e "${YELLOW}Маршрутизация отключена.${NC}"
}

install_all() {
    apt update && apt install -y curl wget unzip iptables conntrack
    # Регистрация WGCF
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    mkdir -p /etc/WarpGo && cd /etc/WarpGo || exit
    yes | wgcf register && wgcf generate
    # Установка Tun2Socks
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks
    # Сервис
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo
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
}

# --- МЕНЮ ---
while true; do
    clear
    echo -e "${CYAN}═══ WarpGo v3.2 ═══${NC}"
    check_ips
    echo -e "\n1) ${GREEN}Установка${NC} | 2) Вкл (UP) | 3) Выкл (DOWN)"
    echo -e "4) JSON 3X-UI | 5) Ключи | 6) Логи | 11) ${RED}Удалить${NC} | 0) Выход"
    read -p "Выбор: " c
    case $c in
        1) install_all ;;
        2) routing_up ;;
        3) routing_down ;;
        4) echo '{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]},"tag":"warp"}' && read ;;
        5) cd /etc/WarpGo && wgcf register --force && wgcf generate && read ;;
        6) tail -n 50 "$LOG_FILE" && read ;;
        11) systemctl stop tun2socks && rm -rf /etc/WarpGo /usr/local/bin/tun2socks && routing_down && read ;;
        0) exit 0 ;;
        *) echo "Ошибка" && sleep 1 ;;
    esac
done
