#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="1.9"
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---
check_update_silent() {
    REMOTE_VER=$(curl -sL --max-time 2 "$GITHUB_RAW" | grep -m1 'VERSION=' | cut -d'"' -f2)
    if [[ "$REMOTE_VER" != "$VERSION" && -n "$REMOTE_VER" ]]; then
        UPDATE_LABEL="${RED}[ ДОСТУПНА v$REMOTE_VER ]${NC}"
    else
        UPDATE_LABEL="${GREEN}(v$VERSION)${NC}"
    fi
}

get_header() {
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && S_STAT="${GREEN}● OK${NC}" || S_STAT="${RED}● OFF${NC}"
    (ip link show "$TUN_DEV" >/dev/null 2>&1 && pgrep -x "tun2socks" >/dev/null) && W_STAT="${GREEN}● OK${NC}" || W_STAT="${RED}● OFF${NC}"
    DNS_CUR=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
    S_IP=$(curl -s --interface "$MAIN_IFACE" --max-time 1 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 1 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo $UPDATE_LABEL"
    echo -e " Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | IP: ${GREEN}$W_IP${NC}"
    echo -e " DNS:    ${CYAN}$DNS_CUR${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПУНКТ 4: НОВОЕ МЕНЮ КОМПОНЕНТОВ ---
manage_components() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление компонентами ━━━${NC}\n"
        [ -f /usr/local/bin/tun2socks ] && T2S="${GREEN}[АКТУАЛЬНО]${NC}" || T2S="${RED}[НЕТ]${NC}"
        [ -f /usr/local/bin/wgcf ] && WGCF="${GREEN}[АКТУАЛЬНО]${NC}" || WGCF="${RED}[НЕТ]${NC}"
        command -v speedtest >/dev/null 2>&1 && SPD="${GREEN}[АКТУАЛЬНО]${NC}" || SPD="${RED}[НЕТ]${NC}"

        echo -e " 1) tun2socks      $T2S"
        echo -e " 2) wgcf (WARP)    $WGCF"
        echo -e " 3) Speedtest-CLI  $SPD"
        echo -e "\n 0) Назад"
        
        read -p " Выберите компонент для управления: " c_choice
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
                    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf && chmod +x /usr/local/bin/wgcf
                elif [ "$1" == "speedtest" ]; then
                    apt update && apt install -y curl
                    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
                    apt install speedtest -y
                fi
                echo -e "${GREEN}Готово!${NC}"; sleep 1; break ;;
            2)
                if [ "$1" == "tun2socks" ]; then systemctl stop tun2socks; rm -f /usr/local/bin/tun2socks; fi
                if [ "$1" == "wgcf" ]; then rm -f /usr/local/bin/wgcf; rm -rf /etc/WarpGo; fi
                if [ "$1" == "speedtest" ]; then apt remove speedtest -y; fi
                echo -e "${YELLOW}Удалено.${NC}"; sleep 1; break ;;
            0) break ;;
        esac
    done
}

# --- ПУНКТ 9: РАСШИРЕННЫЙ DNS ---
manage_dns() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление DNS ━━━${NC}\n"
        echo -e " 1) ${CYAN}AdGuard DNS${NC} (Фильтр+) | DoH: dns.adguard.com"
        echo -e " 2) ${CYAN}Cloudflare${NC}  (Скорость) | DoH: 1.1.1.1"
        echo -e " 3) ${CYAN}Google DNS${NC}  (Стандарт) | DoH: 8.8.8.8"
        echo -e " 4) ${CYAN}Comss DNS${NC}   (РФ/СНГ)   | IP: 76.76.2.22"
        echo -e " 5) ${CYAN}Control D${NC}   (Мощный)   | IP: 76.76.2.0"
        echo -e "\n 6) ${YELLOW}Сбросить (Вернуть системный)${NC}"
        echo -e " 0) Назад"
        read -p " Выбор: " d_choice
        case $d_choice in
            1) echo "nameserver 94.140.14.14" > /etc/resolv.conf ;;
            2) echo "nameserver 1.1.1.1" > /etc/resolv.conf ;;
            3) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
            4) echo "nameserver 76.76.2.22" > /etc/resolv.conf ;;
            5) echo "nameserver 76.76.2.0" > /etc/resolv.conf ;;
            6) echo "nameserver 8.8.8.8" > /etc/resolv.conf ;;
            0) break ;;
        esac
        echo "DNS изменен."; sleep 1
    done
}

# --- МАРШРУТЫ И ОСТАНОВКА (FIXED) ---
routing_up() {
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport 47684 priority 5 table main 2>/dev/null
    ip rule add sport 47684 priority 6 table main 2>/dev/null
    ip rule add from 172.29.172.0/24 priority 100 table warp 2>/dev/null
    iptables -t nat -A POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE
    echo -e "${GREEN}Маршруты подняты.${NC}"
}

routing_down() {
    echo -n " Полная очистка маршрутов и таблиц..."
    systemctl stop tun2socks >/dev/null 2>&1
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null
    ip route flush table warp 2>/dev/null
    echo -e " ${GREEN}✓${NC}"
}

# --- ПУНКТ 13: УДАЛЕНИЕ ---
smart_uninstall() {
    clear
    echo -e "${RED}━━━ МЕНЮ УДАЛЕНИЯ ━━━${NC}\n"
    echo -e " 1) Удалить только компоненты (tun2socks, wgcf)"
    echo -e " 2) Восстановить сеть (Очистить iptables/маршруты)"
    echo -e " 3) ПОЛНОЕ УДАЛЕНИЕ (Всё вышеперечисленное)"
    echo -e " 4) ПОЛНОЕ УДАЛЕНИЕ + Скрипт WarpGo"
    echo -e "\n 0) Назад"
    read -p " Выбор: " u_choice
    case $u_choice in
        1) rm -f /usr/local/bin/tun2socks /usr/local/bin/wgcf; rm -rf /etc/WarpGo ;;
        2) routing_down ;;
        3|4) 
            routing_down
            rm -f /usr/local/bin/tun2socks /usr/local/bin/wgcf /etc/systemd/system/tun2socks.service
            rm -rf /etc/WarpGo
            [ "$u_choice" == "4" ] && rm -f "$LOCAL_PATH" && exit 0 ;;
        0) return ;;
    esac
    echo "Выполнено."; sleep 1
}

# --- МЕНЮ ---
check_update_silent
while true; do
    clear
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить WARP (Все компоненты)"
    echo -e "  2) Запустить WARP (UP)"
    echo -e "  3) Остановить WARP (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  4) Компоненты (Обновление/Удаление)"
    echo -e "  5) Обновление ключей CloudFlare"
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
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) # Установка всех компонентов
            component_submenu "tun2socks" # вызов установки внутри
            component_submenu "wgcf"
            systemctl enable tun2socks && systemctl start tun2socks && routing_up ;;
        2) systemctl start tun2socks && routing_up ;;
        3) routing_down ;;
        4) manage_components ;;
        5) re-register_warp ;; # из v1.8
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        7) show_json_page ;; # из v1.7
        8) show_diagnostics_page ;; # из v1.7
        9) manage_dns ;;
        12) self_update ;; # из v1.8
        13) smart_uninstall ;;
        0) exit 0 ;;
    esac
done
