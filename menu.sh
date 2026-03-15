#!/bin/bash

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PORT=40000
TUN_IP="10.0.0.1"
TUN_NET="10.0.0.0/24"

# 1. Установка Tun2Socks
install_tun2socks() {
    echo -e "${YELLOW}Установка Tun2Socks...${NC}"
    ARCH=$(uname -m)
    URL=""
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip"
    elif [[ "$ARCH" == "aarch64" ]]; then
        URL="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-arm64.zip"
    fi
    
    apt install unzip -y > /dev/null
    curl -L "$URL" -o /tmp/t2s.zip
    unzip -o /tmp/t2s.zip -d /tmp/
    mv /tmp/tun2socks-linux-* /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    echo -e "${GREEN}Tun2Socks установлен.${NC}"
}

# 2. Создание интерфейса и маршрутизация
up_tun() {
    echo -e "${YELLOW}Поднятие интерфейса tun0...${NC}"
    
    # Создаем виртуальную сетевую карту
    ip tuntap add dev tun0 mode tun
    ip addr add $TUN_IP/24 dev tun0
    ip link set tun0 up

    # Запускаем tun2socks в фоне
    nohup /usr/local/bin/tun2socks -proxy socks5://127.0.0.1:$PORT -interface tun0 > /dev/null 2>&1 &
    
    # Настройка маршрутизации (чтобы не убить SSH)
    # Создаем отдельную таблицу 100 для WARP
    ip rule add from $TUN_NET lookup 100
    ip route add default dev tun0 table 100
    
    # Трюк: направляем только определенный трафик или весь, кроме SSH
    # Для начала просто создадим интерфейс.
    echo -e "${GREEN}Интерфейс tun0 готов.${NC}"
}

# 3. Полная очистка
down_tun() {
    echo -e "${YELLOW}Удаление интерфейса...${NC}"
    killall tun2socks 2>/dev/null
    ip link delete tun0 2>/dev/null
    ip rule del from $TUN_NET lookup 100 2>/dev/null
    echo -e "${GREEN}Очищено.${NC}"
}

# --- МЕНЮ ---
clear
echo -e "${CYAN}Управление Tun2Socks + WARP${NC}"
echo -e "1) Полная установка (Tun2Socks + Маршруты)"
echo -e "2) Поднять tun0"
echo -e "3) Положить tun0"
echo -e "0) Выход"
read -p "Выбор: " ch

case $ch in
    1) install_tun2socks && up_tun ;;
    2) up_tun ;;
    3) down_tun ;;
    0) exit 0 ;;
esac
