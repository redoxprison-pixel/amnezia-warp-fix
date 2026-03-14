#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.6"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ИНТЕРФЕЙС ---
get_header() {
    clear
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    if pgrep -x "tun2socks" >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
        W_STAT="${GREEN}● OK${NC}"
    else
        W_STAT="${RED}● OFF${NC}"
    fi
    DNS_CUR=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | DNS: ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ФУНКЦИИ СЕТИ (9, 13) ---
routing_down() {
    echo -e "${YELLOW}Очистка сетевых правил...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    while ip rule del priority 5 2>/dev/null; do :; done
    while ip rule del priority 6 2>/dev/null; do :; done
    while ip rule del priority 100 2>/dev/null; do :; done
    iptables -t nat -F POSTROUTING 2>/dev/null
    ip route flush table warp 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Сеть сброшена.${NC}"
    sleep 1
}

manage_dns() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление DNS ━━━${NC}\n"
        echo -e " 1) AdGuard DNS | 2) Cloudflare | 3) Google"
        echo -e " 4) Comss (RU)  | 5) Control D   | 6) Сброс"
        echo -e "\n 0) Назад"
        read -p " Выбор: " d_choice
        case $d_choice in
            1) echo "nameserver 94.140.14.14" > /etc/resolv.conf ;;
            2) echo "nameserver 1.1.1.1" > /etc/resolv.conf ;;
            3|6) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
            4) echo "nameserver 76.76.2.22" > /etc/resolv.conf ;;
            5) echo "nameserver 76.76.2.11" > /etc/resolv.conf ;;
            0) break ;;
        esac
        echo -e "${GREEN}DNS изменен.${NC}"; sleep 1; break
    done
}

# --- ЗАПУСК ---
routing_up() {
    if [ ! -f /usr/local/bin/tun2socks ]; then
        echo -e "${RED}tun2socks не найден! Установи в п.4${NC}"; sleep 2; return
    fi
    systemctl daemon-reload
    ip link delete $TUN_DEV >/dev/null 2>&1
    systemctl restart tun2socks
    sleep 2

    if ! pgrep -x "tun2socks" >/dev/null; then
        echo -e "${RED}Ошибка запуска!${NC}"
        journalctl -u tun2socks -n 5 --no-pager; read -p "Enter..."; return
    fi

    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport 47684 priority 5 table main 2>/dev/null
    ip rule add sport 47684 priority 6 table main 2>/dev/null
    ip rule add from 172.29.172.0/24 priority 100 table warp 2>/dev/null
    iptables -t nat -A POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE
    echo -e "${GREEN}✓ WARP запущен.${NC}"; sleep 1
}

# --- КОМПОНЕНТЫ ---
install_comp() {
    apt update && apt install -y wget unzip curl python3-pip
    if [ "$1" == "t" ]; then
        V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
        wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
        unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
        chmod 755 /usr/local/bin/tun2socks && rm t2s.zip
        cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo Tun
After=network.target
[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    elif [ "$1" == "w" ]; then
        mkdir -p /etc/WarpGo
        wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
        chmod 755 /usr/local/bin/wgcf
    fi
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) Установить всё (Чистая установка)"
    echo -e " 2) Запустить WARP"
    echo -e " 3) Остановить WARP"
    echo -e " 5) Обновить ключи (wgcf)"
    echo -e " 8) Тест скорости (Compact)"
    echo -e " 9) Управление DNS"
    echo -e " 13) ${RED}СБРОС И УДАЛЕНИЕ${NC}"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) install_comp "t"; install_comp "w"; echo "Установлено."; sleep 1 ;;
        2) routing_up ;;
        3) routing_down ;;
        5) cd /etc/WarpGo && rm -f wgcf-account.json wgcf-profile.conf
           yes | wgcf register >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1 ;;
        8) clear; echo "Тест скорости..."; apt install -y speedtest-cli >/dev/null 2>&1
           speedtest-cli --simple || echo "Ошибка теста"; read -p "Enter..." ;;
        9) manage_dns ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Удалено."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
