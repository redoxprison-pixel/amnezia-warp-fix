#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.5"
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
    DNS_CUR=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1 | cut -d' ' -f2)
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | DNS: ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- УДАЛЕНИЕ И СБРОС (Пункт 13) ---
routing_down() {
    echo -e "${YELLOW}Полная очистка сетевых правил...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    while ip rule del priority 5 2>/dev/null; do :; done
    while ip rule del priority 6 2>/dev/null; do :; done
    while ip rule del priority 100 2>/dev/null; do :; done
    iptables -t nat -F POSTROUTING 2>/dev/null
    ip route flush table warp 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Система приведена в исходное состояние.${NC}"
    sleep 1
}

# --- УПРАВЛЕНИЕ DNS (Пункт 9) ---
manage_dns() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление DNS ━━━${NC}\n"
        echo -e " 1) AdGuard DNS (Блокировка рекламы)"
        echo -e " 2) Cloudflare  (1.1.1.1)"
        echo -e " 3) Google      (8.8.8.8)"
        echo -e " 4) Comss.one   (RU серверы)"
        echo -e " 5) Control D   (Фильтрация)"
        echo -e "\n 6) Сбросить на стандарт (Google)"
        echo -e " 0) Назад"
        read -p " Выбор: " d_choice
        case $d_choice in
            1) echo "nameserver 94.140.14.14" > /etc/resolv.conf ;;
            2) echo "nameserver 1.1.1.1" > /etc/resolv.conf ;;
            3|6) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
            4) echo "nameserver 76.76.2.22" > /etc/resolv.conf ;;
            5) echo "nameserver 76.76.2.11" > /etc/resolv.conf ;;
            0) break ;;
        esac
        echo -e "${GREEN}DNS обновлен.${NC}"; sleep 1; break
    done
}

# --- ЗАПУСК WARP (Пункт 2) ---
routing_up() {
    if [ ! -f /usr/local/bin/tun2socks ]; then
        echo -e "${RED}Файл tun2socks не найден! Установи его в пункте 4.${NC}"; sleep 2; return
    fi
    systemctl daemon-reload
    echo -e "${YELLOW}Запуск туннеля...${NC}"
    ip link delete $TUN_DEV >/dev/null 2>&1
    systemctl restart tun2socks
    sleep 2

    if ! pgrep -x "tun2socks" >/dev/null; then
        echo -e "${RED}Ошибка запуска! Проверь права файла или конфиг.${NC}"
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

# --- УСТАНОВКА КОМПОНЕНТОВ (Пункт 4) ---
component_submenu() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Настройка $1 ━━━${NC}\n"
        echo -e " 1) Установить / Переустановить"
        echo -e " 2) Удалить"
        echo -e " 0) Назад"
        read -p " Выбор: " s_choice
        case $s_choice in
            1) 
                apt update && apt install -y wget unzip curl python3-pip
                if [ "$1" == "tun2socks" ]; then
                    rm -f /usr/local/bin/tun2socks
                    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
                    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
                    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
                    chmod 755 /usr/local/bin/tun2socks
                    rm t2s.zip
                    # Создание сервиса
                    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks for WarpGo
After=network.target
[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload
                elif [ "$1" == "wgcf" ]; then
                    mkdir -p /etc/WarpGo
                    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
                    chmod 755 /usr/local/bin/wgcf
                elif [ "$1" == "speedtest" ]; then
                    apt install -y speedtest-cli
                fi
                echo -e "${GREEN}Готово!${NC}"; sleep 1; break ;;
            2)
                routing_down; rm -f /usr/local/bin/$1; echo "Удалено."; sleep 1; break ;;
            0) break ;;
        esac
    done
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    get_header
    echo -e " 1) Установить всё (tun2socks + wgcf)"
    echo -e " 2) Запустить WARP (UP)"
    echo -e " 3) Остановить WARP (DOWN)"
    echo -e " 4) Управление компонентами (tun2/wgcf/speed)"
    echo -e " 5) Обновить ключи CloudFlare"
    echo -e " 7) Данные SOCKS5 (для Telegram)"
    echo -e " 8) ${YELLOW}Тест скорости (Компактный)${NC}"
    echo -e " 9) Управление DNS"
    echo -e " 13) ${RED}СБРОС ВСЕХ НАСТРОЕК${NC}"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) component_submenu "tun2socks" <<< "1"
           component_submenu "wgcf" <<< "1" ;;
        2) routing_up ;;
        3) routing_down ;;
        4) clear; echo -e "1) tun2socks\n2) wgcf\n3) speedtest\n0) назад"
           read -p "> " c; [ "$c" == "1" ] && component_submenu "tun2socks"
           [ "$c" == "2" ] && component_submenu "wgcf"
           [ "$c" == "3" ] && component_submenu "speedtest" ;;
        5) cd /etc/WarpGo && rm -f wgcf-account.json wgcf-profile.conf
           yes | wgcf register >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1
           echo "Ключи обновлены."; sleep 1 ;;
        7) echo -e "IP: $S_IP | Port: 33854 (Amnezia SOCKS5)"; read -p "Enter..." ;;
        8) clear; echo "Тестирование скорости..."; speedtest-cli --simple || echo "Сначала установи speedtest в п.4"; read -p "Enter..." ;;
        9) manage_dns ;;
        13) routing_down; rm -rf /etc/WarpGo; echo "Данные стерты."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
