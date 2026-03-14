#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.4"
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ШАПКА И СТАТУСЫ ---
get_header() {
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    if pgrep -x "tun2socks" >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
        W_STAT="${GREEN}● OK${NC}"
    else
        W_STAT="${RED}● OFF${NC}"
    fi
    DNS_CUR=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
    S_IP=$(curl -s --interface "$MAIN_IFACE" --max-time 1 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 1 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION"
    echo -e " Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | IP: ${GREEN}$W_IP${NC}"
    echo -e " DNS:    ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- СОЗДАНИЕ СЕРВИСА (FIXED) ---
create_service() {
    echo -e "${YELLOW}Настройка системного сервиса...${NC}"
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks for WarpGo
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/WarpGo
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tun2socks >/dev/null 2>&1
}

# --- ЗАПУСК (С ПРОВЕРКОЙ ОШИБОК) ---
routing_up() {
    # 1. Проверка конфига
    if [ ! -f /etc/WarpGo/wgcf-profile.conf ]; then
        echo -e "${RED}Ошибка: Конфиг WARP не найден! Сначала выполни пункт 5.${NC}"
        sleep 2; return
    fi

    # 2. Daemon-reload на случай изменений
    systemctl daemon-reload

    echo -e "${YELLOW}Запуск туннеля...${NC}"
    
    # 3. Принудительная очистка старого интерфейса если он завис
    ip link delete $TUN_DEV >/dev/null 2>&1
    
    # 4. Старт сервиса
    systemctl start tun2socks
    sleep 2

    # 5. Проверка: поднялся ли процесс?
    if ! pgrep -x "tun2socks" >/dev/null; then
        echo -e "${RED}Критическая ошибка: tun2socks не смог запуститься!${NC}"
        echo -e "${YELLOW}Последние логи:${NC}"
        journalctl -u tun2socks -n 5 --no-pager
        read -p "Нажми Enter..."
        return
    fi

    # 6. Настройка маршрутов
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip link set dev "$TUN_DEV" mtu 1280 2>/dev/null
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport 47684 priority 5 table main 2>/dev/null
    ip rule add sport 47684 priority 6 table main 2>/dev/null
    ip rule add from 172.29.172.0/24 priority 100 table warp 2>/dev/null
    iptables -t nat -A POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE
    
    sysctl -w net.ipv6.conf."$TUN_DEV".disable_ipv6=1 >/dev/null
    echo -e "${GREEN}✓ WARP успешно запущен.${NC}"
    sleep 1
}

# --- ПОЛНЫЙ СБРОС ---
routing_down() {
    echo -e "${YELLOW}Полная очистка сети...${NC}"
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    while ip rule del priority 5 2>/dev/null; do :; done
    while ip rule del priority 6 2>/dev/null; do :; done
    while ip rule del priority 100 2>/dev/null; do :; done
    iptables -t nat -F POSTROUTING 2>/dev/null
    ip route flush table warp 2>/dev/null
    ip link delete $TUN_DEV >/dev/null 2>&1
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}✓ Сеть восстановлена.${NC}"
    sleep 1
}

# --- ОСТАЛЬНЫЕ МОДУЛИ (ПОЛНЫЕ) ---
manage_components() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление компонентами ━━━${NC}\n"
        [ -f /usr/local/bin/tun2socks ] && T2S="${GREEN}[АКТУАЛЬНО]${NC}" || T2S="${RED}[НЕТ]${NC}"
        [ -f /usr/local/bin/wgcf ] && WGCF="${GREEN}[АКТУАЛЬНО]${NC}" || WGCF="${RED}[НЕТ]${NC}"
        command -v speedtest >/dev/null 2>&1 && SPD="${GREEN}[УСТАНОВЛЕНО]${NC}" || SPD="${RED}[НЕТ]${NC}"

        echo -e " 1) tun2socks      $T2S"
        echo -e " 2) wgcf (WARP)    $WGCF"
        echo -e " 3) Speedtest-CLI  $SPD"
        echo -e "\n 0) Назад"
        read -p " Выбор: " c_choice
        case $c_choice in
            1) component_submenu "tun2socks" ;;
            2) component_submenu "wgcf" ;;
            3) component_submenu "speedtest" ;;
            0) break ;;
        esac
    done
}

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
                apt update && apt install -y wget unzip curl bc
                if [ "$1" == "tun2socks" ]; then
                    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
                    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
                    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks; rm t2s.zip
                    create_service
                elif [ "$1" == "wgcf" ]; then
                    mkdir -p /etc/WarpGo
                    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod +x /usr/local/bin/wgcf
                elif [ "$1" == "speedtest" ]; then
                    apt install -y speedtest-cli || (curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && apt install -y speedtest)
                fi
                echo -e "${GREEN}Готово!${NC}"; sleep 1; break ;;
            2)
                if [ "$1" == "tun2socks" ]; then systemctl stop tun2socks; rm -f /usr/local/bin/tun2socks /etc/systemd/system/tun2socks.service; systemctl daemon-reload; fi
                if [ "$1" == "wgcf" ]; then rm -f /usr/local/bin/wgcf; rm -rf /etc/WarpGo; fi
                if [ "$1" == "speedtest" ]; then apt remove -y speedtest speedtest-cli; fi
                echo -e "${YELLOW}Удалено.${NC}"; sleep 1; break ;;
            0) break ;;
        esac
    done
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить всё (tun2socks + wgcf)"
    echo -e "  2) Запустить WARP (UP)"
    echo -e "  3) Остановить WARP (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  4) Компоненты (Обновление/Удаление)"
    echo -e "  5) Обновление ключей CloudFlare"
    echo -e "  6) Показать логи"
    echo -e "  7) Прокси для Telegram (SOCKS5)"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ И DNS:${NC}"
    echo -e "  8) Диагностика"
    echo -e "  9) Управление DNS"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 12) ОБНОВИТЬ СКРИПТ"
    echo -e " 13) ${RED}УДАЛЕНИЕ И СБРОС${NC}"
    echo ""
    echo -e "  0) Выход"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) component_submenu "tun2socks" <<< "1"
           component_submenu "wgcf" <<< "1"
           echo -e "${GREEN}Установка завершена.${NC}"; sleep 2 ;;
        2) routing_up ;;
        3) routing_down ;;
        4) manage_components ;;
        5) clear; cd /etc/WarpGo && rm -f wgcf-account.json wgcf-profile.conf
           yes | wgcf register >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1
           echo "Ключи обновлены."; sleep 2 ;;
        6) journalctl -u tun2socks -n 50 --no-pager && read -p "Enter..." ;;
        7) clear; echo -e "${BLUE}Внешний SOCKS5:${NC} ${YELLOW}IP:${NC} $S_IP ${YELLOW}PORT:${NC} 33854"
           echo -e "Порт Amnezia для Telegram. Если не работает — проверь ufw allow 33854/tcp"; read -p "Enter..." ;;
        8) clear; speedtest || speedtest-cli; read -p "Enter..." ;;
        9) # Вызов меню DNS из v2.3
           echo "Меню DNS..." ;;
        12) curl -sL "$GITHUB_RAW" -o "$LOCAL_PATH" && chmod +x "$LOCAL_PATH"
            echo "Обновлено. Перезапуск..."; sleep 1; exec "$LOCAL_PATH" ;;
        13) routing_down; rm -f /usr/local/bin/tun2socks /usr/local/bin/wgcf; rm -rf /etc/WarpGo; echo "Очищено."; sleep 2 ;;
        0) exit 0 ;;
    esac
done
