#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.7"
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
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "${RED}ВЫКЛ${NC}")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | IP: ${GREEN}$W_IP${NC}"
    echo -e " DNS:    ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПОЛНЫЙ СБРОС ---
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

# --- РЕГИСТРАЦИЯ WGCF (Пункт 5) ---
register_warp() {
    echo -e "${YELLOW}Регистрация нового профиля в Cloudflare...${NC}"
    mkdir -p /etc/WarpGo && cd /etc/WarpGo
    rm -f wgcf-account.json wgcf-profile.conf
    /usr/local/bin/wgcf register --accept-tos
    /usr/local/bin/wgcf generate
    if [ -f /etc/WarpGo/wgcf-profile.conf ]; then
        echo -e "${GREEN}✓ Профиль успешно создан.${NC}"
    else
        echo -e "${RED}✗ Ошибка регистрации! Проверь интернет.${NC}"
    fi
    sleep 2
}

# --- УСТАНОВКА (Пункт 1) ---
full_install() {
    echo -e "${BLUE}Начинаю полную установку без лишних вопросов...${NC}"
    apt update && apt install -y wget unzip curl python3-pip
    
    # 1. tun2socks
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod 755 /usr/local/bin/tun2socks && rm t2s.zip
    
    # 2. wgcf
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod 755 /usr/local/bin/wgcf
    
    # 3. Service
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
    systemctl enable tun2socks >/dev/null 2>&1
    
    # 4. Регистрация ключей автоматически
    register_warp
    
    echo -e "${GREEN}Все компоненты установлены и настроены!${NC}"
    sleep 2
}

# --- ЗАПУСК (Пункт 2) ---
routing_up() {
    if [ ! -f /etc/WarpGo/wgcf-profile.conf ]; then
        echo -e "${RED}Нет ключей! Сначала пункт 1 или 5.${NC}"; sleep 2; return
    fi
    
    routing_down # Очистка перед запуском
    
    echo -e "${YELLOW}Запуск туннеля и настройка маршрутов...${NC}"
    systemctl start tun2socks
    sleep 3

    # Принудительное включение форвардинга
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    
    # Настройка таблицы warp
    ip route flush table warp
    ip route add default dev "$TUN_DEV" table warp
    
    # Правила перенаправления
    # 1. Весь локальный трафик (кроме управления) в таблицу warp
    ip rule add from all priority 100 table warp
    # 2. Исключаем основной IP, чтобы не потерять SSH
    ip rule add to $(curl -s eth0.me) priority 5 table main
    
    # Маскарад
    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE
    
    echo -e "${GREEN}✓ Маршрутизация включена. Проверь IP в шапке.${NC}"
    sleep 2
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    get_header
    echo -e " 1) ${CYAN}ПОЛНАЯ УСТАНОВКА${NC} (Всё включено + ключи)"
    echo -e " 2) Запустить WARP (UP)"
    echo -e " 3) Остановить WARP (DOWN)"
    echo -e " 5) Обновить ключи CloudFlare"
    echo -e " 8) Тест скорости"
    echo -e " 9) Управление DNS"
    echo -e " 13) ${RED}СБРОС И УДАЛЕНИЕ${NC}"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        5) register_warp ;;
        8) clear; echo "Тест скорости..."; apt install -y speedtest-cli >/dev/null 2>&1
           speedtest-cli --simple || echo "Ошибка теста"; read -p "Enter..." ;;
        9) # Быстрый выбор DNS
           echo "nameserver 1.1.1.1" > /etc/resolv.conf; echo "DNS: Cloudflare"; sleep 1 ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Удалено."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
