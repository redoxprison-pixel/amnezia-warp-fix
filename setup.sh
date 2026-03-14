#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Конфигурация
VERSION="3.5"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo -e "${RED}ВЫКЛ${NC}")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Interface: $MAIN_IFACE"
    echo -e " Main IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP IP: $W_IP (SOCKS5:40000)"
    echo -e " Status:  $W_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПОЛНЫЙ СБРОС (Безопасность) ---
routing_down() {
    echo -e "${YELLOW}Очистка сетевых правил...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    # Сброс всех возможных правил от старых версий
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 101 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    iptables -t nat -F
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Сеть восстановлена.${NC}"
}

# --- ЗАПУСК С ПРОВЕРКОЙ ---
routing_up() {
    routing_down
    echo -e "${YELLOW}Запуск туннеля...${NC}"
    
    # 1. Запуск tun2socks
    systemctl start tun2socks
    sleep 3
    
    if ! pgrep -x "tun2socks" >/dev/null; then
        echo -e "${RED}Ошибка: tun2socks не запущен. Проверь логи (п.6).${NC}"; sleep 2; return
    fi

    # 2. Настройка интерфейса
    ip addr add 192.168.100.1/24 dev "$TUN_DEV" 2>/dev/null
    ip link set dev "$TUN_DEV" mtu 1280
    ip link set dev "$TUN_DEV" up

    # 3. Маршрутизация (Safe Mode)
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route add default dev "$TUN_DEV" table 100
    
    # Защита SSH: оставляем текущую сессию в основной таблице
    MY_REMOTE_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    if [ -z "$MY_REMOTE_IP" ]; then MY_REMOTE_IP="0.0.0.0/0"; fi
    ip rule add to "$MY_REMOTE_IP" priority 100 table main
    
    # Исключаем Cloudflare (чтобы WARP не закольцевался)
    ip rule add to 162.159.0.0/16 priority 101 table main
    
    # Заворачиваем остальное
    ip rule add from all priority 500 table 100
    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE

    # 4. ТЕСТ СВЯЗИ
    echo -e "${BLUE}Проверка интернета через туннель...${NC}"
    if curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 5 google.com > /dev/null; then
        echo -e "${GREEN}✓ УСПЕХ: WARP работает!${NC}"
    else
        echo -e "${RED}✗ ПРОВАЛ: Интернета в туннеле нет. ОТКАТ...${NC}"
        routing_down
        echo -e "${YELLOW}Причина: Cloudflare не отвечает. Попробуй пункт 5 (новые ключи).${NC}"
        read -p "Нажми Enter..."
    fi
}

# --- УСТАНОВКА (Исправленная) ---
full_install() {
    echo -e "${BLUE}Установка компонентов...${NC}"
    apt update && apt install -y wget unzip curl
    # tun2socks
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod 755 /usr/local/bin/tun2socks; rm t2s.zip
    # wgcf
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod 755 /usr/local/bin/wgcf
    # Ключи
    mkdir -p /etc/WarpGo && cd /etc/WarpGo
    /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate
    
    # Сервис
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
    echo -e "${GREEN}Готово!${NC}"; sleep 2
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) Установить WARP (Все компоненты)"
    echo -e " 2) ЗАПУСТИТЬ WARP (UP)"
    echo -e " 3) ОСТАНОВИТЬ WARP (DOWN)"
    echo -e " 5) Обновить ключи CloudFlare (Если ВЫКЛ)"
    echo -e " 6) Показать логи (Ошибки)"
    echo -e " 13) ${RED}КРИТИЧЕСКИЙ СБРОС СЕТИ${NC}"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        5) cd /etc/WarpGo && rm -f wgcf* && /usr/local/bin/wgcf register --accept-tos && /usr/local/bin/wgcf generate; echo "Ключи обновлены."; sleep 1 ;;
        6) journalctl -u tun2socks -n 50 --no-pager; read -p "Enter..." ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Сброшено."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
