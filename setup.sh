#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.0"
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ПРОВЕРКИ СТАТУСА ---
get_header() {
    # Проверка интернета
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    
    # Проверка WARP (строго: файл + процесс + интерфейс)
    if [ -f /usr/local/bin/tun2socks ] && pgrep -x "tun2socks" >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
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

# --- ИСПРАВЛЕННАЯ УСТАНОВКА SPEEDTEST (Ubuntu 24.04+) ---
install_speedtest() {
    echo -e "${YELLOW}Установка Speedtest...${NC}"
    # Очистка старых кривых репозиториев
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
    apt update && apt install -y curl
    # Используем прямой бинарник или универсальный метод, так как Noble часто не имеет Release file
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    # Если репозиторий не подошел (Ubuntu 24.04), ставим через python/pip или универсальный скрипт
    apt install -y speedtest || apt install -y speedtest-cli
}

# --- НОВАЯ ОСТАНОВКА (Чтобы интернет не пропадал) ---
routing_down() {
    echo -n " Сброс сетевых правил и остановка WARP..."
    systemctl stop tun2socks >/dev/null 2>&1
    killall tun2socks >/dev/null 2>&1
    
    # Удаляем все правила, созданные скриптом
    while ip rule del priority 5 2>/dev/null; do :; done
    while ip rule del priority 6 2>/dev/null; do :; done
    while ip rule del priority 100 2>/dev/null; do :; done
    
    # Очистка iptables (только наши правила)
    iptables -t nat -D POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE 2>/dev/null
    
    # Сброс таблицы маршрутизации
    ip route flush table warp 2>/dev/null
    
    # Сброс DNS на стандартный (Google), чтобы не вис интернет
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    
    echo -e " ${GREEN}✓ Сеть восстановлена${NC}"
    sleep 2
}

# --- ПОДМЕНЮ КОМПОНЕНТОВ ---
component_submenu() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление $1 ━━━${NC}\n"
        echo -e " 1) Установить / Обновить"
        echo -e " 2) Удалить"
        echo -e " 0) Назад"
        read -p " Выбор: " s_choice
        case $s_choice in
            1) 
                if [ "$1" == "tun2socks" ]; then
                    V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
                    wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
                    unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks; rm t2s.zip
                elif [ "$1" == "wgcf" ]; then
                    mkdir -p /etc/WarpGo
                    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod +x /usr/local/bin/wgcf
                elif [ "$1" == "speedtest" ]; then
                    install_speedtest
                fi
                echo -e "${GREEN}Готово!${NC}"; sleep 1; break ;;
            2)
                if [ "$1" == "tun2socks" ]; then systemctl stop tun2socks; rm -f /usr/local/bin/tun2socks; fi
                if [ "$1" == "wgcf" ]; then rm -f /usr/local/bin/wgcf; rm -rf /etc/WarpGo; fi
                if [ "$1" == "speedtest" ]; then apt remove -y speedtest speedtest-cli; fi
                echo -e "${YELLOW}Удалено.${NC}"; sleep 1; break ;;
            0) break ;;
        esac
    done
}

# --- МЕНЮ DNS (Исправленное) ---
manage_dns() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление DNS ━━━${NC}\n"
        echo -e " 1) AdGuard DNS (94.140.14.14)"
        echo -e " 2) Cloudflare  (1.1.1.1)"
        echo -e " 3) Google      (8.8.8.8)"
        echo -e " 4) Comss       (76.76.2.22)"
        echo -e " 5) Control D   (76.76.2.11)" # Исправлен IP на стандартный фильтр
        echo -e "\n 6) Сбросить на стандарт (Google)"
        echo -e " 0) Назад"
        read -p " Выбор: " d_choice
        case $d_choice in
            1) echo "nameserver 94.140.14.14" > /etc/resolv.conf ;;
            2) echo "nameserver 1.1.1.1" > /etc/resolv.conf ;;
            3) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
            4) echo "nameserver 76.76.2.22" > /etc/resolv.conf ;;
            5) echo "nameserver 76.76.2.11" > /etc/resolv.conf ;;
            6) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
            0) break ;;
        esac
        echo "DNS изменен."; sleep 1
    done
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    clear
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить всё (tun2socks + wgcf)"
    echo -e "  2) Запустить WARP (UP)"
    echo -e "  3) Остановить WARP (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  4) Компоненты (Подробно)"
    echo -e "  5) Обновить ключи CloudFlare"
    echo -e "  6) Показать логи"
    echo -e "  7) Конфиг 3X-UI (JSON)"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ И DNS:${NC}"
    echo -e "  8) Диагностика и Speedtest"
    echo -e "  9) Управление DNS"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 12) ОБНОВИТЬ СКРИПТ (WarpGo)"
    echo ""
    echo -e " 13) ${RED}УДАЛЕНИЕ И СБРОС${NC}"
    echo ""
    echo -e "  0) Выход"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) 
            component_submenu "tun2socks" <<< "1"
            component_submenu "wgcf" <<< "1"
            echo "Компоненты установлены. Не забудьте запустить (пункт 2)."; sleep 2 ;;
        2) systemctl start tun2socks && routing_up ;;
        3) routing_down ;;
        4) manage_components ;;
        8) # Исправленный блок диагностики
            clear
            echo -e "${BLUE}━━━ Диагностика ━━━${NC}"
            if command -v speedtest >/dev/null 2>&1; then
                speedtest
            else
                echo -e "${RED}Speedtest не установлен. Установите его в пункте 4.${NC}"
            fi
            read -p "Нажмите Enter..." ;;
        13) smart_uninstall ;; # Из v1.9
        0) exit 0 ;;
    esac
done
