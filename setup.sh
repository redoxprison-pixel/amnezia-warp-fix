#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.8"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ИНТЕРФЕЙС ---
get_header() {
    clear
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● RUN${NC}" || W_STAT="${RED}● STOP${NC}"
    
    # Получаем IP (основной и через WARP)
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "OFF")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Сервер: $S_STAT"
    echo -e " Main IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP IP: ${GREEN}$W_IP${NC} (через SOCKS5)"
    echo -e " Status:  $W_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПУНКТ 13: ЧИСТКА ---
routing_down() {
    echo -e "${YELLOW}Полный сброс маршрутов и туннелей...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    # Удаляем все наши правила
    while ip rule del priority 100 2>/dev/null; do :; done
    while ip rule del priority 500 2>/dev/null; do :; done
    iptables -t nat -F POSTROUTING 2>/dev/null
    ip route flush table 100 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Система очищена.${NC}"
    sleep 1
}

# --- ПУНКТ 5: РЕГИСТРАЦИЯ ---
register_warp() {
    echo -e "${YELLOW}Обновление аккаунта Cloudflare...${NC}"
    mkdir -p /etc/WarpGo && cd /etc/WarpGo
    rm -f wgcf-account.json wgcf-profile.conf
    /usr/local/bin/wgcf register --accept-tos
    /usr/local/bin/wgcf generate
    if [ -f /etc/WarpGo/wgcf-profile.conf ]; then
        echo -e "${GREEN}✓ Ключи получены успешно.${NC}"
    else
        echo -e "${RED}✗ Ошибка! Проверь доступ к api.cloudflareclient.com${NC}"
    fi
    sleep 2
}

# --- ПУНКТ 1: УСТАНОВКА ---
full_install() {
    echo -e "${BLUE}Установка всех компонентов...${NC}"
    apt update && apt install -y wget unzip curl python3-pip iptables-persistent
    
    # Скачиваем tun2socks
    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod 755 /usr/local/bin/tun2socks && rm t2s.zip
    
    # Скачиваем wgcf
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod 755 /usr/local/bin/wgcf
    
    # Создаем сервис
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tun2socks >/dev/null 2>&1
    
    # Регистрируем WARP
    register_warp
    echo -e "${GREEN}Установка завершена!${NC}"
    sleep 2
}

# --- ПУНКТ 2: ЗАПУСК (ИСПРАВЛЕННЫЙ) ---
routing_up() {
    if [ ! -f /etc/WarpGo/wgcf-profile.conf ]; then
        echo -e "${RED}Ошибка: Сначала выполни пункт 1 (установка и ключи).${NC}"
        sleep 2; return
    fi
    
    routing_down
    echo -e "${YELLOW}Запуск туннеля и перенаправление трафика...${NC}"
    
    # 1. Включаем форвардинг
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    
    # 2. Стартуем сервис
    systemctl start tun2socks
    sleep 3
    
    # 3. Настройка MTU для Telegram
    ip link set dev "$TUN_DEV" mtu 1280
    
    # 4. Настройка таблицы маршрутизации
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default dev "$TUN_DEV" table warp
    
    # 5. Главная магия: заворачиваем ВСЁ, но оставляем SSH доступным
    # Исключаем трафик до самого сервера, чтобы не выбило консоль
    MY_IP=$(curl -s eth0.me)
    ip rule add to $MY_IP priority 100 table main
    # Весь остальной трафик — в туннель
    ip rule add from all priority 500 table warp
    
    # 6. Маскарад
    iptables -t nat -A POSTROUTING -o "$TUN_DEV" -j MASQUERADE
    
    echo -e "${GREEN}✓ Маршруты применены. Проверь статус в меню.${NC}"
    sleep 2
}

# --- ПУНКТ 9: DNS ---
manage_dns() {
    clear
    echo -e "${BLUE}━━━ Настройка DNS ━━━${NC}"
    echo -e "1) Cloudflare (1.1.1.1)\n2) Google (8.8.8.8)\n3) Сброс"
    read -p "> " d; 
    case $d in
        1) echo "nameserver 1.1.1.1" > /etc/resolv.conf ;;
        2) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
        3) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
    esac
    echo "DNS обновлен."; sleep 1
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) ${CYAN}ПОЛНАЯ УСТАНОВКА${NC} (Всё с нуля)"
    echo -e " 2) ${GREEN}ЗАПУСТИТЬ WARP${NC} (Включить туннель)"
    echo -e " 3) ${YELLOW}ОСТАНОВИТЬ WARP${NC} (Выключить)"
    echo -e " 4) Управление компонентами (tun2/wgcf)"
    echo -e " 5) Обновить ключи CloudFlare"
    echo -e " 8) Тест скорости"
    echo -e " 9) Управление DNS"
    echo -e " 13) ${RED}ПОЛНОЕ УДАЛЕНИЕ${NC}"
    echo -e " 0) Выход"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        4) clear; echo -e "1) tun2socks\n2) wgcf\n0) назад"; read -p "> " c
           [ "$c" == "1" ] && (V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4); wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip; unzip -o t2s.zip; mv tun2socks-linux-amd64 /usr/local/bin/tun2socks; chmod 755 /usr/local/bin/tun2socks; rm t2s.zip; echo "Обновлено")
           [ "$c" == "2" ] && (wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf; chmod 755 /usr/local/bin/wgcf; echo "Обновлено") ;;
        5) register_warp ;;
        8) clear; echo "Тест скорости..."; apt install -y speedtest-cli >/dev/null 2>&1; speedtest-cli --simple; read -p "Enter..." ;;
        9) manage_dns ;;
        13) routing_down; rm -rf /etc/WarpGo /usr/local/bin/tun2socks /usr/local/bin/wgcf; echo "Стерто."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
